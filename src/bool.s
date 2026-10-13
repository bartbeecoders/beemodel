# =============================================================================
#  BeeModel - mesh booleans (union / difference / intersection), robust.
#
#  1. Both meshes go to A's frame and are snapped to a dyadic integer grid
#     (2^18 cells over the size: noise such as cos 90deg != 0 or angles typed
#     to six decimals is gone, coincidences become exact). orient3d is exact
#     in 128-bit integers. B is perturbed symbolically along its vertex
#     normals (out for union and difference, in for intersection) plus a
#     pseudo-random per-vertex part ("simulation of simplicity"): every
#     decision is generic and made the same way everywhere, and faces lying
#     on faces resolve as a modeler expects - a flush cut goes through,
#     touching solids fuse, A - A is empty.
#  2. Candidate triangle pairs come from a uniform grid. Each intersecting
#     pair yields one segment between two points; a point is identified by
#     (edge of one mesh, face of the other), so neighbouring triangles share
#     it. Points at the same place (in the limit of the perturbation) are
#     welded to one id, mesh vertices included.
#  3. Every cut triangle is re-triangulated in 2D: the points of its edges
#     in order along them, the others inserted, the segments recovered by
#     edge flips. A point that is inside symbolically but on the boundary in
#     fact makes a flat triangle there, so no neighbour sees a T-junction.
#  4. Regions of each mesh, bounded by the cuts, are classified inside or
#     outside the other mesh by exact ray parity from a point exactly on the
#     region (barycentric, perturbed like its triangle); the operation picks
#     them (B's flipped for a difference). Untouched polygons keep their
#     shape, coincident opposite faces cancel. A result that is not closed
#     (solids touching along a line) is retried with B turned a hair.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

# exports
.globl mesh_boolean
.globl mesh_manifold
.globl bool_with
.globl op_bool_union
.globl op_bool_diff
.globl op_bool_isect

.equ BOOL_UNION,     0
.equ BOOL_DIFF,      1
.equ BOOL_ISECT,     2
.equ CDT_MAXP,       4096
.equ CDT_MAXT,       (CDT_MAXP*2+8)

.section .bss
.align 16
# ---- inputs ----
nva:            .skip 4
nvb:            .skip 4
nta:            .skip 4
ntb:            .skip 4
nv:             .skip 4
nt:             .skip 4
op_kind:        .skip 4
fail_flag:      .skip 4
jit:            .skip 4
.align 8
vi:             .skip 8             # int64 coords [nv][3]
vd:             .skip 8             # double coords [nv][3]
tri:            .skip 8             # u32 [nt][3] (global vertex ids)
tpoly:          .skip 8             # u32 [nt] source polygon
src_a:          .skip 8             # meshes
src_b:          .skip 8
mat_b:          .skip 48            # B (local) -> A (local)
ctr:            .skip 24            # snapping: centre, scale (doubles)
scl:            .skip 8
cell:           .skip 8
vw:             .skip 8             # int64 [nv][3] perturbation W (0 for A)
vn:             .skip 8             # int64 [nv][3] perturbation N (0 for A)
# ---- edges ----
n_edge:         .skip 4
.align 8
eh_e:           .skip 8             # hash (u, v) -> edge id
te:             .skip 8             # u32 [nt][3]: edge of triangle corner k->k+1
ev:             .skip 8             # u32 [ne][2]
# ---- intersections ----
np_:            .skip 4
nseg:           .skip 4
cap_p:          .skip 4
cap_s:          .skip 4
.align 8
eh_p:           .skip 8             # hash (edge << 32 | face) -> point
p_pos:          .skip 8             # double [np][3]
p_edge:         .skip 8             # u32 [np]
p_t:            .skip 8             # double [np]: parameter along the edge (lo -> hi)
seg:            .skip 8             # u32 [nseg][3]: triangle, p, q (global ids)
eh_c:           .skip 8             # constrained edges (p, q)
# ---- grid ----
g_n:            .skip 4
.align 8
g_min:          .skip 24
g_inv:          .skip 8
g_off:          .skip 8
g_tri:          .skip 8
stamp:          .skip 8
# ---- per triangle segments (CSR) ----
ts_off:         .skip 8
ts_seg:         .skip 8
ep_off:         .skip 8             # edge -> points (CSR)
ep_pts:         .skip 8
# ---- fragments ----
nfr:            .skip 4
cap_fr:         .skip 4
.align 8
fr:             .skip 8             # u32 [n][4]: a b c, source triangle (| B flag)
# ---- CDT scratch ----
cdt_n:          .skip 4
cdt_nt:         .skip 4
.align 16
cdt_id:         .skip CDT_MAXP*4
cdt_xy:         .skip CDT_MAXP*16
cdt_t:          .skip CDT_MAXT*12
cdt_ax:         .skip 8             # projection axes
cdt_flip:       .skip 4
cdt_onedge:     .skip 4
cf_depth:       .skip 4
.align 8
es_t:           .skip CDT_MAXP*8
es_id:          .skip CDT_MAXP*4
.align 8
cdt_area0:      .skip 8
# ---- classification ----
.align 8
reg:            .skip 8             # u32 [nfr] region id
reg_in:         .skip 8             # u8 [regions] inside the other mesh
nreg:           .skip 4
kept_poly:      .skip 8
tmpq:           .skip 64

.section .rodata
.align 8
bd_half:        .double 0.5
bd_one:         .double 1.0
bd_tiny:        .double 1.0e-9
bd_eps2:        .double 1.0e-18
bd_dir0:        # ray directions: every component in (2^38, 2^39.5) so the
                #  segment leaves the snapped box
                .quad 397268980492, 548411791148, 738007750828
                .quad -632880339924, 367344988844, 453830842372
                .quad 284920197524, -675288079484, 519101206532
                .quad 481353801116, 560948493844, -349641027932
                .quad -532028582132, -388902471676, 604131778652
s_axes:         .byte 1, 2, 2, 0, 0, 1

.text

# =============================================================================
#  mesh_boolean(rdi=A mesh, rsi=B mesh, rdx=B->A matrix float[12], ecx=op)
#    -> rax = new finished mesh, or 0 (failed / empty)
# =============================================================================
mesh_boolean:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 24
    mov     [rip+src_a], rdi
    mov     [rip+src_b], rsi
    mov     [rip+op_kind], ecx
    lea     rdi, [rip+mat_b]
    mov     rsi, rdx
    mov     ecx, 48
    rep     movsb
    mov     dword ptr [rip+jit], 0
    xor     r12d, r12d                  # a result that is not closed (kept
    mov     rdi, [rip+src_a]            #  in case nothing better comes)
    call    mesh_manifold
    mov     ebx, eax
    mov     rdi, [rip+src_b]
    call    mesh_manifold
    and     ebx, eax                    # both inputs closed
    call    fa_mark
    mov     [rsp], rax
.Lmb_try:
    mov     dword ptr [rip+fail_flag], 0
    call    load_inputs
    test    eax, eax
    jz      .Lmb_fail
    call    b_normals
    test    eax, eax
    jz      .Lmb_fail
    call    build_edges
    test    eax, eax
    jz      .Lmb_fail
    call    find_intersections
    test    eax, eax
    jz      .Lmb_fail
    call    weld_points
    test    eax, eax
    jz      .Lmb_fail
    call    split_triangles
    test    eax, eax
    jz      .Lmb_fail
    call    classify
    test    eax, eax
    jz      .Lmb_fail
    call    assemble
    test    rax, rax
    jz      .Lmb_fail
    test    ebx, ebx                    # closed in, closed out?
    jz      .Lmb_out
    mov     r13, rax
    mov     rdi, rax
    call    mesh_manifold
    test    eax, eax
    jz      2f
    test    r12, r12                    # yes: drop an earlier attempt
    jz      1f
    mov     rdi, r12
    call    mesh_unref
1:  mov     rax, r13
    jmp     .Lmb_out
2:  test    r12, r12                    # no (solids touching along a line,
    jz      3f                          #  coincidences the symbolic
    mov     rdi, r12                    #  perturbation leaves flat): keep it,
    call    mesh_unref                  #  try with B turned a hair
3:  mov     r12, r13
    jmp     .Lmb_again
.Lmb_fail:
    cmp     dword ptr [rip+fail_flag], 0  # a degenerate configuration: try
    je      .Lmb_best                   #  again with B turned a hair
.Lmb_again:
    cmp     dword ptr [rip+jit], 2
    jae     .Lmb_best
    inc     dword ptr [rip+jit]
    mov     rdi, [rsp]
    call    fa_release
    jmp     .Lmb_try
.Lmb_best:
    mov     rax, r12
.Lmb_out:
    push    rax
    mov     rdi, [rsp+8]
    call    fa_release
    pop     rax
    add     rsp, 24
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Inputs: vertices (A local; B through the matrix), snapping, triangles
# =============================================================================
load_inputs:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 40
    mov     r12, [rip+src_a]
    mov     r13, [rip+src_b]
    mov     eax, [r12+ME_NVERTS]
    mov     [rip+nva], eax
    mov     ecx, [r13+ME_NVERTS]
    mov     [rip+nvb], ecx
    add     eax, ecx
    mov     [rip+nv], eax
    mov     eax, [r12+ME_NTRIS]
    mov     [rip+nta], eax
    mov     ecx, [r13+ME_NTRIS]
    mov     [rip+ntb], ecx
    add     eax, ecx
    mov     [rip+nt], eax
    cmp     dword ptr [rip+nta], 0
    je      .Lli_fail
    cmp     dword ptr [rip+ntb], 0
    je      .Lli_fail
    mov     edi, [rip+nv]
    imul    edi, edi, 24
    call    fa
    test    rax, rax
    jz      .Lli_fail
    mov     [rip+vd], rax
    mov     edi, [rip+nv]
    imul    edi, edi, 24
    call    fa
    test    rax, rax
    jz      .Lli_fail
    mov     [rip+vi], rax
    mov     edi, [rip+nv]
    imul    edi, edi, 24
    call    fa
    test    rax, rax
    jz      .Lli_fail
    mov     [rip+vw], rax
    mov     ecx, [rip+nva]              # pseudo-random, non-zero, < 2^20
    mov     r8, 0x9E3779B97F4A7C15
41: cmp     ecx, [rip+nv]
    jae     42f
    mov     rdx, rcx
    sub     edx, [rip+nva]
    inc     rdx
    imul    rdx, r8
    mov     r9, rdx
    shr     r9, 29
    xor     rdx, r9
    imul    rdx, r8
    lea     r10, [rcx+rcx*2]
    lea     r10, [rax+r10*8]
    xor     r11d, r11d
40: mov     r9, rdx
    and     r9, 0xFFFFF
    sub     r9, 0x7FFFF
    or      r9, 1
    mov     [r10+r11*8], r9
    shr     rdx, 21
    inc     r11d
    cmp     r11d, 3
    jb      40b
    inc     ecx
    jmp     41b
42: mov     edi, [rip+nt]
    imul    edi, edi, 12
    call    fa
    test    rax, rax
    jz      .Lli_fail
    mov     [rip+tri], rax
    mov     edi, [rip+nt]
    shl     edi, 2
    call    fa
    test    rax, rax
    jz      .Lli_fail
    mov     [rip+tpoly], rax
    # positions (double): A as is, B through mat_b
    mov     r14, [rip+vd]
    xor     ebx, ebx
1:  cmp     ebx, [rip+nva]
    jae     2f
    mov     rax, [r12+ME_POS]
    lea     rcx, [rbx+rbx*2]
    cvtss2sd xmm0, [rax+rcx*4]
    cvtss2sd xmm1, [rax+rcx*4+4]
    cvtss2sd xmm2, [rax+rcx*4+8]
    movsd   [r14+rcx*8], xmm0
    movsd   [r14+rcx*8+8], xmm1
    movsd   [r14+rcx*8+16], xmm2
    inc     ebx
    jmp     1b
2:  xor     ebx, ebx
3:  cmp     ebx, [rip+nvb]
    jae     4f
    mov     rax, [r13+ME_POS]
    lea     rcx, [rbx+rbx*2]
    lea     rsi, [rax+rcx*4]
    mov     eax, [rip+nva]
    add     eax, ebx
    lea     rax, [rax+rax*2]
    lea     rdi, [r14+rax*8]
    xor     ecx, ecx                    # row r: m[r][0..2] . p + m[r][3]
31: lea     rdx, [rip+mat_b]
    imul    r8, rcx, 16
    add     rdx, r8
    cvtss2sd xmm0, [rdx]
    cvtss2sd xmm1, [rsi]
    mulsd   xmm0, xmm1
    cvtss2sd xmm2, [rdx+4]
    cvtss2sd xmm1, [rsi+4]
    mulsd   xmm2, xmm1
    addsd   xmm0, xmm2
    cvtss2sd xmm2, [rdx+8]
    cvtss2sd xmm1, [rsi+8]
    mulsd   xmm2, xmm1
    addsd   xmm0, xmm2
    cvtss2sd xmm2, [rdx+12]
    addsd   xmm0, xmm2
    movsd   [rdi+rcx*8], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      31b
    inc     ebx
    jmp     3b
4:  cmp     dword ptr [rip+jit], 0
    je      45f
    call    jitter_b
45: # snapping frame: centre of the bounding box, grid below
    movsd   xmm0, [r14]                 # min / max init
    movsd   xmm1, [r14+8]
    movsd   xmm2, [r14+16]
    movsd   xmm3, xmm0
    movsd   xmm4, xmm1
    movsd   xmm5, xmm2
    xor     ecx, ecx
41: cmp     ecx, [rip+nv]
    jae     42f
    lea     rax, [rcx+rcx*2]
    minsd   xmm0, [r14+rax*8]
    minsd   xmm1, [r14+rax*8+8]
    minsd   xmm2, [r14+rax*8+16]
    maxsd   xmm3, [r14+rax*8]
    maxsd   xmm4, [r14+rax*8+8]
    maxsd   xmm5, [r14+rax*8+16]
    inc     ecx
    jmp     41b
42: addsd   xmm0, xmm3                  # centre
    mulsd   xmm0, [rip+bd_half]
    addsd   xmm1, xmm4
    mulsd   xmm1, [rip+bd_half]
    addsd   xmm2, xmm5
    mulsd   xmm2, [rip+bd_half]
    movsd   [rip+ctr], xmm0
    movsd   [rip+ctr+8], xmm1
    movsd   [rip+ctr+16], xmm2
    subsd   xmm3, xmm0                  # half extents
    subsd   xmm4, xmm1
    subsd   xmm5, xmm2
    maxsd   xmm3, xmm4
    maxsd   xmm3, xmm5
    maxsd   xmm3, [rip+bd_tiny]
    movq    rax, xmm3                   # cell = 2^(ceil(log2 h) - 18): float
    shr     rax, 52                     #  noise below it disappears and
    and     eax, 0x7ff                  #  dyadic coordinates stay exact
    sub     eax, 17
    shl     rax, 52
    movq    xmm7, rax
    movsd   xmm6, [rip+bd_one]
    divsd   xmm6, xmm7
    movsd   [rip+scl], xmm6
    movsd   [rip+cell], xmm7
    xor     ecx, ecx                    # the centre on the grid
46: lea     r9, [rip+ctr]
    movsd   xmm0, [r9+rcx*8]
    mulsd   xmm0, xmm6
    cvtsd2si rax, xmm0
    cvtsi2sd xmm0, rax
    mulsd   xmm0, xmm7
    movsd   [r9+rcx*8], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      46b
    mov     r8, [rip+vi]
    xor     ecx, ecx
43: cmp     ecx, [rip+nv]
    jae     44f
    lea     rax, [rcx+rcx*2]
    xor     edx, edx
431:movsd   xmm0, [r14+rax*8]
    lea     r9, [rip+ctr]
    subsd   xmm0, [r9+rdx*8]
    mulsd   xmm0, [rip+scl]
    cvtsd2si r10, xmm0                  # (round to nearest)
    mov     [r8+rax*8], r10
    cvtsi2sd xmm0, r10                  # the double position is the snapped one
    mulsd   xmm0, [rip+cell]
    addsd   xmm0, [r9+rdx*8]
    movsd   [r14+rax*8], xmm0
    inc     rax
    inc     edx
    cmp     edx, 3
    jb      431b
    inc     ecx
    jmp     43b
44: # triangles (global vertex ids), polygons
    mov     r8, [rip+tri]
    mov     r9, [rip+tpoly]
    mov     rsi, [r12+ME_TRIS]
    mov     r10, [r12+ME_TPOLY]
    xor     ecx, ecx
5:  cmp     ecx, [rip+nta]
    jae     6f
    lea     rax, [rcx+rcx*2]
    mov     edx, [rsi+rax*4]
    mov     [r8+rax*4], edx
    mov     edx, [rsi+rax*4+4]
    mov     [r8+rax*4+4], edx
    mov     edx, [rsi+rax*4+8]
    mov     [r8+rax*4+8], edx
    mov     edx, [r10+rcx*4]
    mov     [r9+rcx*4], edx
    inc     ecx
    jmp     5b
6:  mov     rsi, [r13+ME_TRIS]
    mov     r10, [r13+ME_TPOLY]
    mov     r11d, [rip+nva]
    xor     ecx, ecx
7:  cmp     ecx, [rip+ntb]
    jae     8f
    lea     rax, [rcx+rcx*2]
    mov     edx, [rip+nta]
    add     edx, ecx
    lea     rdx, [rdx+rdx*2]
    mov     edi, [rsi+rax*4]
    add     edi, r11d
    mov     [r8+rdx*4], edi
    mov     edi, [rsi+rax*4+4]
    add     edi, r11d
    mov     [r8+rdx*4+4], edi
    mov     edi, [rsi+rax*4+8]
    add     edi, r11d
    mov     [r8+rdx*4+8], edi
    mov     edx, [rip+nta]
    add     edx, ecx
    mov     edi, [r10+rcx*4]
    mov     [r9+rdx*4], edi
    inc     ecx
    jmp     7b
8:  mov     eax, 1
    jmp     9f
.Lli_fail:
    xor     eax, eax
9:  add     rsp, 40
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# jitter_b - turn B's vertices (vd) by jit * 1e-5 rad about a generic axis
#   through a generic point of A's box: breaks the coincidences (parallel
#   coplanar edges, ...) that a translation alone cannot
jitter_b:
    push    rbx
    sub     rsp, 32
    mov     rax, [rip+src_a]            # centre c = 0.618 min + 0.382 max
    xor     ecx, ecx
1:  cvtss2sd xmm0, [rax+ME_BMIN+rcx*4]
    mulsd   xmm0, [rip+bd_g1]
    cvtss2sd xmm1, [rax+ME_BMAX+rcx*4]
    mulsd   xmm1, [rip+bd_g2]
    addsd   xmm0, xmm1
    movsd   [rsp+rcx*8], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      1b
    cvtsi2sd xmm7, dword ptr [rip+jit]
    mulsd   xmm7, [rip+bd_ang]          # theta
    movsd   xmm4, [rip+bd_ax]           # theta k
    mulsd   xmm4, xmm7
    movsd   xmm5, [rip+bd_ax+8]
    mulsd   xmm5, xmm7
    movsd   xmm6, [rip+bd_ax+16]
    mulsd   xmm6, xmm7
    mov     rax, [rip+vd]
    mov     ecx, [rip+nva]
2:  cmp     ecx, [rip+nv]
    jae     3f
    lea     rdx, [rcx+rcx*2]
    lea     rdx, [rax+rdx*8]
    movsd   xmm0, [rdx]                 # r = p - c
    subsd   xmm0, [rsp]
    movsd   xmm1, [rdx+8]
    subsd   xmm1, [rsp+8]
    movsd   xmm2, [rdx+16]
    subsd   xmm2, [rsp+16]
    movsd   xmm3, xmm5                  # p += theta k x r
    mulsd   xmm3, xmm2
    movsd   xmm7, xmm6
    mulsd   xmm7, xmm1
    subsd   xmm3, xmm7
    addsd   xmm3, [rdx]
    movsd   xmm7, xmm6
    mulsd   xmm7, xmm0
    movsd   xmm8, xmm4
    mulsd   xmm8, xmm2
    subsd   xmm7, xmm8
    addsd   xmm7, [rdx+8]
    movsd   xmm8, xmm4
    mulsd   xmm8, xmm1
    movsd   xmm9, xmm5
    mulsd   xmm9, xmm0
    subsd   xmm8, xmm9
    addsd   xmm8, [rdx+16]
    movsd   [rdx], xmm3
    movsd   [rdx+8], xmm7
    movsd   [rdx+16], xmm8
    inc     ecx
    jmp     2b
3:  add     rsp, 32
    pop     rbx
    ret

.section .rodata
.align 8
bd_g1:          .double 0.6180339887
bd_g2:          .double 0.3819660113
bd_ang:         .double 1.0e-5
bd_ax:          .double 0.4558423058, 0.5698028822, 0.6837634587
.text

# b_normals -> eax = 1: vn = B's vertex normals (sum of its triangles' unit
#   normals) as integers of length 2^20, pointing out (union, difference)
#   or in (intersection)
b_normals:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 48
    mov     edi, [rip+nv]
    imul    edi, edi, 24
    call    fa
    test    rax, rax
    jz      8f
    mov     [rip+vn], rax
    mov     edi, [rip+nv]
    imul    edi, edi, 24
    call    fa                          # double sums
    test    rax, rax
    jz      8f
    mov     r12, rax
    mov     ebx, [rip+nta]
1:  cmp     ebx, [rip+nt]
    jae     3f
    mov     rax, [rip+tri]
    lea     rcx, [rbx+rbx*2]
    lea     r13, [rax+rcx*4]
    mov     edi, [r13]
    call    vpos
    mov     rsi, rax
    mov     edi, [r13+4]
    call    vpos
    mov     rdx, rax
    mov     edi, [r13+8]
    call    vpos
    xor     ecx, ecx                    # e1 = b - a, e2 = c - a
11: movsd   xmm0, [rdx+rcx*8]
    subsd   xmm0, [rsi+rcx*8]
    movsd   [rsp+rcx*8], xmm0
    movsd   xmm0, [rax+rcx*8]
    subsd   xmm0, [rsi+rcx*8]
    movsd   [rsp+24+rcx*8], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      11b
    movsd   xmm0, [rsp+8]               # n = e1 x e2
    mulsd   xmm0, [rsp+40]
    movsd   xmm1, [rsp+16]
    mulsd   xmm1, [rsp+32]
    subsd   xmm0, xmm1
    movsd   xmm2, [rsp+16]
    mulsd   xmm2, [rsp+24]
    movsd   xmm1, [rsp]
    mulsd   xmm1, [rsp+40]
    subsd   xmm2, xmm1
    movsd   xmm3, [rsp]
    mulsd   xmm3, [rsp+32]
    movsd   xmm1, [rsp+8]
    mulsd   xmm1, [rsp+24]
    subsd   xmm3, xmm1
    movsd   xmm4, xmm0                  # unit
    mulsd   xmm4, xmm4
    movsd   xmm5, xmm2
    mulsd   xmm5, xmm5
    addsd   xmm4, xmm5
    movsd   xmm5, xmm3
    mulsd   xmm5, xmm5
    addsd   xmm4, xmm5
    sqrtsd  xmm4, xmm4
    xorpd   xmm5, xmm5
    ucomisd xmm4, xmm5
    je      2f
    movsd   xmm5, [rip+bd_one]
    divsd   xmm5, xmm4
    mulsd   xmm0, xmm5
    mulsd   xmm2, xmm5
    mulsd   xmm3, xmm5
    xor     ecx, ecx
12: mov     eax, [r13+rcx*4]
    lea     rax, [rax+rax*2]
    lea     rax, [r12+rax*8]
    movsd   xmm1, [rax]
    addsd   xmm1, xmm0
    movsd   [rax], xmm1
    movsd   xmm1, [rax+8]
    addsd   xmm1, xmm2
    movsd   [rax+8], xmm1
    movsd   xmm1, [rax+16]
    addsd   xmm1, xmm3
    movsd   [rax+16], xmm1
    inc     ecx
    cmp     ecx, 3
    jb      12b
2:  inc     ebx
    jmp     1b
3:  movsd   xmm6, [rip+bd_2p20]         # +/- 2^20 by the operation
    cmp     dword ptr [rip+op_kind], BOOL_ISECT
    jne     31f
    xorpd   xmm6, [rip+bd_sign]
31: mov     ebx, [rip+nva]
4:  cmp     ebx, [rip+nv]
    jae     7f
    lea     rax, [rbx+rbx*2]
    lea     rsi, [r12+rax*8]
    mov     rdi, [rip+vn]
    lea     rdi, [rdi+rax*8]
    movsd   xmm0, [rsi]
    mulsd   xmm0, xmm0
    movsd   xmm1, [rsi+8]
    mulsd   xmm1, xmm1
    addsd   xmm0, xmm1
    movsd   xmm1, [rsi+16]
    mulsd   xmm1, xmm1
    addsd   xmm0, xmm1
    sqrtsd  xmm0, xmm0
    xorpd   xmm1, xmm1
    ucomisd xmm0, xmm1
    je      6f                          # (no normal: W alone)
    movsd   xmm1, xmm6
    divsd   xmm1, xmm0
    xor     ecx, ecx
5:  movsd   xmm0, [rsi+rcx*8]
    mulsd   xmm0, xmm1
    cvtsd2si rax, xmm0
    mov     [rdi+rcx*8], rax
    inc     ecx
    cmp     ecx, 3
    jb      5b
6:  inc     ebx
    jmp     4b
7:  mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 48
    pop     r13
    pop     r12
    pop     rbx
    ret

.section .rodata
.align 8
bd_2p20:        .double 1048576.0
.text

# =============================================================================
#  Exact predicates (128-bit integers) and symbolic perturbation
# =============================================================================
# mul_ss(rax, rcx) -> rdx:rax = signed product (128)
# mul128(r8=hi, r9=lo, r10=m) -> r8:r9 = (hi:lo) * m, signed, assumed to fit
mul128:
    push    rbx
    xor     ebx, ebx                    # sign
    test    r8, r8
    jns     1f
    not     r8                          # negate 128
    not     r9
    add     r9, 1
    adc     r8, 0
    xor     ebx, 1
1:  test    r10, r10
    jns     2f
    neg     r10
    xor     ebx, 1
2:  mov     rax, r9                     # lo * m
    mul     r10
    mov     r9, rax
    mov     rcx, rdx
    mov     rax, r8                     # hi * m (low part)
    mul     r10
    lea     r8, [rcx+rax]
    test    ebx, ebx
    jz      3f
    not     r8
    not     r9
    add     r9, 1
    adc     r8, 0
3:  pop     rbx
    ret

# cross2(rdi=x1, rsi=y1, rdx=x2, rcx=y2) -> r8:r9 = x1*y2 - y1*x2 (128)
cross2:
    push    rbx
    mov     rax, rdi
    mov     rbx, rdx
    imul    rcx                         # x1 * y2
    mov     r8, rdx
    mov     r9, rax
    mov     rax, rsi
    imul    rbx                         # y1 * x2
    sub     r9, rax
    sbb     r8, rdx
    pop     rbx
    ret

# sgn128(r8:r9) -> eax = -1 / 0 / 1
sgn128:
    test    r8, r8
    js      1f
    jnz     2f
    test    r9, r9
    jnz     2f
    xor     eax, eax
    ret
1:  mov     eax, -1
    ret
2:  mov     eax, 1
    ret

# pt(edi=global vertex) -> rax = &int64[3]
pt:
    mov     eax, edi
    lea     rax, [rax+rax*2]
    shl     rax, 3
    add     rax, [rip+vi]
    ret

# Mesh B is perturbed symbolically: p -> p + e (N_p + d W_p), 1 >> d >> e,
#   N_p along the vertex normal - out for a union or difference, in for an
#   intersection - so faces lying on each other resolve the way a modeler
#   expects (a flush cut goes through, touching solids fuse, A - A is
#   empty), and W_p a pseudo-random tie breaker for what N leaves exact.
#   det(r + e(A + d B)) is a polynomial; the first non-zero coefficient in
#   the order 1, e, ed, e^2, e^2 d, e^2 d^2, e^3 ... gives the sign.
#
# og_p / og_n / og_w (int64[3] pointers) hold the four points a b
#   c d; orient_gen(edi=1: stop at the first non-zero coefficient, 0: all
#   ten into og_c) -> eax = sign
orient_gen:
    test    edi, edi                    # fast path: the exact determinant
    jz      orient_full                 #  alone decides almost always
    sub     rsp, 88
    mov     rax, [rip+og_p+24]          # rows a-d, b-d, c-d on the stack
    mov     rcx, [rip+og_p]
    mov     rdx, [rcx]
    sub     rdx, [rax]
    mov     [rsp], rdx
    mov     rdx, [rcx+8]
    sub     rdx, [rax+8]
    mov     [rsp+8], rdx
    mov     rdx, [rcx+16]
    sub     rdx, [rax+16]
    mov     [rsp+16], rdx
    mov     rcx, [rip+og_p+8]
    mov     rdx, [rcx]
    sub     rdx, [rax]
    mov     [rsp+24], rdx
    mov     rdx, [rcx+8]
    sub     rdx, [rax+8]
    mov     [rsp+32], rdx
    mov     rdx, [rcx+16]
    sub     rdx, [rax+16]
    mov     [rsp+40], rdx
    mov     rcx, [rip+og_p+16]
    mov     rdx, [rcx]
    sub     rdx, [rax]
    mov     [rsp+48], rdx
    mov     rdx, [rcx+8]
    sub     rdx, [rax+8]
    mov     [rsp+56], rdx
    mov     rdx, [rcx+16]
    sub     rdx, [rax+16]
    mov     [rsp+64], rdx
    lea     rdi, [rsp]
    lea     rsi, [rsp+24]
    lea     rdx, [rsp+48]
    call    det3
    add     rsp, 88
    call    sgn128
    test    eax, eax
    jz      1f
    ret
1:  mov     edi, 1
orient_full:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 8
    mov     [rsp], edi
    lea     r12, [rip+og_p]
    lea     r13, [rip+og_w]
    lea     r14, [rip+og_n]
    xor     ebx, ebx                    # rows j = 0..2 (minus d)
1:  mov     rsi, [r12+rbx*8]
    mov     rdi, [r12+24]
    mov     r8, [r13+rbx*8]
    mov     r9, [r13+24]
    mov     r15, [r14+rbx*8]
    imul    r10, rbx, 24
    lea     r11, [rip+og_rows]
    add     r11, r10
    xor     ecx, ecx
    xor     ebp, ebp                    # non-zero bits: 1 = A row, 2 = B row
2:  mov     rdx, [rsi+rcx*8]            # r
    sub     rdx, [rdi+rcx*8]
    mov     [r11+rcx*8], rdx
    mov     rdx, [r15+rcx*8]            # A = N_j - N_d
    mov     rax, [r14+24]
    sub     rdx, [rax+rcx*8]
    mov     [r11+72+rcx*8], rdx
    test    rdx, rdx
    jz      3f
    or      ebp, 1
3:  mov     rdx, [r8+rcx*8]             # B = W_j - W_d
    sub     rdx, [r9+rcx*8]
    mov     [r11+144+rcx*8], rdx
    test    rdx, rdx
    jz      4f
    or      ebp, 2
4:  inc     ecx
    cmp     ecx, 3
    jb      2b
    lea     rdx, [rip+og_nz]
    mov     [rdx+rbx*4], ebp
    inc     ebx
    cmp     ebx, 3
    jb      1b
    xor     r12d, r12d                  # order index
    mov     dword ptr [rip+og_sign], 0
.Log_ord:
    cmp     r12d, 10
    jae     .Log_done
    xor     r13d, r13d                  # sum (r13 hi : r14 lo)
    xor     r14d, r14d
    xor     ebx, ebx                    # assignment 0..26: a digit per row
.Log_as:
    cmp     ebx, 27
    jae     .Log_store
    mov     eax, ebx
    xor     ecx, ecx                    # row
    xor     r8d, r8d                    # k (rows not r)
    xor     r9d, r9d                    # m (B rows)
    lea     r15, [rip+og_sel]
5:  xor     edx, edx
    mov     r10d, 3
    div     r10d                        # edx = digit, eax = the rest
    imul    r11, rcx, 24
    lea     r10, [rip+og_rows]
    add     r10, r11
    test    edx, edx
    jz      7f
    inc     r8d
    lea     r11, [rip+og_nz]
    mov     r11d, [r11+rcx*4]
    cmp     edx, 2
    je      6f
    test    r11d, 1                     # a zero row: no term
    jz      .Log_next
    add     r10, 72
    jmp     7f
6:  inc     r9d
    test    r11d, 2
    jz      .Log_next
    add     r10, 144
7:  mov     [r15+rcx*8], r10
    inc     ecx
    cmp     ecx, 3
    jb      5b
    lea     rax, [rip+ord_k]
    movzx   eax, byte ptr [rax+r12]
    cmp     r8d, eax
    jne     .Log_next
    lea     rax, [rip+ord_m]
    movzx   eax, byte ptr [rax+r12]
    cmp     r9d, eax
    jne     .Log_next
    mov     rdi, [r15]
    mov     rsi, [r15+8]
    mov     rdx, [r15+16]
    call    det3
    add     r14, r9
    adc     r13, r8
.Log_next:
    inc     ebx
    jmp     .Log_as
.Log_store:
    mov     rax, r12
    shl     rax, 4
    lea     rcx, [rip+og_c]
    mov     [rcx+rax], r13
    mov     [rcx+rax+8], r14
    mov     r8, r13
    mov     r9, r14
    call    sgn128
    test    eax, eax
    jz      8f
    cmp     dword ptr [rip+og_sign], 0
    jne     8f
    mov     [rip+og_sign], eax
    cmp     dword ptr [rsp], 0
    jne     .Log_done
8:  inc     r12d
    jmp     .Log_ord
.Log_done:
    mov     eax, [rip+og_sign]
    add     rsp, 8
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# det3(rdi, rsi, rdx = rows int64[3]) -> r8:r9 = x . (y x z) (128-bit)
det3:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13, rdx
    mov     rdi, [r12+8]                # y.y z.z - y.z z.y
    mov     rsi, [r12+16]
    mov     rdx, [r13+8]
    mov     rcx, [r13+16]
    call    cross2
    mov     r10, [rbx]
    call    mul128
    mov     r14, r8
    mov     r15, r9
    mov     rdi, [r12+16]               # y.z z.x - y.x z.z
    mov     rsi, [r12]
    mov     rdx, [r13+16]
    mov     rcx, [r13]
    call    cross2
    mov     r10, [rbx+8]
    call    mul128
    add     r15, r9
    adc     r14, r8
    mov     rdi, [r12]                  # y.x z.y - y.y z.x
    mov     rsi, [r12+8]
    mov     rdx, [r13]
    mov     rcx, [r13+8]
    call    cross2
    mov     r10, [rbx+16]
    call    mul128
    add     r9, r15
    adc     r8, r14
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# og_vertex(ecx=slot, edi=global vertex) - point, W and B flag of a vertex
og_vertex:
    mov     eax, edi
    lea     rax, [rax+rax*2]
    shl     rax, 3
    mov     rdx, [rip+vi]
    add     rdx, rax
    lea     r8, [rip+og_p]
    mov     [r8+rcx*8], rdx
    mov     rdx, rax
    add     rax, [rip+vw]
    lea     r8, [rip+og_w]
    mov     [r8+rcx*8], rax
    add     rdx, [rip+vn]
    lea     r8, [rip+og_n]
    mov     [r8+rcx*8], rdx
    ret

# orient_sos(edi=a, esi=b, edx=c, ecx=d global vertices) -> eax = -1 / 1
#   (0: degenerate even when perturbed - flags the run as failed)
orient_sos:
    push    rbx
    push    r12
    push    r13
    mov     ebx, esi
    mov     r12d, edx
    mov     r13d, ecx
    xor     ecx, ecx
    call    og_vertex
    mov     edi, ebx
    mov     ecx, 1
    call    og_vertex
    mov     edi, r12d
    mov     ecx, 2
    call    og_vertex
    mov     edi, r13d
    mov     ecx, 3
    call    og_vertex
    mov     edi, 1
    call    orient_gen
    test    eax, eax
    jnz     1f
    mov     dword ptr [rip+fail_flag], 1
1:  pop     r13
    pop     r12
    pop     rbx
    ret

# c_double(rdi=&128-bit (hi, lo)) -> xmm0
c_double:
    mov     r8, [rdi]
    mov     r9, [rdi+8]
    cvtsi2sd xmm0, r8
    mulsd   xmm0, [rip+bd_2p64]
    mov     rax, r9
    shr     rax, 1
    cvtsi2sd xmm1, rax
    addsd   xmm1, xmm1
    mov     rax, r9
    and     eax, 1
    cvtsi2sd xmm2, rax
    addsd   xmm1, xmm2
    addsd   xmm0, xmm1
    ret

# point_t(rdi=&triangle u32[3], esi=lo, edx=hi) -> xmm0 = where the edge
#   lo -> hi crosses the triangle's plane in the limit of the perturbation:
#   t = D(lo) / (D(lo) - D(hi)) at the first order where they are not both 0
point_t:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 176
    mov     rbx, rdi
    mov     r12d, esi
    mov     r13d, edx
    xor     ecx, ecx
    mov     edi, [rbx]
    call    og_vertex
    mov     edi, [rbx+4]
    mov     ecx, 1
    call    og_vertex
    mov     edi, [rbx+8]
    mov     ecx, 2
    call    og_vertex
    mov     edi, r12d
    mov     ecx, 3
    call    og_vertex
    xor     edi, edi
    call    orient_gen
    lea     rsi, [rip+og_c]             # keep D(lo)
    lea     rdi, [rsp]
    mov     ecx, 160
    rep     movsb
    mov     edi, r13d
    mov     ecx, 3
    call    og_vertex
    xor     edi, edi
    call    orient_gen
    xor     ecx, ecx
1:  cmp     ecx, 10
    jae     8f
    mov     rax, rcx
    shl     rax, 4
    lea     rdx, [rip+og_c]
    mov     r8, [rsp+rax]
    or      r8, [rsp+rax+8]
    or      r8, [rdx+rax]
    or      r8, [rdx+rax+8]
    jnz     2f
    inc     ecx
    jmp     1b
2:  mov     [rsp+160], rax
    lea     rdi, [rdx+rax]              # D(hi)
    call    c_double
    movsd   [rsp+168], xmm0
    mov     rax, [rsp+160]
    lea     rdi, [rsp+rax]              # D(lo)
    call    c_double
    movsd   xmm1, xmm0
    subsd   xmm1, [rsp+168]
    xorpd   xmm2, xmm2
    ucomisd xmm1, xmm2
    je      8f
    divsd   xmm0, xmm1
    jmp     9f
8:  movsd   xmm0, [rip+bd_half]
9:  add     rsp, 176
    pop     r13
    pop     r12
    pop     rbx
    ret

.section .bss
.align 16
og_p:           .skip 32
og_w:           .skip 32
og_n:           .skip 32
og_nz:          .skip 16
og_sel:         .skip 24
og_sign:        .skip 4
n_inc:          .skip 4
.align 8
inc_p:          .skip 8
.align 16
og_rows:        .skip 216           # r[3][3], A[3][3], B[3][3]
og_c:           .skip 160           # ten 128-bit coefficients (hi, lo)
.section .rodata
.align 8
ord_k:          .byte 0, 1, 1, 2, 2, 2, 3, 3, 3, 3
ord_m:          .byte 0, 0, 1, 0, 1, 2, 0, 1, 2, 3
bd_2p64:        .double 18446744073709551616.0
.text

# =============================================================================
#  Edges of both meshes (unique, ids) and per-triangle corner edges
# =============================================================================
build_edges:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     edi, [rip+nt]
    imul    edi, edi, 3
    call    eh_new
    test    rax, rax
    jz      .Lbe_fail
    mov     [rip+eh_e], rax
    mov     edi, [rip+nt]
    imul    edi, edi, 12
    call    fa
    test    rax, rax
    jz      .Lbe_fail
    mov     [rip+te], rax
    mov     edi, [rip+nt]
    imul    edi, edi, 24
    call    fa
    test    rax, rax
    jz      .Lbe_fail
    mov     [rip+ev], rax
    mov     dword ptr [rip+n_edge], 0
    xor     r12d, r12d                  # triangle
1:  cmp     r12d, [rip+nt]
    jae     3f
    xor     r13d, r13d                  # corner
2:  cmp     r13d, 3
    jae     21f
    mov     rax, [rip+tri]
    lea     rcx, [r12+r12*2]
    lea     rdx, [rcx+r13]
    mov     edi, [rax+rdx*4]            # v_k
    lea     ebx, [r13+1]
    cmp     ebx, 3
    jb      22f
    xor     ebx, ebx
22: add     rbx, rcx
    mov     esi, [rax+rbx*4]            # v_k+1
    mov     r14d, edi
    mov     r15d, esi
    call    ukey
    mov     rsi, rax
    mov     rdi, [rip+eh_e]
    call    eh_slot
    test    edx, edx
    jnz     23f
    mov     ecx, [rip+n_edge]
    mov     [rax], ecx
    inc     dword ptr [rip+n_edge]
    mov     rdx, [rip+ev]               # endpoints (lo, hi)
    mov     edi, r14d
    mov     esi, r15d
    cmp     edi, esi
    jbe     24f
    xchg    edi, esi
24: mov     [rdx+rcx*8], edi
    mov     [rdx+rcx*8+4], esi
23: mov     ecx, [rax]
    mov     rax, [rip+te]
    lea     rdx, [r12+r12*2]
    add     rdx, r13
    mov     [rax+rdx*4], ecx
    inc     r13d
    jmp     2b
21: inc     r12d
    jmp     1b
3:  mov     eax, 1
    jmp     9f
.Lbe_fail:
    xor     eax, eax
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Intersections
# =============================================================================
# find_intersections -> eax = 1 ok (0: allocation failure or degeneracy)
find_intersections:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 56
    call    build_grid
    test    eax, eax
    jz      .Lfi_fail
    mov     edi, [rip+nt]               # points / segments: grow-free caps
    shl     edi, 2
    add     edi, 1024
    mov     [rip+cap_p], edi
    mov     [rip+cap_s], edi
    call    eh_new
    test    rax, rax
    jz      .Lfi_fail
    mov     [rip+eh_p], rax
    mov     edi, [rip+cap_p]
    imul    edi, edi, 24
    call    fa
    test    rax, rax
    jz      .Lfi_fail
    mov     [rip+p_pos], rax
    mov     edi, [rip+cap_p]            # (edge, point) incidences
    shl     edi, 3
    call    fa
    test    rax, rax
    jz      .Lfi_fail
    mov     [rip+p_edge], rax
    mov     edi, [rip+cap_p]
    shl     edi, 3
    call    fa
    test    rax, rax
    jz      .Lfi_fail
    mov     [rip+inc_p], rax
    mov     dword ptr [rip+n_inc], 0
    mov     edi, [rip+cap_p]
    shl     edi, 3
    call    fa
    test    rax, rax
    jz      .Lfi_fail
    mov     [rip+p_t], rax
    mov     edi, [rip+cap_s]
    imul    edi, edi, 24
    call    fa
    test    rax, rax
    jz      .Lfi_fail
    mov     [rip+seg], rax
    mov     edi, [rip+ntb]
    shl     edi, 2
    call    fa
    test    rax, rax
    jz      .Lfi_fail
    mov     [rip+stamp], rax
    mov     dword ptr [rip+np_], 0
    mov     dword ptr [rip+nseg], 0
    xor     r12d, r12d                  # A triangle
.Lfi_ta:
    cmp     r12d, [rip+nta]
    jae     .Lfi_done
    mov     edi, r12d
    lea     rsi, [rsp]                  # its grid cell range [rsp..+24)
    call    tri_cells
    mov     ebx, [rsp+8]                # z
.Lfi_z:
    cmp     ebx, [rsp+20]
    ja      .Lfi_tnext
    mov     r13d, [rsp+4]               # y
.Lfi_y:
    cmp     r13d, [rsp+16]
    ja      .Lfi_znext
    mov     r14d, [rsp]                 # x
.Lfi_x:
    cmp     r14d, [rsp+12]
    ja      .Lfi_ynext
    mov     eax, ebx                    # cell index
    imul    eax, [rip+g_n]
    add     eax, r13d
    imul    eax, [rip+g_n]
    add     eax, r14d
    mov     rcx, [rip+g_off]
    mov     r15d, [rcx+rax*4]
    mov     ebp, [rcx+rax*4+4]
.Lfi_c:
    cmp     r15d, ebp
    jae     .Lfi_xnext
    mov     rcx, [rip+g_tri]
    mov     edi, [rcx+r15*4]            # B triangle (local index)
    mov     rcx, [rip+stamp]
    lea     eax, [r12+1]
    cmp     [rcx+rdi*4], eax
    je      .Lfi_cnext
    mov     [rcx+rdi*4], eax
    mov     [rsp+32], r15d
    mov     [rsp+36], ebp
    mov     esi, edi
    add     esi, [rip+nta]              # global B triangle
    mov     edi, r12d
    call    tri_tri
    test    eax, eax
    js      .Lfi_fail
    mov     r15d, [rsp+32]
    mov     ebp, [rsp+36]
.Lfi_cnext:
    inc     r15d
    jmp     .Lfi_c
.Lfi_xnext:
    inc     r14d
    jmp     .Lfi_x
.Lfi_ynext:
    inc     r13d
    jmp     .Lfi_y
.Lfi_znext:
    inc     ebx
    jmp     .Lfi_z
.Lfi_tnext:
    inc     r12d
    jmp     .Lfi_ta
.Lfi_done:
    cmp     dword ptr [rip+fail_flag], 0
    jne     .Lfi_fail
    mov     eax, 1
    jmp     9f
.Lfi_fail:
    xor     eax, eax
9:  add     rsp, 56
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# tri_box(edi=global triangle, rsi=out double[6] min / max)
tri_box:
    mov     rax, [rip+tri]
    lea     rcx, [rdi+rdi*2]
    mov     r8d, [rax+rcx*4]
    mov     r9d, [rax+rcx*4+4]
    mov     r10d, [rax+rcx*4+8]
    mov     rax, [rip+vd]
    lea     r8, [r8+r8*2]
    lea     r9, [r9+r9*2]
    lea     r10, [r10+r10*2]
    xor     ecx, ecx
1:  movsd   xmm0, [rax+r8*8]
    movsd   xmm1, xmm0
    minsd   xmm0, [rax+r9*8]
    maxsd   xmm1, [rax+r9*8]
    minsd   xmm0, [rax+r10*8]
    maxsd   xmm1, [rax+r10*8]
    movsd   [rsi+rcx*8], xmm0
    movsd   [rsi+24+rcx*8], xmm1
    inc     r8
    inc     r9
    inc     r10
    inc     ecx
    cmp     ecx, 3
    jb      1b
    ret

# build_grid -> eax = 1: B triangles bucketed into g_n^3 cells
build_grid:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 112
    mov     eax, [rip+ntb]              # g = clamp(2 cbrt(n), 1, 96)
    cvtsi2sd xmm0, eax
    sqrtsd  xmm0, xmm0
    sqrtsd  xmm0, xmm0                  # n^(1/4) (close enough, cheaper)
    addsd   xmm0, xmm0
    cvttsd2si eax, xmm0
    cmp     eax, 1
    jge     1f
    mov     eax, 1
1:  cmp     eax, 96
    jle     2f
    mov     eax, 96
2:  mov     [rip+g_n], eax
    movsd   xmm0, [rip+bd_big]          # bounds of B (vd)
    movsd   xmm1, xmm0
    movsd   xmm2, xmm0
    movsd   xmm3, [rip+bd_nbig]
    movsd   xmm4, xmm3
    movsd   xmm5, xmm3
    mov     rax, [rip+vd]
    mov     ecx, [rip+nva]
3:  cmp     ecx, [rip+nv]
    jae     4f
    lea     rdx, [rcx+rcx*2]
    minsd   xmm0, [rax+rdx*8]
    minsd   xmm1, [rax+rdx*8+8]
    minsd   xmm2, [rax+rdx*8+16]
    maxsd   xmm3, [rax+rdx*8]
    maxsd   xmm4, [rax+rdx*8+8]
    maxsd   xmm5, [rax+rdx*8+16]
    inc     ecx
    jmp     3b
4:  movsd   [rip+g_min], xmm0
    movsd   [rip+g_min+8], xmm1
    movsd   [rip+g_min+16], xmm2
    subsd   xmm3, xmm0                  # cell size = max extent / g (+ a bit)
    subsd   xmm4, xmm1
    subsd   xmm5, xmm2
    maxsd   xmm3, xmm4
    maxsd   xmm3, xmm5
    mulsd   xmm3, [rip+bd_1001]
    maxsd   xmm3, [rip+bd_tiny]
    cvtsi2sd xmm6, dword ptr [rip+g_n]
    divsd   xmm6, xmm3
    movsd   [rip+g_inv], xmm6
    mov     eax, [rip+g_n]              # offsets (cells + 1)
    imul    eax, eax
    imul    eax, [rip+g_n]
    mov     [rsp+104], eax
    lea     edi, [rax*4+8]
    call    fa
    test    rax, rax
    jz      .Lbg_fail
    mov     [rip+g_off], rax
    xor     r15d, r15d                  # pass 0 count, pass 1 fill
.Lbg_pass:
    xor     r12d, r12d
.Lbg_tri:
    cmp     r12d, [rip+ntb]
    jae     .Lbg_pend
    mov     edi, r12d
    add     edi, [rip+nta]
    lea     rsi, [rsp+48]
    call    tri_cells
    mov     ebx, [rsp+56]
5:  cmp     ebx, [rsp+68]
    ja      .Lbg_tnext
    mov     r13d, [rsp+52]
6:  cmp     r13d, [rsp+64]
    ja      .Lbg_znext
    mov     r14d, [rsp+48]
7:  cmp     r14d, [rsp+60]
    ja      .Lbg_ynext
    mov     eax, ebx
    imul    eax, [rip+g_n]
    add     eax, r13d
    imul    eax, [rip+g_n]
    add     eax, r14d
    mov     rcx, [rip+g_off]
    test    r15d, r15d
    jnz     71f
    inc     dword ptr [rcx+rax*4+4]
    jmp     72f
71: mov     edx, [rcx+rax*4]            # cursor
    inc     dword ptr [rcx+rax*4]
    mov     rcx, [rip+g_tri]
    mov     [rcx+rdx*4], r12d
72: inc     r14d
    jmp     7b
.Lbg_ynext:
    inc     r13d
    jmp     6b
.Lbg_znext:
    inc     ebx
    jmp     5b
.Lbg_tnext:
    inc     r12d
    jmp     .Lbg_tri
.Lbg_pend:
    test    r15d, r15d
    jnz     .Lbg_fix
    mov     rcx, [rip+g_off]            # prefix sums (counts at +1)
    xor     eax, eax
    xor     edx, edx
8:  cmp     edx, [rsp+104]
    jae     81f
    add     eax, [rcx+rdx*4+4]
    mov     [rcx+rdx*4+4], eax
    inc     edx
    jmp     8b
81: lea     edi, [rax*4+8]
    call    fa
    test    rax, rax
    jz      .Lbg_fail
    mov     [rip+g_tri], rax
    mov     r15d, 1
    jmp     .Lbg_pass
.Lbg_fix:                               # cursors advanced: shift back
    mov     rcx, [rip+g_off]
    mov     edx, [rsp+104]
9:  test    edx, edx
    jz      91f
    mov     eax, [rcx+rdx*4-4]
    mov     [rcx+rdx*4], eax
    dec     edx
    jmp     9b
91: mov     dword ptr [rcx], 0
    mov     eax, 1
    jmp     .Lbg_out
.Lbg_fail:
    xor     eax, eax
.Lbg_out:
    add     rsp, 112
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# tri_cells(edi=global triangle, rsi=out u32[6]: x0 y0 z0 x1 y1 z1) - the
#   grid cells its bounding box covers (clamped)
tri_cells:
    push    rbx
    sub     rsp, 48
    mov     rbx, rsi
    lea     rsi, [rsp]
    call    tri_box
    xor     ecx, ecx
1:  movsd   xmm0, [rsp+rcx*8]
    lea     rax, [rip+g_min]
    subsd   xmm0, [rax+rcx*8]
    mulsd   xmm0, [rip+g_inv]
    subsd   xmm0, [rip+bd_pad]          # pad: touching boxes share a cell
    cvttsd2si rax, xmm0
    call    clamp_g
    mov     [rbx+rcx*4], eax
    movsd   xmm0, [rsp+24+rcx*8]
    lea     rax, [rip+g_min]
    subsd   xmm0, [rax+rcx*8]
    mulsd   xmm0, [rip+g_inv]
    addsd   xmm0, [rip+bd_pad]
    cvttsd2si rax, xmm0
    call    clamp_g
    mov     [rbx+12+rcx*4], eax
    inc     ecx
    cmp     ecx, 3
    jb      1b
    add     rsp, 48
    pop     rbx
    ret
clamp_g:
    test    rax, rax
    jns     1f
    xor     eax, eax
    ret
1:  mov     edx, [rip+g_n]
    dec     edx
    cmp     rax, rdx
    jbe     2f
    mov     eax, edx
2:  ret

# tri_tri(edi=A triangle, esi=B triangle, both global) -> eax = 0 ok, -1 fail
#   (records the segment and its points when they intersect)
tri_tri:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 88
    mov     [rsp+64], edi
    mov     [rsp+68], esi
    mov     rax, [rip+tri]
    lea     rcx, [rdi+rdi*2]
    mov     edx, [rax+rcx*4]
    mov     [rsp], edx                  # a0 a1 a2
    mov     edx, [rax+rcx*4+4]
    mov     [rsp+4], edx
    mov     edx, [rax+rcx*4+8]
    mov     [rsp+8], edx
    lea     rcx, [rsi+rsi*2]
    mov     edx, [rax+rcx*4]
    mov     [rsp+12], edx               # b0 b1 b2
    mov     edx, [rax+rcx*4+4]
    mov     [rsp+16], edx
    mov     edx, [rax+rcx*4+8]
    mov     [rsp+20], edx
    # quick reject on the boxes (doubles)
    call    box_overlap
    test    eax, eax
    jz      .Ltt_none
    # sides of the a's against B's plane, b's against A's plane
    xor     ebx, ebx
1:  mov     edi, [rsp+12]
    mov     esi, [rsp+16]
    mov     edx, [rsp+20]
    mov     ecx, [rsp+rbx*4]
    call    orient_sos
    mov     [rsp+24+rbx*4], eax         # sa
    mov     edi, [rsp]
    mov     esi, [rsp+4]
    mov     edx, [rsp+8]
    mov     ecx, [rsp+12+rbx*4]
    call    orient_sos
    mov     [rsp+36+rbx*4], eax         # sb
    inc     ebx
    cmp     ebx, 3
    jb      1b
    mov     eax, [rsp+24]
    cmp     eax, [rsp+28]
    jne     2f
    cmp     eax, [rsp+32]
    je      .Ltt_none
2:  mov     eax, [rsp+36]
    cmp     eax, [rsp+40]
    jne     3f
    cmp     eax, [rsp+44]
    je      .Ltt_none
3:  mov     dword ptr [rsp+48], 0       # endpoints found
    # A's edges through triangle B
    xor     ebx, ebx
4:  cmp     ebx, 3
    jae     5f
    lea     r12d, [rbx+1]
    cmp     r12d, 3
    jb      41f
    xor     r12d, r12d
41: mov     eax, [rsp+24+rbx*4]
    cmp     eax, [rsp+24+r12*4]
    je      49f
    mov     r13d, [rsp+rbx*4]           # edge (a_i, a_k)
    mov     r14d, [rsp+r12*4]
    lea     rdi, [rsp+12]
    mov     esi, r13d
    mov     edx, r14d
    call    seg_through
    test    eax, eax
    jz      49f
    mov     edi, [rsp+64]               # point (edge of A corner i, face B)
    mov     esi, ebx
    mov     edx, [rsp+68]
    lea     rcx, [rsp+12]
    call    make_point
    test    eax, eax
    js      .Ltt_fail
    mov     ecx, [rsp+48]
    cmp     ecx, 2
    jae     .Ltt_degen
    mov     [rsp+52+rcx*4], eax
    inc     dword ptr [rsp+48]
49: inc     ebx
    jmp     4b
5:  # B's edges through triangle A
    xor     ebx, ebx
6:  cmp     ebx, 3
    jae     7f
    lea     r12d, [rbx+1]
    cmp     r12d, 3
    jb      61f
    xor     r12d, r12d
61: mov     eax, [rsp+36+rbx*4]
    cmp     eax, [rsp+36+r12*4]
    je      69f
    mov     r13d, [rsp+12+rbx*4]
    mov     r14d, [rsp+12+r12*4]
    lea     rdi, [rsp]
    mov     esi, r13d
    mov     edx, r14d
    call    seg_through
    test    eax, eax
    jz      69f
    mov     edi, [rsp+68]
    mov     esi, ebx
    mov     edx, [rsp+64]
    lea     rcx, [rsp]
    call    make_point
    test    eax, eax
    js      .Ltt_fail
    mov     ecx, [rsp+48]
    cmp     ecx, 2
    jae     .Ltt_degen
    mov     [rsp+52+rcx*4], eax
    inc     dword ptr [rsp+48]
69: inc     ebx
    jmp     6b
7:  cmp     dword ptr [rsp+48], 0
    je      .Ltt_none
    cmp     dword ptr [rsp+48], 2
    jne     .Ltt_degen
    mov     eax, [rip+nseg]             # the segment, once per triangle
    add     eax, 2
    cmp     eax, [rip+cap_s]
    jae     .Ltt_fail
    mov     rdx, [rip+seg]
    mov     eax, [rip+nseg]
    lea     rcx, [rax+rax*2]
    mov     esi, [rsp+64]
    mov     [rdx+rcx*4], esi
    mov     esi, [rsp+52]
    mov     [rdx+rcx*4+4], esi
    mov     esi, [rsp+56]
    mov     [rdx+rcx*4+8], esi
    mov     esi, [rsp+68]
    mov     [rdx+rcx*4+12], esi
    mov     esi, [rsp+52]
    mov     [rdx+rcx*4+16], esi
    mov     esi, [rsp+56]
    mov     [rdx+rcx*4+20], esi
    add     dword ptr [rip+nseg], 2
.Ltt_none:
    xor     eax, eax
    jmp     9f
.Ltt_degen:
    mov     dword ptr [rip+fail_flag], 1
.Ltt_fail:
    mov     eax, -1
9:  add     rsp, 88
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# box_overlap([rsp+8+0..+20] = the caller's six vertices) -> eax = 1 unless
#   the snapped boxes are strictly apart (then no perturbation can join them)
box_overlap:
    push    rbx
    push    r12
    sub     rsp, 8
    xor     ebx, ebx                    # axis
1:  mov     r8, 0x7fffffffffffffff      # A min / max, B min / max
    mov     r9, 0x8000000000000000
    mov     r10, r8
    mov     r11, r9
    xor     r12d, r12d
2:  mov     edi, [rsp+32+r12*4]
    call    pt
    mov     rax, [rax+rbx*8]
    cmp     r12d, 3
    jae     3f
    cmp     rax, r8
    cmovl   r8, rax
    cmp     rax, r9
    cmovg   r9, rax
    jmp     4f
3:  cmp     rax, r10
    cmovl   r10, rax
    cmp     rax, r11
    cmovg   r11, rax
4:  inc     r12d
    cmp     r12d, 6
    jb      2b
    cmp     r10, r9                     # B min > A max
    jg      8f
    cmp     r8, r11                     # A min > B max
    jg      8f
    inc     ebx
    cmp     ebx, 3
    jb      1b
    mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# seg_through(rdi=&triangle u32[3], esi=p, edx=q) -> eax = 1 if segment pq
#   (crossing the triangle's plane) passes through the triangle: the three
#   orientations (p, q, t_i, t_i+1) agree
seg_through:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rbx, rdi
    mov     r12d, esi
    mov     r13d, edx
    mov     edi, r12d
    mov     esi, r13d
    mov     edx, [rbx]
    mov     ecx, [rbx+4]
    call    orient_sos
    mov     r14d, eax
    mov     edi, r12d
    mov     esi, r13d
    mov     edx, [rbx+4]
    mov     ecx, [rbx+8]
    call    orient_sos
    cmp     eax, r14d
    jne     8f
    mov     edi, r12d
    mov     esi, r13d
    mov     edx, [rbx+8]
    mov     ecx, [rbx]
    call    orient_sos
    cmp     eax, r14d
    jne     8f
    test    eax, eax
    jz      8f
    mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# add_inc(edi=edge, esi=point) -> eax = 1
add_inc:
    mov     eax, [rip+n_inc]
    mov     ecx, [rip+cap_p]
    add     ecx, ecx
    cmp     eax, ecx
    jae     1f
    mov     rcx, [rip+p_edge]
    mov     [rcx+rax*4], edi
    mov     rcx, [rip+inc_p]
    mov     [rcx+rax*4], esi
    inc     dword ptr [rip+n_inc]
    mov     eax, 1
    ret
1:  xor     eax, eax
    ret

# make_point(edi=triangle owning the edge, esi=its corner k (edge k->k+1),
#   edx=the other triangle, rcx=&other triangle's vertices) -> eax = global
#   vertex id of the intersection point (created once per (edge, face))
make_point:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 32
    mov     r12d, edi
    mov     r13d, esi
    mov     r14d, edx
    mov     r15, rcx
    mov     rax, [rip+te]               # edge id
    lea     rcx, [r12+r12*2]
    add     rcx, r13
    mov     ebx, [rax+rcx*4]
    mov     rsi, rbx                    # key: edge << 32 | face
    shl     rsi, 32
    or      rsi, r14
    mov     rdi, [rip+eh_p]
    call    eh_slot
    test    edx, edx
    jz      1f
    mov     eax, [rax]                  # known
    mov     [rsp+24], eax
    jmp     .Lmp_on
1:  mov     ecx, [rip+np_]
    cmp     ecx, [rip+cap_p]
    jae     .Lmp_fail
    mov     [rax], ecx
    mov     [rsp+24], ecx
    inc     dword ptr [rip+np_]
    mov     edi, ebx
    mov     esi, ecx
    call    add_inc
    test    eax, eax
    jz      .Lmp_fail
    mov     ecx, [rsp+24]
    # position: p + t (q - p), t = d(p) / (d(p) - d(q)) with exact dets; the
    #   edge runs lo -> hi (ev order) so t orders points along it
    mov     rax, [rip+ev]
    mov     ecx, [rax+rbx*8]
    mov     [rsp], ecx                  # lo
    mov     ecx, [rax+rbx*8+4]
    mov     [rsp+4], ecx                # hi
    mov     rdi, r15
    mov     esi, [rsp]
    mov     edx, [rsp+4]
    call    point_t
    movsd   xmm1, xmm0                  # t
    mov     ecx, [rsp+24]
    mov     rax, [rip+p_t]
    movsd   [rax+rcx*8], xmm1
    mov     rax, [rip+vd]
    mov     edx, [rsp]
    lea     rdx, [rdx+rdx*2]
    mov     r8d, [rsp+4]
    lea     r8, [r8+r8*2]
    mov     r9, [rip+p_pos]
    lea     r10, [rcx+rcx*2]
    xor     r11d, r11d
2:  movsd   xmm0, [rax+r8*8]
    subsd   xmm0, [rax+rdx*8]
    mulsd   xmm0, xmm1
    addsd   xmm0, [rax+rdx*8]
    movsd   [r9+r10*8], xmm0
    inc     rdx
    inc     r8
    inc     r10
    inc     r11d
    cmp     r11d, 3
    jb      2b
.Lmp_on:
    mov     eax, [rsp+24]
    add     eax, [rip+nv]
    jmp     9f
.Lmp_fail:
    mov     eax, -1
9:  add     rsp, 32
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.section .rodata
.align 8
bd_big:         .double 1.0e300
bd_nbig:        .double -1.0e300
bd_1001:        .double 1.001
bd_pad:         .double 0.001
.text

# cn(edi=id) -> eax = its canonical id (same position: same id, after the
#   exact predicates; the triangulation and the output work with these)
cn:
    mov     rax, [rip+canon]
    mov     eax, [rax+rdi*4]
    ret

# =============================================================================
#  Welding: points at the same place (on the snapped grid / 16) as a mesh
#  vertex or an earlier point become that one. The perturbation keeps them
#  apart symbolically, but the triangulation works with real positions.
# =============================================================================
# wq(rax=&double[3], rdi=out int64[3]) - the weld key on a lattice 16 times
#   finer than the grid; a position within 1/16 cell of a grid point (where
#   every vertex is) takes that grid point exactly
wq:
    xor     ecx, ecx
    xor     r8d, r8d                    # 1 = off the grid
1:  movsd   xmm0, [rax+rcx*8]
    lea     rdx, [rip+ctr]
    subsd   xmm0, [rdx+rcx*8]
    mulsd   xmm0, [rip+scl]
    movsd   [rdi+rcx*8], xmm0           # (scratch: grid units)
    cvtsd2si rdx, xmm0
    cvtsi2sd xmm1, rdx
    subsd   xmm1, xmm0
    andpd   xmm1, [rip+bd_abs]
    comisd  xmm1, [rip+bd_16th]
    jb      2f
    mov     r8d, 1
2:  inc     ecx
    cmp     ecx, 3
    jb      1b
    xor     ecx, ecx
3:  movsd   xmm0, [rdi+rcx*8]
    test    r8d, r8d
    jnz     4f
    cvtsd2si rdx, xmm0
    shl     rdx, 4
    jmp     5f
4:  mulsd   xmm0, [rip+bd_16]
    cvtsd2si rdx, xmm0
5:  mov     [rdi+rcx*8], rdx
    inc     ecx
    cmp     ecx, 3
    jb      3b
    ret

# wslot(rsi=&int64[3]) -> rax = &slot (u32: id + 1, 0 = empty) for the key
wslot:
    mov     rax, [rsi]
    imul    rax, rax, 0x5bd1e995
    mov     rdx, [rsi+8]
    imul    rdx, rdx, 0x27d4eb2f
    xor     rax, rdx
    mov     rdx, [rsi+16]
    imul    rdx, rdx, 0x165667b1
    xor     rax, rdx
    mov     rdx, rax
    shr     rdx, 29
    xor     rax, rdx
    and     eax, [rip+w_mask]
1:  mov     r8, [rip+w_tab]
    mov     edx, [r8+rax*4]
    test    edx, edx
    jz      3f
    dec     edx                         # compare the coordinates
    lea     rdx, [rdx+rdx*2]
    shl     rdx, 3
    add     rdx, [rip+w_q]
    mov     r9, [rdx]
    cmp     r9, [rsi]
    jne     2f
    mov     r9, [rdx+8]
    cmp     r9, [rsi+8]
    jne     2f
    mov     r9, [rdx+16]
    cmp     r9, [rsi+16]
    je      3f
2:  inc     eax
    and     eax, [rip+w_mask]
    jmp     1b
3:  lea     rax, [r8+rax*4]
    ret

weld_points:
    push    rbx
    push    r12
    push    r13
    mov     eax, [rip+nv]
    add     eax, [rip+np_]
    lea     r12d, [rax+rax]
    mov     ebx, 16
1:  cmp     ebx, r12d
    jae     2f
    add     ebx, ebx
    jmp     1b
2:  lea     edi, [rbx*4]
    call    fa
    test    rax, rax
    jz      8f
    mov     [rip+w_tab], rax
    lea     eax, [rbx-1]
    mov     [rip+w_mask], eax
    mov     edi, [rip+nv]
    add     edi, [rip+np_]
    imul    edi, edi, 24
    call    fa
    test    rax, rax
    jz      8f
    mov     [rip+w_q], rax
    mov     edi, [rip+nv]           # canonical id of every vertex and point
    add     edi, [rip+np_]
    lea     edi, [rdi*4+8]
    call    fa
    test    rax, rax
    jz      8f
    mov     [rip+canon], rax
    mov     ecx, [rip+nv]
    lea     rax, [rax+rcx*4]
    mov     [rip+pmap], rax
    xor     ebx, ebx                    # vertices, then points
3:  mov     eax, [rip+nv]
    add     eax, [rip+np_]
    cmp     ebx, eax
    jae     6f
    mov     edi, ebx
    call    vpos
    lea     rdi, [rbx+rbx*2]
    shl     rdi, 3
    add     rdi, [rip+w_q]
    mov     r12, rdi
    call    wq
    mov     rsi, r12
    call    wslot
    mov     edx, [rax]
    test    edx, edx
    jnz     4f
    lea     edx, [rbx+1]                # new: this one
    mov     [rax], edx
4:  dec     edx                         # the id it welds to
    mov     rax, [rip+canon]
    mov     [rax+rbx*4], edx
    inc     ebx
    jmp     3b
6:  mov     rdx, [rip+seg]              # the segments use the welded ids
    mov     r8, [rip+pmap]
    xor     ecx, ecx
7:  cmp     ecx, [rip+nseg]
    jae     71f
    lea     rax, [rcx+rcx*2]
    mov     r9d, [rdx+rax*4+4]
    sub     r9d, [rip+nv]
    mov     r9d, [r8+r9*4]
    mov     [rdx+rax*4+4], r9d
    mov     r9d, [rdx+rax*4+8]
    sub     r9d, [rip+nv]
    mov     r9d, [r8+r9*4]
    mov     [rdx+rax*4+8], r9d
    inc     ecx
    jmp     7b
71: mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  pop     r13
    pop     r12
    pop     rbx
    ret

.section .bss
.align 8
w_tab:          .skip 8
w_q:            .skip 8
pmap:           .skip 8
w_mask:         .skip 4
.align 8
canon:          .skip 8
.section .rodata
.align 8
bd_16th:        .double 0.0625
bd_16:          .double 16.0
bd_8th:         .double 0.125
.text

# =============================================================================
#  Splitting: every triangle with segments is re-triangulated in 2D
# =============================================================================
# vpos(edi=global vertex) -> rax = &double[3] (mesh vertex or point)
vpos:
    cmp     edi, [rip+nv]
    jae     1f
    mov     eax, edi
    lea     rax, [rax+rax*2]
    shl     rax, 3
    add     rax, [rip+vd]
    ret
1:  sub     edi, [rip+nv]
    mov     eax, edi
    lea     rax, [rax+rax*2]
    shl     rax, 3
    add     rax, [rip+p_pos]
    ret

split_triangles:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 40
    # segments grouped per triangle (CSR)
    mov     edi, [rip+nt]
    lea     edi, [rdi*4+8]
    call    fa
    test    rax, rax
    jz      .Lst_fail
    mov     [rip+ts_off], rax
    mov     r8, rax
    mov     rdx, [rip+seg]
    xor     ecx, ecx
1:  cmp     ecx, [rip+nseg]
    jae     2f
    lea     rax, [rcx+rcx*2]
    mov     eax, [rdx+rax*4]
    inc     dword ptr [r8+rax*4+4]
    inc     ecx
    jmp     1b
2:  xor     eax, eax
    xor     ecx, ecx
21: cmp     ecx, [rip+nt]
    jae     22f
    add     eax, [r8+rcx*4+4]
    mov     [r8+rcx*4+4], eax
    inc     ecx
    jmp     21b
22: mov     edi, [rip+nseg]
    lea     edi, [rdi*4+8]
    call    fa
    test    rax, rax
    jz      .Lst_fail
    mov     [rip+ts_seg], rax
    mov     r8, [rip+ts_off]            # fill with cursors (then shift)
    mov     rdx, [rip+seg]
    xor     ecx, ecx
23: cmp     ecx, [rip+nseg]
    jae     24f
    lea     rax, [rcx+rcx*2]
    mov     eax, [rdx+rax*4]
    mov     r9d, [r8+rax*4]
    inc     dword ptr [r8+rax*4]
    mov     r10, [rip+ts_seg]
    mov     [r10+r9*4], ecx
    inc     ecx
    jmp     23b
24: mov     ecx, [rip+nt]
25: test    ecx, ecx
    jz      26f
    mov     eax, [r8+rcx*4-4]
    mov     [r8+rcx*4], eax
    dec     ecx
    jmp     25b
26: mov     dword ptr [r8], 0
    call    share_edge_points
    test    eax, eax
    jz      .Lst_fail
    # points per edge (CSR), for the boundary of each triangle
    mov     edi, [rip+n_edge]
    lea     edi, [rdi*4+8]
    call    fa
    test    rax, rax
    jz      .Lst_fail
    mov     [rip+ep_off], rax
    mov     r8, rax
    mov     rdx, [rip+p_edge]
    xor     ecx, ecx
3:  cmp     ecx, [rip+n_inc]
    jae     31f
    mov     eax, [rdx+rcx*4]
    inc     dword ptr [r8+rax*4+4]
    inc     ecx
    jmp     3b
31: xor     eax, eax
    xor     ecx, ecx
32: cmp     ecx, [rip+n_edge]
    jae     33f
    add     eax, [r8+rcx*4+4]
    mov     [r8+rcx*4+4], eax
    inc     ecx
    jmp     32b
33: mov     edi, [rip+n_inc]
    lea     edi, [rdi*4+8]
    call    fa
    test    rax, rax
    jz      .Lst_fail
    mov     [rip+ep_pts], rax
    mov     r8, [rip+ep_off]
    mov     rdx, [rip+p_edge]
    xor     ecx, ecx
34: cmp     ecx, [rip+n_inc]
    jae     35f
    mov     eax, [rdx+rcx*4]
    mov     r9d, [r8+rax*4]
    inc     dword ptr [r8+rax*4]
    mov     r10, [rip+inc_p]
    mov     r11d, [r10+rcx*4]
    mov     r10, [rip+ep_pts]
    mov     [r10+r9*4], r11d
    inc     ecx
    jmp     34b
35: mov     ecx, [rip+n_edge]
36: test    ecx, ecx
    jz      37f
    mov     eax, [r8+rcx*4-4]
    mov     [r8+rcx*4], eax
    dec     ecx
    jmp     36b
37: mov     dword ptr [r8], 0
    # constrained edges set (for the classification)
    mov     edi, [rip+nseg]
    add     edi, 8
    call    eh_new
    test    rax, rax
    jz      .Lst_fail
    mov     [rip+eh_c], rax
    xor     ebx, ebx
4:  cmp     ebx, [rip+nseg]
    jae     41f
    mov     rdx, [rip+seg]
    lea     rax, [rbx+rbx*2]
    mov     edi, [rdx+rax*4+4]
    mov     esi, [rdx+rax*4+8]
    call    ukey
    mov     rsi, rax
    mov     rdi, [rip+eh_c]
    call    eh_slot
    mov     dword ptr [rax], 1
    inc     ebx
    jmp     4b
41: # fragments
    mov     eax, [rip+nseg]             # nt + 4 (segments + incidences)
    add     eax, [rip+n_inc]
    shl     eax, 2
    add     eax, [rip+nt]
    add     eax, 64
    mov     [rip+cap_fr], eax
    lea     edi, [rax*8]
    shl     edi, 1
    call    fa
    test    rax, rax
    jz      .Lst_fail
    mov     [rip+fr], rax
    mov     dword ptr [rip+nfr], 0
    xor     r12d, r12d                  # triangle
5:  cmp     r12d, [rip+nt]
    jae     .Lst_ok
    mov     r8, [rip+ts_off]
    mov     eax, [r8+r12*4]
    cmp     eax, [r8+r12*4+4]
    jne     51f
    mov     rax, [rip+tri]              # untouched: itself
    lea     rcx, [r12+r12*2]
    mov     r8, [rip+canon]
    mov     edi, [rax+rcx*4]
    mov     edi, [r8+rdi*4]
    mov     esi, [rax+rcx*4+4]
    mov     esi, [r8+rsi*4]
    mov     edx, [rax+rcx*4+8]
    mov     edx, [r8+rdx*4]
    mov     ecx, r12d
    call    add_frag
    test    eax, eax
    jz      .Lst_fail
    jmp     52f
51: mov     edi, r12d
    call    cdt_triangle
    test    eax, eax
    jz      .Lst_fail
52: inc     r12d
    jmp     5b
.Lst_ok:
    mov     eax, 1
    jmp     9f
.Lst_fail:
    mov     dword ptr [rip+fail_flag], 1
    xor     eax, eax
9:  add     rsp, 40
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# share_edge_points -> eax = 1. A segment end lying on a triangle's edge
#   that the triangle across uses as well: the curve crosses that edge
#   there, so the point joins the edge's list and both sides split the edge
#   at it. (Used by one side only, it is inside that triangle symbolically
#   and becomes a flat triangle there.)
share_edge_points:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 72
    mov     edi, [rip+n_edge]           # edge -> its two triangles
    shl     edi, 3
    add     edi, 8
    call    fa_fill_m1
    test    rax, rax
    jz      .Lse_fail
    mov     [rsp], rax
    xor     ecx, ecx
1:  mov     eax, [rip+nt]
    lea     eax, [rax+rax*2]
    cmp     ecx, eax
    jae     2f
    mov     rax, [rip+te]
    mov     eax, [rax+rcx*4]
    mov     edx, ecx                    # triangle = corner / 3
    imul    rdx, rdx, 0x55555556
    shr     rdx, 32
    mov     r8, [rsp]
    cmp     dword ptr [r8+rax*8], -1
    jne     11f
    mov     [r8+rax*8], edx
    jmp     12f
11: mov     [r8+rax*8+4], edx
12: inc     ecx
    jmp     1b
2:  xor     r12d, r12d                  # triangle
.Lse_tri:
    cmp     r12d, [rip+nt]
    jae     .Lse_ok
    mov     rax, [rip+ts_off]
    mov     r13d, [rax+r12*4]           # its segments
    mov     r14d, [rax+r12*4+4]
.Lse_seg:
    cmp     r13d, r14d
    jae     .Lse_tnext
    mov     dword ptr [rsp+8], 1        # end 1, 2
.Lse_end:
    mov     rax, [rip+ts_seg]
    mov     eax, [rax+r13*4]
    lea     rax, [rax+rax*2]
    mov     ecx, [rsp+8]
    add     rax, rcx
    mov     rdx, [rip+seg]
    mov     r15d, [rdx+rax*4]           # P
    cmp     r15d, [rip+nv]
    jb      .Lse_enext
    xor     ebx, ebx                    # edge k of the triangle
.Lse_edge:
    cmp     ebx, 3
    jae     .Lse_enext
    mov     rax, [rip+tri]
    lea     rcx, [r12+r12*2]
    lea     rax, [rax+rcx*4]
    mov     edi, [rax+rbx*4]            # u
    lea     edx, [rbx+1]
    cmp     edx, 3
    jb      3f
    xor     edx, edx
3:  mov     esi, [rax+rdx*4]            # v
    mov     [rsp+16], esi
    call    cn                          # (P may be welded to a corner)
    cmp     eax, r15d
    je      .Lse_enext
    mov     edi, [rsp+16]
    call    cn
    cmp     eax, r15d
    je      .Lse_enext
    mov     rax, [rip+tri]
    lea     rcx, [r12+r12*2]
    lea     rax, [rax+rcx*4]
    mov     edi, [rax+rbx*4]
    mov     esi, [rsp+16]
    mov     edx, r15d
    call    on_edge_d
    test    eax, eax
    jz      .Lse_knext
    mov     rax, [rip+te]               # the triangle across this edge
    lea     rcx, [r12+r12*2]
    add     rcx, rbx
    mov     ebp, [rax+rcx*4]            # edge
    mov     r8, [rsp]
    mov     eax, [r8+rbp*8]
    cmp     eax, r12d
    jne     4f
    mov     eax, [r8+rbp*8+4]
4:  test    eax, eax
    js      .Lse_knext
    mov     rcx, [rip+ts_off]           # does it use P too?
    mov     edx, [rcx+rax*4]
    mov     r9d, [rcx+rax*4+4]
5:  cmp     edx, r9d
    jae     .Lse_knext
    mov     rcx, [rip+ts_seg]
    mov     ecx, [rcx+rdx*4]
    lea     rcx, [rcx+rcx*2]
    mov     r10, [rip+seg]
    cmp     [r10+rcx*4+4], r15d
    je      6f
    cmp     [r10+rcx*4+8], r15d
    je      6f
    inc     edx
    jmp     5b
6:  mov     edi, ebp                    # yes: on the edge for both
    mov     esi, r15d
    sub     esi, [rip+nv]
    call    add_inc
    test    eax, eax
    jz      .Lse_fail
.Lse_knext:
    inc     ebx
    jmp     .Lse_edge
.Lse_enext:
    inc     dword ptr [rsp+8]
    cmp     dword ptr [rsp+8], 2
    jbe     .Lse_end
    inc     r13d
    jmp     .Lse_seg
.Lse_tnext:
    inc     r12d
    jmp     .Lse_tri
.Lse_ok:
    mov     eax, 1
    jmp     9f
.Lse_fail:
    xor     eax, eax
9:  add     rsp, 72
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# on_edge_d(edi=u, esi=v, edx=P) -> eax = 1 if P lies on segment u-v
#   (within the weld tolerance, strictly between the ends)
on_edge_d:
    push    rbx
    push    r12
    sub     rsp, 56
    mov     ebx, esi
    mov     r12d, edx
    call    vpos
    mov     [rsp+48], rax
    mov     edi, ebx
    call    vpos
    mov     rsi, rax
    mov     edi, r12d
    call    vpos
    mov     rdx, [rsp+48]
    xor     ecx, ecx                    # d = v - u, w = P - u
1:  movsd   xmm0, [rsi+rcx*8]
    subsd   xmm0, [rdx+rcx*8]
    movsd   [rsp+rcx*8], xmm0
    movsd   xmm0, [rax+rcx*8]
    subsd   xmm0, [rdx+rcx*8]
    movsd   [rsp+24+rcx*8], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      1b
    lea     rdi, [rsp]
    mov     rsi, rdi
    call    dot_d
    movsd   xmm7, xmm0                  # |d|^2
    lea     rdi, [rsp]
    lea     rsi, [rsp+24]
    call    dot_d                       # d . w strictly inside (0, |d|^2)
    xorpd   xmm1, xmm1
    comisd  xmm0, xmm1
    jbe     8f
    comisd  xmm0, xmm7
    jae     8f
    lea     rdi, [rsp]
    lea     rsi, [rsp+24]
    lea     rdx, [rsp]                  # (d is not needed after this)
    movsd   [rsp+48], xmm7
    call    cross_d
    lea     rdi, [rsp]
    mov     rsi, rdi
    call    dot_d                       # distance <= cell / 8 (the weld
    movsd   xmm1, [rip+cell]            #  tolerance: what welded there is
    mulsd   xmm1, [rip+bd_8th]          #  on the edge): |d x w|^2 <=
    mulsd   xmm1, xmm1                  #  (tol |d|)^2
    mulsd   xmm1, [rsp+48]
    comisd  xmm0, xmm1
    ja      8f
    mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 56
    pop     r12
    pop     rbx
    ret

# add_frag(edi, esi, edx = vertices, ecx = source triangle) -> eax = 1
add_frag:
    cmp     edi, esi                    # collapsed by the welding: nothing
    je      2f
    cmp     esi, edx
    je      2f
    cmp     edx, edi
    je      2f
    mov     eax, [rip+nfr]
    cmp     eax, [rip+cap_fr]
    jae     1f
    mov     r8, [rip+fr]
    shl     rax, 4
    mov     [r8+rax], edi
    mov     [r8+rax+4], esi
    mov     [r8+rax+8], edx
    mov     [r8+rax+12], ecx
    inc     dword ptr [rip+nfr]
2:  mov     eax, 1
    ret
1:  xor     eax, eax
    ret

# ---- 2D constrained triangulation of one triangle ---------------------------
# cdt_add_pt(edi=global vertex) -> eax = local index (deduplicated)
cdt_add_pt:
    push    rbx
    mov     ebx, edi
    xor     ecx, ecx
1:  cmp     ecx, [rip+cdt_n]
    jae     2f
    lea     rax, [rip+cdt_id]
    cmp     [rax+rcx*4], ebx
    je      8f
    inc     ecx
    jmp     1b
2:  cmp     ecx, CDT_MAXP
    jae     7f
    lea     rax, [rip+cdt_id]
    mov     [rax+rcx*4], ebx
    inc     dword ptr [rip+cdt_n]
    push    rcx
    mov     edi, ebx
    call    vpos
    pop     rcx
    movzx   r8d, byte ptr [rip+cdt_ax]
    movzx   r9d, byte ptr [rip+cdt_ax+1]
    movsd   xmm0, [rax+r8*8]
    movsd   xmm1, [rax+r9*8]
    lea     rax, [rip+cdt_xy]
    mov     rdx, rcx
    shl     rdx, 4
    movsd   [rax+rdx], xmm0
    movsd   [rax+rdx+8], xmm1
8:  mov     eax, ecx
    pop     rbx
    ret
7:  mov     eax, -1
    pop     rbx
    ret

# o2(edi=i, esi=j, edx=k local) -> xmm0 = orient2d (CCW positive, flipped
#   projections already accounted for)
o2:
    lea     rax, [rip+cdt_xy]
    shl     rdi, 4
    shl     rsi, 4
    shl     rdx, 4
    movsd   xmm0, [rax+rsi]
    subsd   xmm0, [rax+rdi]
    movsd   xmm1, [rax+rdx+8]
    subsd   xmm1, [rax+rdi+8]
    mulsd   xmm0, xmm1
    movsd   xmm2, [rax+rsi+8]
    subsd   xmm2, [rax+rdi+8]
    movsd   xmm3, [rax+rdx]
    subsd   xmm3, [rax+rdi]
    mulsd   xmm2, xmm3
    subsd   xmm0, xmm2
    cmp     dword ptr [rip+cdt_flip], 0
    je      1f
    xorpd   xmm0, [rip+bd_sign]
1:  ret

# cdt_triangle(edi=global triangle) -> eax = 1
cdt_triangle:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 56
    mov     r12d, edi
    mov     dword ptr [rip+cdt_n], 0
    mov     dword ptr [rip+cdt_nt], 0
    # projection: drop the dominant axis of the normal (double)
    mov     rax, [rip+tri]
    lea     rcx, [r12+r12*2]
    mov     edi, [rax+rcx*4]
    call    vpos
    mov     r13, rax
    mov     rax, [rip+tri]
    lea     rcx, [r12+r12*2]
    mov     edi, [rax+rcx*4+4]
    call    vpos
    mov     r14, rax
    mov     rax, [rip+tri]
    lea     rcx, [r12+r12*2]
    mov     edi, [rax+rcx*4+8]
    call    vpos
    mov     r15, rax
    xor     ecx, ecx                    # e1 = b - a, e2 = c - a
1:  movsd   xmm0, [r14+rcx*8]
    subsd   xmm0, [r13+rcx*8]
    movsd   [rsp+rcx*8], xmm0
    movsd   xmm0, [r15+rcx*8]
    subsd   xmm0, [r13+rcx*8]
    movsd   [rsp+24+rcx*8], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      1b
    movsd   xmm0, [rsp+8]               # n = e1 x e2
    mulsd   xmm0, [rsp+40]
    movsd   xmm1, [rsp+16]
    mulsd   xmm1, [rsp+32]
    subsd   xmm0, xmm1                  # nx
    movsd   xmm2, [rsp+16]
    mulsd   xmm2, [rsp+24]
    movsd   xmm1, [rsp]
    mulsd   xmm1, [rsp+40]
    subsd   xmm2, xmm1                  # ny
    movsd   xmm3, [rsp]
    mulsd   xmm3, [rsp+32]
    movsd   xmm1, [rsp+8]
    mulsd   xmm1, [rsp+24]
    subsd   xmm3, xmm1                  # nz
    movsd   [rsp], xmm0
    movsd   [rsp+8], xmm2
    movsd   [rsp+16], xmm3
    movsd   xmm4, xmm0
    andpd   xmm4, [rip+bd_abs]
    movsd   xmm5, xmm2
    andpd   xmm5, [rip+bd_abs]
    movsd   xmm6, xmm3
    andpd   xmm6, [rip+bd_abs]
    xor     ebx, ebx                    # dominant axis
    movsd   xmm7, xmm4
    comisd  xmm5, xmm7
    jbe     2f
    mov     ebx, 1
    movsd   xmm7, xmm5
2:  comisd  xmm6, xmm7
    jbe     3f
    mov     ebx, 2
3:  lea     rax, [rip+s_axes]           # the other two (cyclic): CCW keeps sign
    mov     cl, [rax+rbx*2]
    mov     [rip+cdt_ax], cl
    mov     cl, [rax+rbx*2+1]
    mov     [rip+cdt_ax+1], cl
    mov     dword ptr [rip+cdt_flip], 0
    movsd   xmm0, [rsp+rbx*8]           # normal along the dropped axis < 0:
    xorpd   xmm1, xmm1                  # the projection is mirrored
    comisd  xmm0, xmm1
    jae     4f
    mov     dword ptr [rip+cdt_flip], 1
4:  # corners (canonical: a corner may share its place with the other mesh)
    mov     rax, [rip+tri]
    lea     rcx, [r12+r12*2]
    mov     edi, [rax+rcx*4]
    call    cn
    mov     edi, eax
    call    cdt_add_pt
    mov     rax, [rip+tri]
    lea     rcx, [r12+r12*2]
    mov     edi, [rax+rcx*4+4]
    call    cn
    mov     edi, eax
    call    cdt_add_pt
    mov     rax, [rip+tri]
    lea     rcx, [r12+r12*2]
    mov     edi, [rax+rcx*4+8]
    call    cn
    mov     edi, eax
    call    cdt_add_pt
    cmp     dword ptr [rip+cdt_n], 3    # collapsed: nothing to cut
    jb      .Lct_ok
    lea     rax, [rip+cdt_t]
    mov     dword ptr [rax], 0
    mov     dword ptr [rax+4], 1
    mov     dword ptr [rax+8], 2
    mov     dword ptr [rip+cdt_nt], 1
    xor     edi, edi                    # its area (the scale of "flat")
    mov     esi, 1
    mov     edx, 2
    call    o2
    andpd   xmm0, [rip+bd_abs]
    movsd   [rip+cdt_area0], xmm0
    # points on the three edges, then the segments' interior points
    xor     ebx, ebx
5:  cmp     ebx, 3
    jae     6f
    mov     edi, r12d
    mov     esi, ebx
    call    cdt_edge_pts
    test    eax, eax
    jz      .Lct_fail
    inc     ebx
    jmp     5b
6:  mov     rax, [rip+ts_off]
    mov     r13d, [rax+r12*4]
    mov     r14d, [rax+r12*4+4]
61: cmp     r13d, r14d
    jae     7f
    mov     rax, [rip+ts_seg]
    mov     ecx, [rax+r13*4]
    mov     rdx, [rip+seg]
    lea     rcx, [rcx+rcx*2]
    mov     edi, [rdx+rcx*4+4]
    mov     [rsp+48], ecx
    call    cdt_insert
    test    eax, eax
    jz      .Lct_fail
    mov     ecx, [rsp+48]
    mov     rdx, [rip+seg]
    mov     edi, [rdx+rcx*4+8]
    call    cdt_insert
    test    eax, eax
    jz      .Lct_fail
    inc     r13d
    jmp     61b
7:  # the segments as edges (flips)
    mov     rax, [rip+ts_off]
    mov     r13d, [rax+r12*4]
71: cmp     r13d, r14d
    jae     8f
    mov     rax, [rip+ts_seg]
    mov     ecx, [rax+r13*4]
    mov     rdx, [rip+seg]
    lea     rcx, [rcx+rcx*2]
    mov     edi, [rdx+rcx*4+4]
    mov     esi, [rdx+rcx*4+8]
    call    cdt_force
    test    eax, eax
    jz      .Lct_fail
    inc     r13d
    jmp     71b
8:  # out: the local triangles with global ids, B / A source kept
    xor     ebx, ebx
81: cmp     ebx, [rip+cdt_nt]
    jae     .Lct_ok
    lea     rax, [rip+cdt_t]
    lea     rcx, [rbx+rbx*2]
    lea     rdx, [rip+cdt_id]
    mov     edi, [rax+rcx*4]
    mov     edi, [rdx+rdi*4]
    mov     esi, [rax+rcx*4+4]
    mov     esi, [rdx+rsi*4]
    mov     r8d, [rax+rcx*4+8]
    mov     edx, [rdx+r8*4]
    mov     ecx, r12d
    call    add_frag
    test    eax, eax
    jz      .Lct_fail
    inc     ebx
    jmp     81b
.Lct_ok:
    mov     eax, 1
    jmp     9f
.Lct_fail:
    xor     eax, eax
9:  add     rsp, 56
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# cdt_edge_pts(edi=triangle, esi=corner k) -> eax = 1: the points on its
#   edge k -> k+1, in order along it, each splitting the last piece - they
#   are on that edge by construction, whatever the doubles say
cdt_edge_pts:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 56
    mov     r12d, edi
    mov     r13d, esi
    lea     eax, [r13+1]                # local corners k, k + 1
    cmp     eax, 3
    jb      1f
    xor     eax, eax
1:  mov     [rsp+4], eax                # v (local)
    mov     rcx, [rip+tri]
    lea     rdx, [r12+r12*2]
    lea     rcx, [rcx+rdx*4]
    mov     edi, [rcx+r13*4]
    mov     esi, [rcx+rax*4]
    mov     [rsp+8], esi
    call    vpos
    mov     [rsp+16], rax               # pu
    mov     edi, [rsp+8]
    call    vpos
    mov     rdx, [rsp+16]
    xor     ecx, ecx                    # d = pv - pu
2:  movsd   xmm0, [rax+rcx*8]
    subsd   xmm0, [rdx+rcx*8]
    movsd   [rsp+24+rcx*8], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      2b
    mov     rax, [rip+te]               # the points of this edge, with t
    lea     rcx, [r12+r12*2]
    add     rcx, r13
    mov     ecx, [rax+rcx*4]
    mov     rax, [rip+ep_off]
    mov     r14d, [rax+rcx*4]
    mov     r15d, [rax+rcx*4+4]
    xor     ebx, ebx                    # count
3:  cmp     r14d, r15d
    jae     4f
    cmp     ebx, CDT_MAXP
    jae     .Lep_fail
    mov     rax, [rip+ep_pts]
    mov     edi, [rax+r14*4]
    mov     rax, [rip+pmap]
    mov     edi, [rax+rdi*4]
    lea     rax, [rip+es_id]
    mov     [rax+rbx*4], edi
    call    vpos
    mov     rdx, [rsp+16]
    xorpd   xmm0, xmm0
    xor     ecx, ecx
31: movsd   xmm1, [rax+rcx*8]
    subsd   xmm1, [rdx+rcx*8]
    mulsd   xmm1, [rsp+24+rcx*8]
    addsd   xmm0, xmm1
    inc     ecx
    cmp     ecx, 3
    jb      31b
    lea     rax, [rip+es_t]
    movsd   [rax+rbx*8], xmm0
    inc     ebx                         # insertion sort by t
    lea     ecx, [rbx-1]
32: test    ecx, ecx
    jz      33f
    lea     rax, [rip+es_t]
    movsd   xmm1, [rax+rcx*8-8]
    comisd  xmm1, [rax+rcx*8]
    jbe     33f
    movsd   xmm2, [rax+rcx*8]
    movsd   [rax+rcx*8], xmm1
    movsd   [rax+rcx*8-8], xmm2
    lea     rax, [rip+es_id]
    mov     edx, [rax+rcx*4-4]
    mov     edi, [rax+rcx*4]
    mov     [rax+rcx*4], edx
    mov     [rax+rcx*4-4], edi
    dec     ecx
    jmp     32b
33: inc     r14d
    jmp     3b
4:  mov     [rsp], r13d                 # prev (local), walking u -> v
    xor     r14d, r14d
5:  cmp     r14d, ebx
    jae     .Lep_ok
    mov     eax, [rip+cdt_n]
    mov     [rsp+12], eax
    lea     rax, [rip+es_id]
    mov     edi, [rax+r14*4]
    call    cdt_add_pt
    test    eax, eax
    js      .Lep_fail
    cmp     eax, [rsp+12]               # known (a corner, or twice): skip
    jb      6f
    mov     ebp, eax                    # P
    mov     edi, [rsp]
    mov     esi, [rsp+4]
    call    cdt_find_edge               # the piece prev -> v
    test    eax, eax
    js      .Lep_fail
    mov     r15d, edx                   # w
    mov     edi, eax                    # (prev, P, w), (P, v, w)
    mov     esi, [rsp]
    mov     edx, ebp
    mov     ecx, r15d
    call    cdt_set
    mov     edi, -1
    mov     esi, ebp
    mov     edx, [rsp+4]
    mov     ecx, r15d
    call    cdt_set
    test    eax, eax
    jz      .Lep_fail
    mov     [rsp], ebp
6:  inc     r14d
    jmp     5b
.Lep_ok:
    mov     eax, 1
    jmp     9f
.Lep_fail:
    xor     eax, eax
9:  add     rsp, 56
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# near_edge(edi=a, esi=b, edx=p local, xmm0=threshold from the triangle's
#   area) -> eax = 1 if p is on a-b: |o2| within that, or within 1e-7 of the
#   edge's length (computed edge points carry rounding a few orders above
#   that; a point taken off its line by it would leave a sliver no flip can
#   repair)
near_edge:
    push    rbx
    push    r12
    sub     rsp, 24
    movsd   [rsp], xmm0
    mov     ebx, edi
    mov     r12d, esi
    call    o2
    andpd   xmm0, [rip+bd_abs]
    movsd   [rsp+8], xmm0
    lea     rax, [rip+cdt_xy]
    mov     ecx, ebx
    shl     ecx, 4
    mov     edx, r12d
    shl     edx, 4
    movsd   xmm1, [rax+rdx]
    subsd   xmm1, [rax+rcx]
    movsd   xmm2, [rax+rdx+8]
    subsd   xmm2, [rax+rcx+8]
    mulsd   xmm1, xmm1
    mulsd   xmm2, xmm2
    addsd   xmm1, xmm2
    mulsd   xmm1, [rip+cf_edge]
    maxsd   xmm1, [rsp]
    xor     eax, eax
    movsd   xmm0, [rsp+8]
    comisd  xmm0, xmm1
    setbe   al
    add     rsp, 24
    pop     r12
    pop     rbx
    ret

# cdt_insert(edi=global vertex) -> eax = 1: split the triangle (or edge)
#   holding it
cdt_insert:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 24
    mov     eax, [rip+cdt_n]
    mov     [rsp], eax
    call    cdt_add_pt
    test    eax, eax
    js      .Lci_fail
    cmp     eax, [rsp]                  # already there
    jb      .Lci_ok
    mov     r12d, eax                   # p
    # the triangle containing p (the most interior one wins)
    mov     r13d, -1
    movsd   xmm7, [rip+bd_nbig]         # best min-orientation
    xor     ebx, ebx
1:  cmp     ebx, [rip+cdt_nt]
    jae     2f
    lea     rax, [rip+cdt_t]
    lea     rcx, [rbx+rbx*2]
    mov     r14d, [rax+rcx*4]
    mov     r15d, [rax+rcx*4+4]
    mov     ebp, [rax+rcx*4+8]
    mov     edi, r14d
    mov     esi, r15d
    mov     edx, r12d
    call    o2
    movsd   [rsp+8], xmm0
    mov     edi, r15d
    mov     esi, ebp
    mov     edx, r12d
    call    o2
    minsd   xmm0, [rsp+8]
    movsd   [rsp+8], xmm0
    mov     edi, ebp
    mov     esi, r14d
    mov     edx, r12d
    call    o2
    minsd   xmm0, [rsp+8]
    movsd   [rsp+8], xmm0
    mov     edi, r14d                   # a flat triangle only when nothing
    mov     esi, r15d                   #  else holds the point
    mov     edx, ebp
    call    o2
    andpd   xmm0, [rip+bd_abs]
    movsd   xmm1, [rip+cdt_area0]
    mulsd   xmm1, [rip+bd_flat]
    comisd  xmm0, xmm1
    movsd   xmm0, [rsp+8]
    ja      12f
    subsd   xmm0, [rip+bd_flatpen]
12: comisd  xmm0, xmm7
    jbe     11f
    movsd   xmm7, xmm0
    mov     r13d, ebx
11: inc     ebx
    jmp     1b
2:  test    r13d, r13d
    js      .Lci_fail
    # on an edge (relative to the triangle's size)?  find the edge whose
    #   orientation is near zero
    lea     rax, [rip+cdt_t]
    lea     rcx, [r13+r13*2]
    mov     r14d, [rax+rcx*4]
    mov     r15d, [rax+rcx*4+4]
    mov     ebp, [rax+rcx*4+8]
    mov     edi, r14d                   # area scale
    mov     esi, r15d
    mov     edx, ebp
    call    o2
    andpd   xmm0, [rip+bd_abs]
    mulsd   xmm0, [rip+bd_rel]
    movsd   [rsp+16], xmm0
    mov     edi, r14d
    mov     esi, r15d
    mov     edx, r12d
    movsd   xmm0, [rsp+16]
    call    near_edge
    test    eax, eax
    jnz     .Lci_e0
    mov     edi, r15d
    mov     esi, ebp
    mov     edx, r12d
    movsd   xmm0, [rsp+16]
    call    near_edge
    test    eax, eax
    jnz     .Lci_e1
    mov     edi, ebp
    mov     esi, r14d
    mov     edx, r12d
    movsd   xmm0, [rsp+16]
    call    near_edge
    test    eax, eax
    jnz     .Lci_e2
.Lci_inner:                             # interior: (a b p) (b c p) (c a p)
    mov     edi, r13d
    mov     esi, r14d
    mov     edx, r15d
    mov     ecx, r12d
    call    cdt_set
    mov     edi, -1
    mov     esi, r15d
    mov     edx, ebp
    mov     ecx, r12d
    call    cdt_set
    test    eax, eax
    jz      .Lci_fail
    mov     edi, -1
    mov     esi, ebp
    mov     edx, r14d
    mov     ecx, r12d
    call    cdt_set
    test    eax, eax
    jz      .Lci_fail
    jmp     .Lci_ok
.Lci_e0:                                # on edge (a, b)
    mov     edi, r14d
    mov     esi, r15d
    mov     edx, ebp
    jmp     .Lci_edge
.Lci_e1:                                # (b, c)
    mov     edi, r15d
    mov     esi, ebp
    mov     edx, r14d
    jmp     .Lci_edge
.Lci_e2:                                # (c, a)
    mov     edi, ebp
    mov     esi, r14d
    mov     edx, r15d
.Lci_edge:                              # edge u v, opposite w, triangle r13
    mov     [rsp+8], edi
    mov     [rsp+12], esi
    mov     ebx, edx
    cmp     dword ptr [rip+cdt_onedge], 0
    jne     1f
    mov     edi, [rsp+12]               # a point that only looks to be on the
    mov     esi, [rsp+8]                #  triangle's own boundary is inside it
    call    cdt_find_edge               #  symbolically: a flat triangle, not
    test    eax, eax                    #  a split the neighbour cannot see
    js      .Lci_inner
1:    mov     edi, r13d                   # (u p w), (p v w)
    mov     esi, [rsp+8]
    mov     edx, r12d
    mov     ecx, ebx
    call    cdt_set
    mov     edi, -1
    mov     esi, r12d
    mov     edx, [rsp+12]
    mov     ecx, ebx
    call    cdt_set
    test    eax, eax
    jz      .Lci_fail
    mov     edi, [rsp+12]               # the neighbour across (v, u)
    mov     esi, [rsp+8]
    call    cdt_find_edge               # eax = triangle, edx = third vertex
    test    eax, eax
    js      .Lci_ok                     # (a boundary edge)
    mov     r13d, eax
    mov     ebx, edx
    mov     edi, r13d                   # (v p x), (p u x)
    mov     esi, [rsp+12]
    mov     edx, r12d
    mov     ecx, ebx
    call    cdt_set
    mov     edi, -1
    mov     esi, r12d
    mov     edx, [rsp+8]
    mov     ecx, ebx
    call    cdt_set
    test    eax, eax
    jz      .Lci_fail
.Lci_ok:
    mov     eax, 1
    jmp     9f
.Lci_fail:
    xor     eax, eax
9:  add     rsp, 24
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# cdt_set(edi=triangle or -1 for a new one, esi, edx, ecx = a b c) -> eax = 1
cdt_set:
    test    edi, edi
    jns     1f
    mov     edi, [rip+cdt_nt]
    cmp     edi, CDT_MAXT
    jae     8f
    inc     dword ptr [rip+cdt_nt]
1:  lea     rax, [rip+cdt_t]
    lea     r8, [rdi+rdi*2]
    mov     [rax+r8*4], esi
    mov     [rax+r8*4+4], edx
    mov     [rax+r8*4+8], ecx
    mov     eax, 1
    ret
8:  xor     eax, eax
    ret

# cdt_find_edge(edi=u, esi=v) -> eax = triangle with the directed edge u->v
#   (or -1), edx = its third vertex
cdt_find_edge:
    xor     ecx, ecx
    lea     r8, [rip+cdt_t]
1:  cmp     ecx, [rip+cdt_nt]
    jae     8f
    lea     rax, [rcx+rcx*2]
    xor     r9d, r9d
2:  cmp     r9d, 3
    jae     3f
    lea     r10d, [r9+1]
    cmp     r10d, 3
    jb      21f
    xor     r10d, r10d
21: lea     r11, [rax+r9]
    cmp     [r8+r11*4], edi
    jne     22f
    lea     r11, [rax+r10]
    cmp     [r8+r11*4], esi
    jne     22f
    lea     r10d, [r10+1]               # the third
    cmp     r10d, 3
    jb      23f
    xor     r10d, r10d
23: lea     r11, [rax+r10]
    mov     edx, [r8+r11*4]
    mov     eax, ecx
    ret
22: inc     r9d
    jmp     2b
3:  inc     ecx
    jmp     1b
8:  mov     eax, -1
    ret

# cdt_force(edi=global p, esi=global q) -> eax = 1 when the edge p-q exists
#   (flipping edges that cross it, Sloan)
cdt_force:
    cmp     edi, esi                    # welded to one point: nothing to do
    jne     1f
    mov     eax, 1
    ret
1:  push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 40
    mov     ebx, esi
    call    cdt_local
    test    eax, eax
    js      .Lcf_fail
    mov     r12d, eax                   # p (local)
    mov     edi, ebx
    call    cdt_local
    test    eax, eax
    js      .Lcf_fail
    mov     r13d, eax                   # q
    mov     dword ptr [rsp+32], 0       # guard
    mov     dword ptr [rsp+24], 0       # where the scan starts (round robin:
.Lcf_loop:                              #  an edge just made is not undone)
    inc     dword ptr [rsp+32]
    cmp     dword ptr [rsp+32], 20000
    ja      .Lcf_fail
    mov     edi, r12d                   # done?
    mov     esi, r13d
    call    cdt_find_edge
    test    eax, eax
    jns     .Lcf_ok
    mov     edi, r13d
    mov     esi, r12d
    call    cdt_find_edge
    test    eax, eax
    jns     .Lcf_ok
    # an edge (a, b) crossing p-q whose quad is convex: flip it - first
    #   looking for flips whose new edge no longer crosses p-q
    mov     dword ptr [rsp+28], 0
.Lcf_pass:
    mov     dword ptr [rsp+36], 0
1:  mov     eax, [rsp+36]
    cmp     eax, [rip+cdt_nt]
    jae     .Lcf_nextpass
    add     eax, [rsp+24]
    xor     edx, edx
    div     dword ptr [rip+cdt_nt]
    mov     ebx, edx
    xor     r14d, r14d
2:  cmp     r14d, 3
    jae     3f
    lea     rax, [rip+cdt_t]
    lea     rcx, [rbx+rbx*2]
    lea     rax, [rax+rcx*4]
    mov     r15d, [rax+r14*4]           # a
    lea     edx, [r14+1]
    cmp     edx, 3
    jb      21f
    xor     edx, edx
21: mov     ebp, [rax+rdx*4]            # b
    lea     edx, [rdx+1]
    cmp     edx, 3
    jb      22f
    xor     edx, edx
22: mov     edx, [rax+rdx*4]
    mov     [rsp+8], edx                # c (third of this triangle)
    cmp     r15d, r12d                  # edges at p or q cannot cross
    je      29f
    cmp     r15d, r13d
    je      29f
    cmp     ebp, r12d
    je      29f
    cmp     ebp, r13d
    je      29f
    mov     edi, r12d                   # a, b on opposite sides of p-q
    mov     esi, r13d
    mov     edx, r15d
    call    o2
    movsd   [rsp+16], xmm0
    mov     edi, r12d
    mov     esi, r13d
    mov     edx, ebp
    call    o2
    mulsd   xmm0, [rsp+16]
    xorpd   xmm1, xmm1
    comisd  xmm0, xmm1
    jae     29f
    mov     edi, r15d                   # p, q on opposite sides of a-b
    mov     esi, ebp
    mov     edx, r12d
    call    o2
    movsd   [rsp+16], xmm0
    mov     edi, r15d
    mov     esi, ebp
    mov     edx, r13d
    call    o2
    mulsd   xmm0, [rsp+16]
    xorpd   xmm1, xmm1
    comisd  xmm0, xmm1
    jae     29f
    mov     edi, ebp                    # the other triangle (b, a, d)
    mov     esi, r15d
    call    cdt_find_edge
    test    eax, eax
    js      29f
    mov     [rsp+12], eax
    mov     [rsp+4], edx                # d
    mov     edi, [rsp+8]                # convex: c-d crosses a-b
    mov     esi, edx
    mov     edx, r15d
    call    o2
    movsd   [rsp+16], xmm0
    mov     edi, [rsp+8]
    mov     esi, [rsp+4]
    mov     edx, ebp
    call    o2
    mulsd   xmm0, [rsp+16]
    xorpd   xmm1, xmm1
    comisd  xmm0, xmm1
    jae     29f
    cmp     dword ptr [rsp+28], 0       # first pass: would c-d still cross?
    jne     28f
    mov     eax, [rsp+8]
    cmp     eax, r12d
    je      28f
    cmp     eax, r13d
    je      28f
    mov     eax, [rsp+4]
    cmp     eax, r12d
    je      28f
    cmp     eax, r13d
    je      28f
    mov     edi, r12d
    mov     esi, r13d
    mov     edx, [rsp+8]
    call    o2
    movsd   [rsp+16], xmm0
    mov     edi, r12d
    mov     esi, r13d
    mov     edx, [rsp+4]
    call    o2
    mulsd   xmm0, [rsp+16]
    xorpd   xmm1, xmm1
    comisd  xmm0, xmm1
    jae     28f
    mov     edi, [rsp+8]
    mov     esi, [rsp+4]
    mov     edx, r12d
    call    o2
    movsd   [rsp+16], xmm0
    mov     edi, [rsp+8]
    mov     esi, [rsp+4]
    mov     edx, r13d
    call    o2
    mulsd   xmm0, [rsp+16]
    xorpd   xmm1, xmm1
    comisd  xmm0, xmm1
    jb      29f                         # it would: later
28: lea     eax, [rbx+1]
    mov     [rsp+24], eax
    mov     edi, ebx                    # flip: (a, d, c), (d, b, c)
    mov     esi, r15d
    mov     edx, [rsp+4]
    mov     ecx, [rsp+8]
    call    cdt_set
    mov     edi, [rsp+12]
    mov     esi, [rsp+4]
    mov     edx, ebp
    mov     ecx, [rsp+8]
    call    cdt_set
    jmp     .Lcf_loop
29: inc     r14d
    jmp     2b
3:  inc     dword ptr [rsp+36]
    jmp     1b
.Lcf_nextpass:
    cmp     dword ptr [rsp+28], 0
    jne     .Lcf_split
    mov     dword ptr [rsp+28], 1
    jmp     .Lcf_pass
.Lcf_split:
    # nothing crosses p-q strictly: it runs through a vertex v (a point
    #   that is on it in fact) - recover p-v and v-q
    cmp     dword ptr [rip+cf_depth], 64
    jae     .Lcf_fail
    lea     rax, [rip+cdt_xy]
    mov     ecx, r12d
    shl     ecx, 4
    mov     edx, r13d
    shl     edx, 4
    movsd   xmm4, [rax+rdx]             # d = q - p, L2 = d . d
    subsd   xmm4, [rax+rcx]
    movsd   xmm5, [rax+rdx+8]
    subsd   xmm5, [rax+rcx+8]
    movsd   xmm6, xmm4
    mulsd   xmm6, xmm4
    movsd   xmm7, xmm5
    mulsd   xmm7, xmm5
    addsd   xmm6, xmm7
    xorpd   xmm7, xmm7
    comisd  xmm6, xmm7
    jbe     .Lcf_fail
    mov     ebp, -1                     # the v nearest p
    movsd   xmm8, [rip+cf_two]
    xor     r14d, r14d
51: cmp     r14d, [rip+cdt_n]
    jae     52f
    cmp     r14d, r12d
    je      53f
    cmp     r14d, r13d
    je      53f
    mov     r15d, r14d
    shl     r15d, 4
    movsd   xmm0, [rax+r15]             # w = v - p
    subsd   xmm0, [rax+rcx]
    movsd   xmm1, [rax+r15+8]
    subsd   xmm1, [rax+rcx+8]
    movsd   xmm2, xmm0                  # t = w . d / L2
    mulsd   xmm2, xmm4
    movsd   xmm3, xmm1
    mulsd   xmm3, xmm5
    addsd   xmm2, xmm3
    divsd   xmm2, xmm6
    comisd  xmm2, [rip+cf_eps]
    jbe     53f
    movsd   xmm3, [rip+cf_one]
    subsd   xmm3, [rip+cf_eps]
    comisd  xmm2, xmm3
    jae     53f
    mulsd   xmm0, xmm5                  # cross = wx dy - wy dx; on the line
    mulsd   xmm1, xmm4                  #  if cross^2 <= 1e-18 L2^2
    subsd   xmm0, xmm1
    mulsd   xmm0, xmm0
    movsd   xmm3, xmm6
    mulsd   xmm3, xmm6
    mulsd   xmm3, [rip+cf_tol]
    comisd  xmm0, xmm3
    ja      53f
    comisd  xmm2, xmm8
    jae     53f
    movsd   xmm8, xmm2
    mov     ebp, r14d
53: inc     r14d
    jmp     51b
52: test    ebp, ebp
    js      .Lcf_fail
    lea     rax, [rip+cdt_id]           # (cdt_force takes global ids)
    mov     ecx, [rax+r13*4]
    mov     [rsp], ecx                  # q
    mov     ecx, [rax+rbp*4]
    mov     [rsp+4], ecx                # v
    inc     dword ptr [rip+cf_depth]
    mov     edi, [rax+r12*4]
    mov     esi, ecx
    call    cdt_force
    test    eax, eax
    jz      54f
    mov     edi, [rsp+4]
    mov     esi, [rsp]
    call    cdt_force
54: dec     dword ptr [rip+cf_depth]
    test    eax, eax
    jz      .Lcf_fail
    jmp     .Lcf_ok
.Lcf_ok:
    mov     eax, 1
    jmp     9f
.Lcf_fail:
    xor     eax, eax
9:  add     rsp, 40
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# cdt_local(edi=global vertex) -> eax = local index or -1
cdt_local:
    xor     ecx, ecx
    lea     rdx, [rip+cdt_id]
1:  cmp     ecx, [rip+cdt_n]
    jae     2f
    cmp     [rdx+rcx*4], edi
    je      3f
    inc     ecx
    jmp     1b
2:  mov     eax, -1
    ret
3:  mov     eax, ecx
    ret

.section .rodata
.align 16
bd_abs:         .quad 0x7fffffffffffffff, 0
bd_sign:        .quad 0x8000000000000000, 0
bd_rel:         .double 1.0e-9
bd_flatpen:     .double 1.0e200
bd_flat:        .double 1.0e-13
cf_two:         .double 2.0
cf_one:         .double 1.0
cf_eps:         .double 1.0e-9
cf_tol:         .double 1.0e-18
cf_edge:        .double 1.0e-7
.text

# =============================================================================
#  Classification: regions of fragments between the cuts, inside or not
# =============================================================================
classify:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 40
    mov     edi, [rip+nfr]              # region per fragment
    shl     edi, 2
    add     edi, 8
    call    fa_fill_m1
    test    rax, rax
    jz      .Lcl_fail
    mov     [rip+reg], rax
    mov     edi, [rip+nfr]              # edge -> two fragments (same mesh)
    imul    edi, edi, 3
    call    eh_new
    test    rax, rax
    jz      .Lcl_fail
    mov     [rsp], rax
    mov     edi, [rip+nfr]
    imul    edi, edi, 3
    shl     edi, 3
    add     edi, 16
    call    fa_fill_m1
    test    rax, rax
    jz      .Lcl_fail
    mov     [rsp+8], rax                # slot -> (f1, f2)
    mov     dword ptr [rsp+16], 0       # slots used
    xor     r12d, r12d
1:  cmp     r12d, [rip+nfr]
    jae     2f
    xor     r13d, r13d
11: cmp     r13d, 3
    jae     12f
    mov     rax, [rip+fr]
    mov     rcx, r12
    shl     rcx, 4
    add     rcx, rax
    mov     edi, [rcx+r13*4]
    lea     edx, [r13+1]
    cmp     edx, 3
    jb      13f
    xor     edx, edx
13: mov     esi, [rcx+rdx*4]
    call    ukey
    mov     r14, rax
    mov     rax, [rip+fr]               # mesh bit in the key (A / B apart)
    mov     rcx, r12
    shl     rcx, 4
    mov     ecx, [rax+rcx+12]
    cmp     ecx, [rip+nta]
    jb      14f
    bts     r14, 63
14: mov     rsi, r14
    mov     rdi, [rsp]
    call    eh_slot
    test    edx, edx
    jnz     15f
    mov     ecx, [rsp+16]
    mov     [rax], ecx
    inc     dword ptr [rsp+16]
15: mov     ecx, [rax]
    mov     rax, [rsp+8]
    cmp     dword ptr [rax+rcx*8], -1
    jne     16f
    mov     [rax+rcx*8], r12d
    jmp     17f
16: mov     [rax+rcx*8+4], r12d
17: inc     r13d
    jmp     11b
12: inc     r12d
    jmp     1b
2:  # flood: regions, never across a constrained edge
    mov     edi, [rip+nfr]
    shl     edi, 2
    add     edi, 8
    call    fa
    test    rax, rax
    jz      .Lcl_fail
    mov     [rsp+24], rax               # stack
    mov     dword ptr [rip+nreg], 0
    xor     r12d, r12d                  # seed
3:  cmp     r12d, [rip+nfr]
    jae     .Lcl_regions
    mov     rax, [rip+reg]
    cmp     dword ptr [rax+r12*4], -1
    jne     39f
    mov     ecx, [rip+nreg]
    mov     [rax+r12*4], ecx
    inc     dword ptr [rip+nreg]
    mov     rdx, [rsp+24]
    mov     [rdx], r12d
    mov     ebx, 1                      # stack depth
31: test    ebx, ebx
    jz      39f
    dec     ebx
    mov     rdx, [rsp+24]
    mov     r13d, [rdx+rbx*4]           # fragment
    xor     r14d, r14d                  # its edges
32: cmp     r14d, 3
    jae     31b
    mov     rax, [rip+fr]
    mov     rcx, r13
    shl     rcx, 4
    add     rcx, rax
    mov     edi, [rcx+r14*4]
    lea     edx, [r14+1]
    cmp     edx, 3
    jb      33f
    xor     edx, edx
33: mov     esi, [rcx+rdx*4]
    mov     [rsp+32], edi
    mov     [rsp+36], esi
    call    ukey                        # constrained?
    lea     rsi, [rax+1]
    mov     rdi, [rip+eh_c]
    call    eh_get3
    test    eax, eax
    jns     38f
    mov     edi, [rsp+32]
    mov     esi, [rsp+36]
    call    ukey
    mov     r15, rax
    mov     rax, [rip+fr]
    mov     rcx, r13
    shl     rcx, 4
    mov     ecx, [rax+rcx+12]
    cmp     ecx, [rip+nta]
    jb      34f
    bts     r15, 63
34: lea     rsi, [r15+1]
    mov     rdi, [rsp]
    call    eh_get3
    test    eax, eax
    js      38f
    mov     rdx, [rsp+8]
    mov     ecx, [rdx+rax*8]            # the other fragment on this edge
    cmp     ecx, r13d
    jne     35f
    mov     ecx, [rdx+rax*8+4]
35: test    ecx, ecx
    js      38f
    mov     rax, [rip+reg]
    cmp     dword ptr [rax+rcx*4], -1
    jne     38f
    mov     edx, [rip+nreg]
    dec     edx
    mov     [rax+rcx*4], edx
    mov     rdx, [rsp+24]
    mov     [rdx+rbx*4], ecx
    inc     ebx
38: inc     r14d
    jmp     32b
39: inc     r12d
    jmp     3b
.Lcl_regions:
    # one test per region: its largest fragment's centroid against the other
    mov     edi, [rip+nreg]
    add     edi, 8
    call    fa
    test    rax, rax
    jz      .Lcl_fail
    mov     [rip+reg_in], rax
    mov     edi, [rip+nreg]
    shl     edi, 3
    add     edi, 16
    call    fa
    test    rax, rax
    jz      .Lcl_fail
    mov     [rsp+16], rax               # region -> (best fragment, area as float)
    mov     rdi, rax
    mov     ecx, [rip+nreg]
    shl     ecx, 1
    mov     eax, -1
    rep     stosd
    mov     rdx, [rsp+16]
    xor     ecx, ecx
    mov     eax, [rip+nreg]             # areas start at 0 (-1 bits are NaN:
41: cmp     ecx, eax                    #  reset them)
    jae     42f
    mov     dword ptr [rdx+rcx*8+4], 0
    inc     ecx
    jmp     41b
42: xor     r12d, r12d
43: cmp     r12d, [rip+nfr]
    jae     44f
    mov     edi, r12d
    call    frag_area                   # xmm0 (float)
    mov     rax, [rip+reg]
    mov     ecx, [rax+r12*4]
    mov     rdx, [rsp+16]
    cmp     dword ptr [rdx+rcx*8], -1   # (any fragment beats none)
    je      432f
    comiss  xmm0, [rdx+rcx*8+4]
    jbe     431f
432:
    movss   [rdx+rcx*8+4], xmm0
    mov     [rdx+rcx*8], r12d
431:inc     r12d
    jmp     43b
44: xor     r12d, r12d
45: cmp     r12d, [rip+nreg]
    jae     .Lcl_ok
    mov     rdx, [rsp+16]
    mov     edi, [rdx+r12*8]
    call    frag_inside                 # eax = 1 inside, 0 outside, -1 fail
    test    eax, eax
    js      .Lcl_fail
    mov     rdx, [rip+reg_in]
    mov     [rdx+r12], al
    inc     r12d
    jmp     45b
.Lcl_ok:
    mov     eax, 1
    jmp     9f
.Lcl_fail:
    mov     dword ptr [rip+fail_flag], 1
    xor     eax, eax
9:  add     rsp, 40
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# fa_fill_m1(edi=bytes) -> rax = frame-arena memory filled with 0xff
fa_fill_m1:
    push    rbx
    mov     ebx, edi
    call    fa
    test    rax, rax
    jz      9f
    push    rax
    mov     rdi, rax
    mov     ecx, ebx
    mov     al, 0xff
    rep     stosb
    pop     rax
9:  pop     rbx
    ret

# eh_get3(rdi=table, rsi=key+1) -> eax = value or -1
eh_get3:
    mov     r8, [rdi]
    mov     rax, rsi
    imul    rax, rax, 0x2545f491
    shr     rax, 13
    and     rax, r8
1:  mov     rcx, [rdi+8+rax*8]
    test    rcx, rcx
    jz      2f
    cmp     rcx, rsi
    je      3f
    inc     rax
    and     rax, r8
    jmp     1b
2:  mov     eax, -1
    ret
3:  lea     rcx, [r8+1]
    lea     rcx, [rdi+8+rcx*8]
    mov     eax, [rcx+rax*4]
    ret

# frag_area(edi=fragment) -> xmm0 = area (float, |cross| / 2 is enough)
frag_area:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 48
    mov     rax, [rip+fr]
    mov     rbx, rdi
    shl     rbx, 4
    add     rbx, rax
    mov     edi, [rbx]
    call    vpos
    mov     r12, rax
    mov     edi, [rbx+4]
    call    vpos
    mov     r13, rax
    mov     edi, [rbx+8]
    call    vpos
    xor     ecx, ecx
1:  movsd   xmm0, [r13+rcx*8]
    subsd   xmm0, [r12+rcx*8]
    movsd   [rsp+rcx*8], xmm0
    movsd   xmm0, [rax+rcx*8]
    subsd   xmm0, [r12+rcx*8]
    movsd   [rsp+24+rcx*8], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      1b
    movsd   xmm0, [rsp+8]
    mulsd   xmm0, [rsp+40]
    movsd   xmm1, [rsp+16]
    mulsd   xmm1, [rsp+32]
    subsd   xmm0, xmm1
    mulsd   xmm0, xmm0
    movsd   xmm2, [rsp+16]
    mulsd   xmm2, [rsp+24]
    movsd   xmm1, [rsp]
    mulsd   xmm1, [rsp+40]
    subsd   xmm2, xmm1
    mulsd   xmm2, xmm2
    addsd   xmm0, xmm2
    movsd   xmm2, [rsp]
    mulsd   xmm2, [rsp+32]
    movsd   xmm1, [rsp+8]
    mulsd   xmm1, [rsp+24]
    subsd   xmm2, xmm1
    mulsd   xmm2, xmm2
    addsd   xmm0, xmm2
    sqrtsd  xmm0, xmm0
    cvtsd2ss xmm0, xmm0
    add     rsp, 48
    pop     r13
    pop     r12
    pop     rbx
    ret

# frag_inside(edi=fragment) -> eax = 1 if its centroid is inside the other
#   mesh (ray parity, exact; another direction on a degenerate hit)
frag_inside:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 200
    mov     rax, [rip+fr]
    mov     rbx, rdi
    shl     rbx, 4
    add     rbx, rax
    mov     eax, [rbx+12]               # which mesh is "other"
    xor     r15d, r15d                  # 0: the fragment is A, test against B
    cmp     eax, [rip+nta]
    jb      1f
    mov     r15d, 1
1:  mov     [rip+ray_isb], r15d
    # the sample point: the fragment's centroid, rounded to barycentric
    #   weights k / 2^16 on its source triangle - so it lies exactly on that
    #   triangle (and moves with it when B is perturbed); the ray tests run
    #   on coordinates times 2^16
    mov     rdx, [rip+tri]
    lea     rax, [rax+rax*2]
    lea     rdx, [rdx+rax*4]
    mov     eax, [rdx]
    mov     [rsp+120], eax
    mov     eax, [rdx+4]
    mov     [rsp+124], eax
    mov     eax, [rdx+8]
    mov     [rsp+128], eax
    xorpd   xmm3, xmm3                  # centroid (double)
    xorpd   xmm4, xmm4
    xorpd   xmm5, xmm5
    xor     r12d, r12d
2:  mov     edi, [rbx+r12*4]
    call    vpos
    addsd   xmm3, [rax]
    addsd   xmm4, [rax+8]
    addsd   xmm5, [rax+16]
    inc     r12d
    cmp     r12d, 3
    jb      2b
    mulsd   xmm3, [rip+bd_third]
    mulsd   xmm4, [rip+bd_third]
    mulsd   xmm5, [rip+bd_third]
    movsd   [rsp], xmm3
    movsd   [rsp+8], xmm4
    movsd   [rsp+16], xmm5
    mov     edi, [rsp+120]              # e1 = b - a, e2 = c - a, d = p - a
    call    vpos
    mov     r12, rax
    mov     edi, [rsp+124]
    call    vpos
    mov     r13, rax
    mov     edi, [rsp+128]
    call    vpos
    xor     ecx, ecx
3:  movsd   xmm0, [r13+rcx*8]
    subsd   xmm0, [r12+rcx*8]
    movsd   [rsp+24+rcx*8], xmm0
    movsd   xmm0, [rax+rcx*8]
    subsd   xmm0, [r12+rcx*8]
    movsd   [rsp+48+rcx*8], xmm0
    movsd   xmm0, [rsp+rcx*8]
    subsd   xmm0, [r12+rcx*8]
    movsd   [rsp+72+rcx*8], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      3b
    lea     rdi, [rsp+24]               # n = e1 x e2, nn = n . n
    lea     rsi, [rsp+48]
    lea     rdx, [rsp+96]
    call    cross_d
    lea     rdi, [rsp+96]
    mov     rsi, rdi
    call    dot_d
    movsd   [rsp+160], xmm0
    lea     rdi, [rsp+72]               # u_b = (d x e2) . n / nn
    lea     rsi, [rsp+48]
    lea     rdx, [rsp+168]
    call    cross_d
    lea     rdi, [rsp+168]
    lea     rsi, [rsp+96]
    call    dot_d
    divsd   xmm0, [rsp+160]
    mulsd   xmm0, [rip+bd_2p16]
    cvtsd2si rax, xmm0
    mov     [rsp+144], rax              # k_b
    lea     rdi, [rsp+24]               # u_c = (e1 x d) . n / nn
    lea     rsi, [rsp+72]
    lea     rdx, [rsp+168]
    call    cross_d
    lea     rdi, [rsp+168]
    lea     rsi, [rsp+96]
    call    dot_d
    divsd   xmm0, [rsp+160]
    mulsd   xmm0, [rip+bd_2p16]
    cvtsd2si rax, xmm0
    mov     [rsp+152], rax              # k_c
    mov     rcx, 65536                  # k_a
    sub     rcx, [rsp+144]
    sub     rcx, rax
    mov     [rsp+136], rcx
    xor     ecx, ecx                    # ray_p, ray_n, ray_w = sum k_i (.)_i
4:  xor     r8d, r8d
    xor     r9d, r9d
    xor     r10d, r10d
    xor     r11d, r11d                  # corner
5:  mov     eax, [rsp+120+r11*4]
    lea     rax, [rax+rax*2]
    shl     rax, 3
    add     rax, rcx                    # + component * 8
    mov     rdx, [rip+vi]
    mov     rdx, [rdx+rax]
    imul    rdx, [rsp+136+r11*8]
    add     r8, rdx
    mov     rdx, [rip+vn]
    mov     rdx, [rdx+rax]
    imul    rdx, [rsp+136+r11*8]
    add     r9, rdx
    mov     rdx, [rip+vw]
    mov     rdx, [rdx+rax]
    imul    rdx, [rsp+136+r11*8]
    add     r10, rdx
    inc     r11d
    cmp     r11d, 3
    jb      5b
    lea     rax, [rip+ray_p]
    mov     [rax+rcx], r8
    lea     rax, [rip+ray_n]
    mov     [rax+rcx], r9
    lea     rax, [rip+ray_w]
    mov     [rax+rcx], r10
    add     ecx, 8
    cmp     ecx, 24
    jb      4b
    xor     r14d, r14d                  # direction attempt
.Lfin_dir:
    cmp     r14d, 5
    jae     .Lfin_fail
    lea     rax, [rip+bd_dir0]          # far point
    imul    rcx, r14, 24
    add     rax, rcx
    xor     ecx, ecx
4:  mov     rdx, [rax+rcx*8]
    add     rdx, rdx                    # (scaled coordinates: twice as far)
    lea     r8, [rip+ray_p]
    add     rdx, [r8+rcx*8]
    lea     r8, [rip+ray_q]
    mov     [r8+rcx*8], rdx
    inc     ecx
    cmp     ecx, 3
    jb      4b
    xor     ebp, ebp                    # crossings
    mov     r12d, 0                     # triangles of the other mesh
    mov     r13d, [rip+nta]
    test    r15d, r15d
    jnz     5f
    mov     r12d, [rip+nta]
    mov     r13d, [rip+nt]
5:  cmp     r12d, r13d
    jae     .Lfin_done
    mov     edi, r12d
    mov     esi, r15d
    call    ray_tri                     # eax = 1 cross, 0 no, -1 degenerate
    test    eax, eax
    js      .Lfin_next_dir
    add     ebp, eax
    inc     r12d
    jmp     5b
.Lfin_next_dir:
    inc     r14d
    jmp     .Lfin_dir
.Lfin_done:
    mov     eax, ebp
    and     eax, 1
    jmp     9f
.Lfin_fail:
    mov     eax, -1
9:  add     rsp, 200
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# cross_d(rdi=&u, rsi=&v, rdx=&out double[3]) / dot_d(rdi, rsi) -> xmm0
cross_d:
    movsd   xmm0, [rdi+8]
    mulsd   xmm0, [rsi+16]
    movsd   xmm1, [rdi+16]
    mulsd   xmm1, [rsi+8]
    subsd   xmm0, xmm1
    movsd   xmm2, [rdi+16]
    mulsd   xmm2, [rsi]
    movsd   xmm1, [rdi]
    mulsd   xmm1, [rsi+16]
    subsd   xmm2, xmm1
    movsd   xmm3, [rdi]
    mulsd   xmm3, [rsi+8]
    movsd   xmm1, [rdi+8]
    mulsd   xmm1, [rsi]
    subsd   xmm3, xmm1
    movsd   [rdx], xmm0
    movsd   [rdx+8], xmm2
    movsd   [rdx+16], xmm3
    ret
dot_d:
    movsd   xmm0, [rdi]
    mulsd   xmm0, [rsi]
    movsd   xmm1, [rdi+8]
    mulsd   xmm1, [rsi+8]
    addsd   xmm0, xmm1
    movsd   xmm1, [rdi+16]
    mulsd   xmm1, [rsi+16]
    addsd   xmm0, xmm1
    ret

# og_vertex_s(ecx=slot, edi=global vertex) - og_vertex with everything times
#   2^16 (the scale of the ray tests)
og_vertex_s:
    mov     eax, edi
    lea     rax, [rax+rax*2]
    shl     rax, 3
    imul    r9, rcx, 72
    lea     r10, [rip+og_sv]
    add     r10, r9
    lea     r8, [rip+og_p]
    mov     [r8+rcx*8], r10
    lea     r9, [r10+24]
    lea     r8, [rip+og_n]
    mov     [r8+rcx*8], r9
    lea     r9, [r10+48]
    lea     r8, [rip+og_w]
    mov     [r8+rcx*8], r9
    xor     r9d, r9d
1:  mov     r8, [rip+vi]
    add     r8, rax
    mov     rdx, [r8+r9*8]
    shl     rdx, 16
    mov     [r10+r9*8], rdx
    mov     r8, [rip+vn]
    add     r8, rax
    mov     rdx, [r8+r9*8]
    shl     rdx, 16
    mov     [r10+24+r9*8], rdx
    mov     r8, [rip+vw]
    add     r8, rax
    mov     rdx, [r8+r9*8]
    shl     rdx, 16
    mov     [r10+48+r9*8], rdx
    inc     r9d
    cmp     r9d, 3
    jb      1b
    ret

# ray_tri(edi=global triangle, esi=1 if the ray belongs to B) -> eax = 1 if
#   the segment ray_p -> ray_q crosses it, 0 if not, -1 on an exact tie.
#   Ray points carry B's perturbation when they belong to B, triangle
#   vertices when the triangle is B's.
ray_tri:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 48
    mov     rax, [rip+tri]
    lea     rcx, [rdi+rdi*2]
    mov     edx, [rax+rcx*4]
    mov     [rsp], edx
    mov     edx, [rax+rcx*4+4]
    mov     [rsp+4], edx
    mov     edx, [rax+rcx*4+8]
    mov     [rsp+8], edx
    mov     [rsp+12], esi
    # plane sides of p and q
    mov     edi, [rsp]
    mov     esi, [rsp+4]
    mov     edx, [rsp+8]
    lea     rcx, [rip+ray_p]
    call    ray_orient
    mov     ebx, eax
    mov     edi, [rsp]
    mov     esi, [rsp+4]
    mov     edx, [rsp+8]
    lea     rcx, [rip+ray_q]
    call    ray_orient
    mov     ecx, eax                    # both ends on its plane: a flat
    or      ecx, ebx                    #  triangle (a sliver an earlier
    jz      .Lrt_no                     #  boolean kept), nothing to cross
    test    eax, eax
    jz      .Lrt_tie
    test    ebx, ebx
    jz      .Lrt_tie
    cmp     eax, ebx
    je      .Lrt_no
    # the three edges against the ray: same sign
    mov     edi, [rsp]
    mov     esi, [rsp+4]
    call    ray_edge
    mov     r12d, eax
    test    eax, eax
    jz      .Lrt_tie
    mov     edi, [rsp+4]
    mov     esi, [rsp+8]
    call    ray_edge
    test    eax, eax
    jz      .Lrt_tie
    cmp     eax, r12d
    jne     .Lrt_no
    mov     edi, [rsp+8]
    mov     esi, [rsp]
    call    ray_edge
    test    eax, eax
    jz      .Lrt_tie
    cmp     eax, r12d
    jne     .Lrt_no
    mov     eax, 1
    jmp     9f
.Lrt_no:
    xor     eax, eax
    jmp     9f
.Lrt_tie:
    mov     eax, -1
9:  add     rsp, 48
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ray_orient(edi, esi, edx = triangle vertices, rcx=&int64[3] point) -> eax
#   = orientation (the point carries ray_w when it is B's)
ray_orient:
    push    rbx
    push    r12
    push    r14
    mov     ebx, esi
    mov     r12d, edx
    mov     r14, rcx
    xor     ecx, ecx
    call    og_vertex_s
    mov     edi, ebx
    mov     ecx, 1
    call    og_vertex_s
    mov     edi, r12d
    mov     ecx, 2
    call    og_vertex_s
    lea     rax, [rip+og_p]
    mov     [rax+24], r14
    lea     rax, [rip+og_w]
    lea     rcx, [rip+ray_w]
    mov     [rax+24], rcx
    lea     rax, [rip+og_n]
    lea     rcx, [rip+ray_n]
    mov     [rax+24], rcx
    mov     edi, 1
    call    orient_gen
    pop     r14
    pop     r12
    pop     rbx
    ret

# ray_edge(edi=u, esi=v triangle vertices) -> eax = orient(p, q, u, v)
ray_edge:
    push    rbx
    mov     ebx, esi
    mov     ecx, 2
    call    og_vertex_s
    mov     edi, ebx
    mov     ecx, 3
    call    og_vertex_s
    lea     rax, [rip+og_p]
    lea     rcx, [rip+ray_p]
    mov     [rax], rcx
    lea     rcx, [rip+ray_q]
    mov     [rax+8], rcx
    lea     rax, [rip+og_w]
    lea     rcx, [rip+ray_w]
    mov     [rax], rcx
    mov     [rax+8], rcx
    lea     rax, [rip+og_n]
    lea     rcx, [rip+ray_n]
    mov     [rax], rcx
    mov     [rax+8], rcx
    mov     edi, 1
    call    orient_gen
    pop     rbx
    ret

.section .bss
.align 8
ray_p:          .skip 24
ray_q:          .skip 24
ray_isb:        .skip 4
.align 8
ray_w:          .skip 24
ray_n:          .skip 24
og_sv:          .skip 4*72
.section .rodata
.align 8
bd_third:       .double 0.3333333333333333
bd_2p16:        .double 65536.0
.text

# =============================================================================
#  Assembly: the chosen regions; untouched polygons come back whole
# =============================================================================
# keep_frag(edi=fragment) -> eax = 1 keep, 2 keep flipped, 0 drop
keep_frag:
    mov     rax, [rip+fr]
    mov     rcx, rdi
    shl     rcx, 4
    mov     ecx, [rax+rcx+12]
    xor     edx, edx                    # 1 if B
    cmp     ecx, [rip+nta]
    setae   dl
    mov     rax, [rip+reg]
    mov     eax, [rax+rdi*4]
    mov     rcx, [rip+reg_in]
    movzx   eax, byte ptr [rcx+rax]     # inside the other?
    mov     ecx, [rip+op_kind]
    cmp     ecx, BOOL_UNION
    jne     1f
    xor     eax, 1                      # union: outside parts of both
    ret
1:  cmp     ecx, BOOL_ISECT
    jne     2f
    ret                                 # intersection: inside parts of both
2:  test    edx, edx                    # difference: A outside, B inside flipped
    jnz     3f
    xor     eax, 1
    ret
3:  test    eax, eax
    jz      4f
    mov     eax, 2
4:  ret

assemble:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 40
    # which source triangles survived whole (only themselves, kept, same way)
    mov     edi, [rip+nt]
    call    fa
    test    rax, rax
    jz      .Las_fail
    mov     [rsp], rax                  # 1 = whole, kept
    mov     r12, rax
    mov     rax, [rip+ts_off]
    xor     ecx, ecx
1:  cmp     ecx, [rip+nfr]
    jae     2f
    mov     rdx, [rip+fr]
    mov     r8, rcx
    shl     r8, 4
    mov     r9d, [rdx+r8+12]            # source triangle
    mov     rdx, [rip+ts_off]
    mov     r10d, [rdx+r9*4]
    cmp     r10d, [rdx+r9*4+4]
    jne     11f                         # cut: not whole
    push    rcx
    push    r9
    mov     edi, ecx
    call    keep_frag
    pop     r9
    pop     rcx
    mov     [r12+r9], al
11: inc     ecx
    jmp     1b
2:  # polygons whose every triangle survived whole the same way come back
    #   as the original polygon: per mesh, per polygon - count triangles
    mov     edi, [rip+nt]
    shl     edi, 2
    add     edi, 8
    call    fa
    test    rax, rax
    jz      .Las_fail
    mov     [rsp+8], rax                # polygon emitted? (global index)
    mov     rax, [rip+src_a]
    mov     eax, [rax+ME_NPOLYS]
    mov     [rip+polya], eax
    # the output mesh: all vertices (unused ones are compacted away)
    mov     edi, [rip+nv]
    add     edi, [rip+np_]
    mov     esi, [rip+nfr]
    imul    esi, esi, 3
    mov     rax, [rip+src_a]
    mov     eax, [rax+ME_NLOOPS]
    add     esi, eax
    mov     rax, [rip+src_b]
    add     esi, [rax+ME_NLOOPS]
    add     esi, 16
    mov     edx, [rip+nfr]
    add     edx, 16
    call    mesh_new
    test    rax, rax
    jz      .Las_fail
    mov     r13, rax
    xor     ebx, ebx
3:  mov     eax, [rip+nv]
    add     eax, [rip+np_]
    cmp     ebx, eax
    jae     4f
    mov     edi, ebx
    call    vpos
    cvtsd2ss xmm0, [rax]
    cvtsd2ss xmm1, [rax+8]
    cvtsd2ss xmm2, [rax+16]
    mov     rdi, r13
    call    mesh_add_vert
    inc     ebx
    jmp     3b
4:  # whole polygons first
    mov     r14, [rip+src_a]
    xor     r15d, r15d                  # mesh 0 = A, 1 = B
.Las_mesh:
    cmp     r15d, 2
    jae     .Las_frags
    xor     ebx, ebx                    # polygon
41: cmp     ebx, [r14+ME_NPOLYS]
    jae     .Las_mnext
    call    poly_whole                  # eax = 0 no, 1 keep, 2 flipped
    test    eax, eax
    jz      42f
    mov     ebp, eax
    mov     rsi, [r14+ME_POFF]          # the polygon's loops (global ids)
    mov     ecx, [rsi+rbx*4]
    mov     edx, [rsi+rbx*4+4]
    mov     rsi, [r14+ME_LOOPS]
    lea     rdi, [rip+scr]
    xor     r8d, r8d
    xor     r9d, r9d
    test    r15d, r15d
    jz      43f
    mov     r9d, [rip+nva]
43: cmp     ecx, edx
    jae     44f
    mov     eax, [rsi+rcx*4]
    add     eax, r9d
    mov     r10, [rip+canon]
    mov     eax, [r10+rax*4]
    mov     [rdi+r8*4], eax
    inc     r8d
    inc     ecx
    jmp     43b
44: cmp     ebp, 2
    jne     45f
    xor     ecx, ecx                    # flipped: reverse
    lea     edx, [r8-1]
46: cmp     ecx, edx
    jge     45f
    mov     eax, [rdi+rcx*4]
    mov     r10d, [rdi+rdx*4]
    mov     [rdi+rcx*4], r10d
    mov     [rdi+rdx*4], eax
    inc     ecx
    dec     edx
    jmp     46b
45: mov     rsi, rdi
    mov     rdi, r13
    mov     edx, r8d
    call    mesh_add_poly
42: inc     ebx
    jmp     41b
.Las_mnext:
    inc     r15d
    mov     r14, [rip+src_b]
    jmp     .Las_mesh
.Las_frags:
    # the remaining kept fragments as triangles
    xor     ebx, ebx
5:  cmp     ebx, [rip+nfr]
    jae     6f
    mov     rdx, [rip+fr]
    mov     r8, rbx
    shl     r8, 4
    mov     r9d, [rdx+r8+12]            # source triangle: in a whole polygon?
    mov     rax, [rip+tpoly]
    mov     r10d, [rax+r9*4]
    xor     eax, eax
    cmp     r9d, [rip+nta]
    jb      51f
    add     r10d, [rip+polya]           # B polygons after A's
51: mov     rax, [rsp+8]
    cmp     byte ptr [rax+r10], 0
    jne     59f                         # emitted whole already
    mov     edi, ebx
    call    keep_frag
    test    eax, eax
    jz      59f
    mov     rdx, [rip+fr]
    mov     r8, rbx
    shl     r8, 4
    lea     rsi, [rip+tmpq]
    mov     ecx, [rdx+r8]
    mov     [rsi], ecx
    mov     ecx, [rdx+r8+4]
    mov     [rsi+4], ecx
    mov     ecx, [rdx+r8+8]
    mov     [rsi+8], ecx
    cmp     eax, 2
    jne     52f
    mov     ecx, [rsi]                  # flipped
    mov     edx, [rsi+8]
    mov     [rsi], edx
    mov     [rsi+8], ecx
52: mov     rdi, r13
    mov     edx, 3
    call    mesh_add_poly
59: inc     ebx
    jmp     5b
6:  mov     rdi, r13
    call    cancel_sheets
    mov     rdi, r13
    call    mesh_finish
    mov     rdi, r13
    call    mesh_compact
    jmp     9f
.Las_fail:
    xor     eax, eax
9:  add     rsp, 40
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# cancel_sheets(rdi=mesh, polygons only) - a polygon and another one with
#   the same corners in the opposite order enclose nothing (A - A, faces
#   pressed together): both go
cancel_sheets:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 24
    mov     rbx, rdi
    mov     edi, [rbx+ME_NPOLYS]
    call    eh_new
    test    rax, rax
    jz      .Lcs_out
    mov     r12, rax
    mov     edi, [rbx+ME_NPOLYS]
    add     edi, 8
    call    fa
    test    rax, rax
    jz      .Lcs_out
    mov     r13, rax                    # deleted flags
    xor     r14d, r14d                  # polygon
.Lcs_poly:
    cmp     r14d, [rbx+ME_NPOLYS]
    jae     .Lcs_pack
    mov     edi, r14d
    xor     esi, esi
    call    cyc_hash                    # forward
    mov     [rsp], rax
    mov     edi, r14d
    mov     esi, 1
    call    cyc_hash                    # reversed
    lea     rsi, [rax+1]
    mov     rdi, r12
    call    eh_get3
    test    eax, eax
    js      2f
    mov     r15d, eax                   # a candidate: still there, exact?
    cmp     byte ptr [r13+r15], 0
    jne     2f
    mov     edi, r14d
    mov     esi, r15d
    call    cyc_reverse
    test    eax, eax
    jz      2f
    mov     byte ptr [r13+r14], 1
    mov     byte ptr [r13+r15], 1
    jmp     3f
2:  mov     rsi, [rsp]                  # remember this one
    mov     rdi, r12
    call    eh_slot
    mov     [rax], r14d
3:  inc     r14d
    jmp     .Lcs_poly
.Lcs_pack:                              # squeeze the survivors together
    mov     r8, [rbx+ME_POFF]
    mov     r9, [rbx+ME_LOOPS]
    xor     ecx, ecx                    # read polygon
    xor     edx, edx                    # write polygon
    xor     r10d, r10d                  # write loop
4:  cmp     ecx, [rbx+ME_NPOLYS]
    jae     6f
    cmp     byte ptr [r13+rcx], 0
    jne     5f
    mov     eax, [r8+rcx*4]
    mov     r11d, [r8+rcx*4+4]
    mov     [r8+rdx*4], r10d
41: cmp     eax, r11d
    jae     42f
    mov     ebp, [r9+rax*4]
    mov     [r9+r10*4], ebp
    inc     eax
    inc     r10d
    jmp     41b
42: inc     edx
5:  inc     ecx
    jmp     4b
6:  mov     [r8+rdx*4], r10d
    mov     [rbx+ME_NPOLYS], edx
    mov     [rbx+ME_NLOOPS], r10d
.Lcs_out:
    add     rsp, 24
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# cyc_hash(rbx=mesh, edi=polygon, esi=1 reversed) -> rax = hash of the
#   corner cycle starting at its smallest corner
cyc_hash:
    mov     r8, [rbx+ME_POFF]
    mov     r9, [rbx+ME_LOOPS]
    mov     ecx, [r8+rdi*4]             # first
    mov     r10d, [r8+rdi*4+4]
    sub     r10d, ecx                   # n
    lea     r9, [r9+rcx*4]
    xor     ecx, ecx                    # smallest corner position
    xor     edx, edx
1:  cmp     edx, r10d
    jae     2f
    mov     eax, [r9+rdx*4]
    cmp     eax, [r9+rcx*4]
    jae     11f
    mov     ecx, edx
11: inc     edx
    jmp     1b
2:  mov     rax, 0xcbf29ce484222325
    xor     rax, r10
    xor     edx, edx                    # k
3:  cmp     edx, r10d
    jae     9f
    mov     r11d, ecx                   # forward: c + k, reversed: c - k
    test    esi, esi
    jnz     4f
    add     r11d, edx
    jmp     5f
4:  sub     r11d, edx
    add     r11d, r10d
5:  push    rdx
    mov     eax, r11d                   # mod n (r11 < 2n)
    cmp     r11d, r10d
    jb      6f
    sub     r11d, r10d
6:  pop     rdx
    mov     r11d, [r9+r11*4]
    mov     rax, rax
    xor     rax, r11
    mov     r11, 0x100000001b3
    imul    rax, r11
    inc     edx
    jmp     3b
9:  shr     rax, 1                      # (eh keys must not be -1)
    ret

# cyc_reverse(rbx=mesh, edi=p, esi=q) -> eax = 1 if q is p backwards
cyc_reverse:
    mov     r8, [rbx+ME_POFF]
    mov     r9, [rbx+ME_LOOPS]
    mov     eax, [r8+rdi*4]
    mov     r10d, [r8+rdi*4+4]
    sub     r10d, eax
    lea     rdi, [r9+rax*4]             # p's corners
    mov     eax, [r8+rsi*4]
    mov     r11d, [r8+rsi*4+4]
    sub     r11d, eax
    lea     rsi, [r9+rax*4]             # q's corners
    cmp     r10d, r11d
    jne     8f
    mov     eax, [rdi]                  # p0 in q
    xor     ecx, ecx
1:  cmp     ecx, r11d
    jae     8f
    cmp     [rsi+rcx*4], eax
    je      2f
    inc     ecx
    jmp     1b
2:  xor     edx, edx                    # q[j - k] == p[k]
3:  cmp     edx, r10d
    jae     7f
    mov     eax, ecx
    sub     eax, edx
    jns     4f
    add     eax, r10d
4:  mov     eax, [rsi+rax*4]
    cmp     eax, [rdi+rdx*4]
    jne     8f
    inc     edx
    jmp     3b
7:  mov     eax, 1
    ret
8:  xor     eax, eax
    ret

# poly_whole(ebx=polygon of mesh r14 (r15d = 0 A / 1 B), [rsp+8+0] = whole
#   flags, [rsp+8+8] = emitted flags) -> eax = 0 / 1 keep / 2 flipped; marks
#   it emitted
poly_whole:
    push    r12
    push    r13
    mov     r12, [rsp+24]               # whole flags (assemble's [rsp])
    mov     r13, [rsp+32]               # emitted flags
    mov     rax, [r14+ME_POFF]          # triangles of this polygon: n - 2
    mov     ecx, [rax+rbx*4+4]
    sub     ecx, [rax+rbx*4]
    sub     ecx, 2                      # count
    jle     8f
    # its triangles are consecutive in the fan triangulation: find the
    #   first triangle of this polygon via tpoly (linear scan is too slow;
    #   use the polygon's loop offset: tris of polygon p start at
    #   loops[p] - 2p)
    mov     edx, [rax+rbx*4]
    lea     r8d, [rbx+rbx]
    sub     edx, r8d                    # first triangle (local)
    test    r15d, r15d
    jz      1f
    add     edx, [rip+nta]
1:  movzx   eax, byte ptr [r12+rdx]     # all the same, non-zero
    test    eax, eax
    jz      8f
    mov     r8d, edx
    add     r8d, ecx
2:  inc     edx
    cmp     edx, r8d
    jae     3f
    cmp     [r12+rdx], al
    jne     8f
    jmp     2b
3:  mov     edx, ebx                    # mark emitted
    test    r15d, r15d
    jz      4f
    add     edx, [rip+polya]
4:  mov     byte ptr [r13+rdx], 1
    jmp     9f
8:  xor     eax, eax
9:  pop     r13
    pop     r12
    ret

.section .bss
polya:          .skip 4
.text

# =============================================================================
#  object.boolean, closed-manifold check
# =============================================================================
OPERATOR op_boolean, "object.boolean", "Boolean", do_boolean, flags=OPF_AI_SAFE|OPF_UNDO|OPF_OBJECT, doc="Combine the active mesh with another selected one: object.boolean union|difference|intersect [keep]"
OPERATOR op_bool_union, "object.boolean_union", "Boolean Union", do_boolean_n, arg=BOOL_UNION, flags=OPF_AI_SAFE|OPF_UNDO|OPF_OBJECT|OPF_HIDDEN, doc="Boolean union of the active and the selected mesh"
OPERATOR op_bool_diff, "object.boolean_difference", "Boolean Difference", do_boolean_n, arg=BOOL_DIFF, flags=OPF_AI_SAFE|OPF_UNDO|OPF_OBJECT|OPF_HIDDEN, doc="Subtract the selected mesh from the active one"
OPERATOR op_bool_isect, "object.boolean_intersect", "Boolean Intersect", do_boolean_n, arg=BOOL_ISECT, flags=OPF_AI_SAFE|OPF_UNDO|OPF_OBJECT|OPF_HIDDEN, doc="Keep what the active and the selected mesh share"

.section .rodata
s_bo_need:      .asciz "boolean: select two meshes (the active one is kept)"
s_bo_kind:      .asciz "boolean: union, difference or intersect"
s_bo_fail:      .asciz "boolean: failed (the meshes must be closed and not self-intersecting)"
s_bo_done:      .asciz "boolean: faces "
s_bo_keep:      .asciz "keep"

.section .bss
.align 8
bo_ma:          .skip 48
bo_mb:          .skip 48
bo_rel:         .skip 48
bo_keep:        .skip 4

.text
do_boolean:
    sub     rsp, 8
    mov     rdi, [rip+op_arg]
    test    rdi, rdi
    jz      7f
1:  cmp     byte ptr [rdi], ' '
    jne     2f
    inc     rdi
    jmp     1b
2:  movzx   eax, byte ptr [rdi]
    or      eax, 0x20
    mov     esi, BOOL_UNION
    cmp     eax, 'u'
    je      3f
    mov     esi, BOOL_DIFF
    cmp     eax, 'd'
    je      3f
    cmp     eax, 's'                    # subtract
    je      3f
    mov     esi, BOOL_ISECT
    cmp     eax, 'i'
    jne     7f
3:  mov     dword ptr [rip+bo_keep], 0  # "keep" anywhere after the kind
4:  cmp     byte ptr [rdi], 0
    je      6f
    cmp     dword ptr [rdi], 0x7065656b # "keep"
    je      5f
    inc     rdi
    jmp     4b
5:  mov     dword ptr [rip+bo_keep], 1
6:  mov     edi, esi
    add     rsp, 8
    jmp     bool_run
7:  lea     rdi, [rip+s_bo_kind]
    call    log_line
    call    undo_drop_last
    add     rsp, 8
    ret

do_boolean_n:                           # rdi = kind (operator argument)
    mov     dword ptr [rip+bo_keep], 0
# bool_run(edi=kind)
bool_run:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r15d, edi
    cmp     dword ptr [rip+edit_obj], 0
    je      1f
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    jmp     edit_unsupported
1:  mov     edi, [rip+active_obj]
    call    obj_get
    test    rax, rax
    jz      .Lbr_need
    cmp     dword ptr [rax+OB_TYPE], OT_MESH
    jne     .Lbr_need
    mov     rbx, rax                    # A
    xor     r12d, r12d                  # B: the first other selected mesh
    xor     r13d, r13d
2:  cmp     r13d, [rip+obj_count]
    jae     3f
    mov     edi, r13d
    call    obj_at
    inc     r13d
    cmp     rax, rbx
    je      2b
    test    dword ptr [rax+OB_FLAGS], OBF_SELECTED
    jz      2b
    cmp     dword ptr [rax+OB_TYPE], OT_MESH
    jne     2b
    mov     r12, rax
3:  test    r12, r12
    jz      .Lbr_need
    mov     rdi, rbx
    lea     rsi, [rip+bo_ma]
    call    obj_matrix
    mov     rdi, r12
    lea     rsi, [rip+bo_mb]
    call    obj_matrix
    call    rel_matrix
    mov     rdi, [rbx+OB_MESH]
    mov     rsi, [r12+OB_MESH]
    lea     rdx, [rip+bo_rel]
    mov     ecx, r15d
    call    mesh_boolean
    test    rax, rax
    jz      .Lbr_fail
    mov     r14, rax
    mov     rdi, [rbx+OB_MESH]          # swap the mesh in
    mov     [rbx+OB_MESH], r14
    call    mesh_unref
    cmp     dword ptr [rip+bo_keep], 0
    jne     4f
    and     dword ptr [rbx+OB_FLAGS], ~OBF_SELECTED  # delete B only
    call    op_delete_sel
    or      dword ptr [rbx+OB_FLAGS], OBF_SELECTED
    jmp     5f
4:  and     dword ptr [r12+OB_FLAGS], ~OBF_SELECTED
5:  mov     dword ptr [rip+dirty], 1
    call    fmt_reset
    lea     rdi, [rip+s_bo_done]
    call    fmt_str
    mov     edi, [r14+ME_NPOLYS]
    call    fmt_int
    lea     rdi, [rip+fmt_buf]
    call    log_line
    jmp     9f
.Lbr_need:
    lea     rdi, [rip+s_bo_need]
    call    log_line
    call    undo_drop_last
    jmp     9f
.Lbr_fail:
    lea     rdi, [rip+s_bo_fail]
    call    log_line
    call    undo_drop_last
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# bool_with(rdi=object A, rsi=object B, rdx=mesh standing for A, ecx=kind)
#   -> rax = that mesh combined with B's base mesh, in A's frame (or 0)
bool_with:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13, rdx
    mov     r14d, ecx
    lea     rsi, [rip+bo_ma]
    call    obj_matrix
    mov     rdi, r12
    lea     rsi, [rip+bo_mb]
    call    obj_matrix
    call    rel_matrix
    mov     rdi, r13
    mov     rsi, [r12+OB_MESH]
    lea     rdx, [rip+bo_rel]
    mov     ecx, r14d
    call    mesh_boolean
    add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# rel_matrix - bo_rel = inverse(bo_ma) * bo_mb (3x4 affine, doubles inside)
rel_matrix:
    sub     rsp, 104
    # cofactor inverse of the 3x3 part: inv[i][j] = cof[j][i] / det
    lea     rsi, [rip+bo_ma]
    xor     ecx, ecx
1:  cvtss2sd xmm0, [rsi+rcx*4]          # m as doubles at [rsp] (row-major,
    movsd   [rsp+rcx*8], xmm0           #  12 entries)
    inc     ecx
    cmp     ecx, 12
    jb      1b
    # minors (a=m00 b=m01 c=m02 / d=m10 e=m11 f=m12 / g=m20 h=m21 i=m22)
    #   offsets: a 0 b 8 c 16 t0 24 | d 32 e 40 f 48 t1 56 | g 64 h 72 i 80 t2 88
.macro CF2 out, p, q, r, s              # out = p*q - r*s
    movsd   xmm0, [rsp+\p]
    mulsd   xmm0, [rsp+\q]
    movsd   xmm1, [rsp+\r]
    mulsd   xmm1, [rsp+\s]
    subsd   xmm0, xmm1
    movsd   \out, xmm0
.endm
    CF2     xmm2, 40, 80, 48, 72        # A = ei - fh
    CF2     xmm3, 48, 64, 32, 80        # B = fg - di
    CF2     xmm4, 32, 72, 40, 64        # C = dh - eg
    CF2     xmm5, 16, 72, 8, 80         # D = ch - bi
    CF2     xmm6, 0, 80, 16, 64         # E = ai - cg
    CF2     xmm7, 8, 64, 0, 72          # F = bg - ah
    CF2     xmm8, 8, 48, 16, 40         # G = bf - ce
    CF2     xmm9, 16, 32, 0, 48         # H = cd - af
    CF2     xmm10, 0, 40, 8, 32         # I = ae - bd
.purgem CF2
    movsd   xmm0, [rsp]                 # det = aA + bB + cC
    mulsd   xmm0, xmm2
    movsd   xmm1, [rsp+8]
    mulsd   xmm1, xmm3
    addsd   xmm0, xmm1
    movsd   xmm1, [rsp+16]
    mulsd   xmm1, xmm4
    addsd   xmm0, xmm1
    movsd   xmm1, [rip+bd_one]
    divsd   xmm1, xmm0
    # inverse rows: (A D G) (B E H) (C F I) / det, stored as floats in bo_ma
    #   (the original is no longer needed), translation -inv * t
    lea     rdi, [rip+bo_ma]
    mulsd   xmm2, xmm1
    mulsd   xmm5, xmm1
    mulsd   xmm8, xmm1
    mulsd   xmm3, xmm1
    mulsd   xmm6, xmm1
    mulsd   xmm9, xmm1
    mulsd   xmm4, xmm1
    mulsd   xmm7, xmm1
    mulsd   xmm10, xmm1
.macro INVROW o, x, y, z
    cvtsd2ss xmm0, \x
    movss   [rdi+\o], xmm0
    cvtsd2ss xmm0, \y
    movss   [rdi+\o+4], xmm0
    cvtsd2ss xmm0, \z
    movss   [rdi+\o+8], xmm0
    movsd   xmm0, \x                    # -(row . t)
    mulsd   xmm0, [rsp+24]
    movsd   xmm11, \y
    mulsd   xmm11, [rsp+56]
    addsd   xmm0, xmm11
    movsd   xmm11, \z
    mulsd   xmm11, [rsp+88]
    addsd   xmm0, xmm11
    xorpd   xmm0, [rip+bd_sign]
    cvtsd2ss xmm0, xmm0
    movss   [rdi+\o+12], xmm0
.endm
    INVROW  0, xmm2, xmm5, xmm8
    INVROW  16, xmm3, xmm6, xmm9
    INVROW  32, xmm4, xmm7, xmm10
.purgem INVROW
    # rel = inv * mb
    lea     rsi, [rip+bo_mb]
    lea     rdx, [rip+bo_rel]
    xor     ecx, ecx                    # row
2:  xor     r8d, r8d                    # column
3:  imul    r9, rcx, 16
    cvtss2sd xmm0, [rdi+r9]
    cvtss2sd xmm1, [rsi+r8*4]
    mulsd   xmm0, xmm1
    cvtss2sd xmm2, [rdi+r9+4]
    cvtss2sd xmm1, [rsi+r8*4+16]
    mulsd   xmm2, xmm1
    addsd   xmm0, xmm2
    cvtss2sd xmm2, [rdi+r9+8]
    cvtss2sd xmm1, [rsi+r8*4+32]
    mulsd   xmm2, xmm1
    addsd   xmm0, xmm2
    cmp     r8d, 3
    jne     4f
    cvtss2sd xmm2, [rdi+r9+12]          # + inverse translation
    addsd   xmm0, xmm2
4:  cvtsd2ss xmm0, xmm0
    lea     r10, [r9+r8*4]
    movss   [rdx+r10], xmm0
    inc     r8d
    cmp     r8d, 4
    jb      3b
    inc     ecx
    cmp     ecx, 3
    jb      2b
    add     rsp, 104
    ret

# mesh_manifold(rdi=mesh) -> eax = 1 if every edge is used once in each
#   direction (closed and consistently oriented)
mesh_manifold:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rbx, rdi
    call    fa_mark
    mov     r15, rax
    mov     edi, [rbx+ME_NLOOPS]
    call    eh_new
    test    rax, rax
    jz      8f
    mov     r12, rax
    xor     r13d, r13d                  # pass 0: insert, 1: look up reverses
.Lmm_pass:
    xor     r14d, r14d                  # polygon
1:  cmp     r14d, [rbx+ME_NPOLYS]
    jae     .Lmm_pend
    mov     rax, [rbx+ME_POFF]
    mov     ecx, [rax+r14*4]
    mov     r8d, [rax+r14*4+4]
2:  cmp     ecx, r8d
    jae     5f
    mov     rax, [rbx+ME_LOOPS]
    mov     edi, [rax+rcx*4]
    lea     edx, [rcx+1]
    cmp     edx, r8d
    jb      3f
    mov     rdx, [rbx+ME_POFF]
    mov     edx, [rdx+r14*4]
3:  mov     esi, [rax+rdx*4]
    push    rcx
    push    r8
    test    r13d, r13d
    jz      4f
    xchg    edi, esi                    # the reverse must exist
    call    dkey
    lea     rsi, [rax+1]
    mov     rdi, r12
    call    eh_get3
    pop     r8
    pop     rcx
    test    eax, eax
    js      8f
    inc     ecx
    jmp     2b
4:  call    dkey
    mov     rsi, rax
    mov     rdi, r12
    call    eh_slot
    mov     dword ptr [rax], 0
    pop     r8
    pop     rcx
    test    edx, edx                    # twice the same way: not manifold
    jnz     8f
    inc     ecx
    jmp     2b
5:  inc     r14d
    jmp     1b
.Lmm_pend:
    inc     r13d
    cmp     r13d, 2
    jb      .Lmm_pass
    mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  push    rax
    mov     rdi, r15
    call    fa_release
    pop     rax
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.section .note.GNU-stack,"",@progbits
