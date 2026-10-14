# =============================================================================
#  BeeModel - B-rep tessellation: watertight triangles for display and tests
#
#  Every edge is sampled once (adaptively: chord height and angle), so the
#  two faces of an edge share its points and the result has no cracks. Each
#  face is triangulated in its (u, v), scaled by the surface's metric there:
#  its loops (holes bridged into the outer one) are ear-clipped, then made
#  Delaunay by edge flips that never cross a boundary; doubly curved faces
#  (spheres, tori, NURBS) get points inside at the sampling step, each
#  inserted with flips. Triangles turn so their normals point out of the
#  solid. bd_inside answers whether a point lies inside a tessellated body
#  (ray parity, three directions voting).
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "brep.inc"

.globl bd_tess
.globl bd_tomesh
.globl bd_inside
.globl ed_tess
.globl bt_tol
.globl bd_reach

.equ TS_NV,   0                         # a body's triangles (BD_TRI)
.equ TS_NT,   4
.equ TS_PV,   8                         # 3 doubles per vertex
.equ TS_PT,   16                        # 3 u32 per triangle
.equ TS_SZ,   32
.equ MAXEP,   4096                      # points of an edge
.equ MAXCP,   32768                     # a face's points
.equ MAXCT,   65536                     # a face's triangles
.equ PF_MAXP, 8192                      # (prof.s's loop points, loops)
.equ PF_MAXL, 128

.section .rodata
.align 16
bt_absm:        .quad 0x7fffffffffffffff, 0x7fffffffffffffff
bt_negm:        .quad 0x8000000000000000, 0x8000000000000000
bt_one:         .double 1.0
bt_half:        .double 0.5
bt_step:        .double 0.2617993877991494      # 15 degrees
bt_fine:        .double 0.17453292519943295     # 10 degrees
bt_tiny:        .double 1.0e-12
bt_big:         .double 1.0e300
bt_rel:         .double 2.0e-4                  # chord height (of the size)
bt_keep:        .double 0.45                    # inner points this far in
bt_eps:         .double 1.0e-9
bt_dirs:        .double 0.5773, 0.5774, 0.5776
                .double -0.6247, 0.4342, 0.6489
                .double 0.2117, -0.8731, 0.4392

.section .bss
.align 8
bt_tol:         .skip 8                 # chord height
bt_va:          .skip ARENA_SZ          # the body's vertices (3 doubles)
bt_ta:          .skip ARENA_SZ          # its triangles (3 u32)
bt_nv:          .skip 4
bt_nt:          .skip 4
bt_ready:       .skip 4
bt_vmap:        .skip 8                 # B-rep vertex -> tessellation vertex
# edge sampling
.align 8
es_t:           .skip 8*MAXEP
es_p:           .skip 24*MAXEP
es_n:           .skip 4
# a face
.align 8
ft_surf:        .skip 8
ft_sense:       .skip 4
ft_curved:      .skip 4
ft_su:          .skip 8                 # metric scales (u, v)
ft_sv:          .skip 8
ft_uv:          .skip 16*MAXCP          # true (u, v) per point
ft_mv:          .skip 4*MAXCP           # tessellation vertex per point
ft_nxt:         .skip 4*MAXCP           # the next boundary point (-1 inner)
ct_p:           .skip 16*MAXCP          # scaled (u, v)
ct_np:          .skip 4
ct_v:           .skip 12*MAXCT
ct_n:           .skip 12*MAXCT
ct_c:           .skip MAXCT             # constrained edges (bits)
ct_nt:          .skip 4
ct_stk:         .skip 8*MAXCT           # (triangle, edge) to check
ct_ns:          .skip 4
ct_last:        .skip 4
ct_hash:        .skip 8                 # adjacency table (bk_data)
ct_hcap:        .skip 4

.text

# =============================================================================
#  Storage
# =============================================================================
bt_init:
    cmp     dword ptr [rip+bt_ready], 0
    jne     9f
    sub     rsp, 8
    lea     rdi, [rip+bt_va]
    mov     rsi, 0x40000000
    call    arena_init
    lea     rdi, [rip+bt_ta]
    mov     rsi, 0x40000000
    call    arena_init
    mov     dword ptr [rip+bt_ready], 1
    add     rsp, 8
9:  ret

# tv_add(rdi=point) -> eax = a new tessellation vertex
tv_add:
    mov     eax, [rip+bt_nv]
    lea     rcx, [rax+rax*2]
    shl     rcx, 3
    cmp     rcx, 0x3ff00000
    jae     8f
    add     rcx, [rip+bt_va+AR_BASE]
    movupd  xmm0, [rdi]
    movupd  [rcx], xmm0
    mov     rdx, [rdi+16]
    mov     [rcx+16], rdx
    inc     dword ptr [rip+bt_nv]
    ret
8:  xor     eax, eax
    ret

# tt_add(edi, esi, edx) - a triangle
tt_add:
    mov     eax, [rip+bt_nt]
    lea     rcx, [rax+rax*2]
    shl     rcx, 2
    cmp     rcx, 0x3ff00000
    jae     9f
    add     rcx, [rip+bt_ta+AR_BASE]
    mov     [rcx], edi
    mov     [rcx+4], esi
    mov     [rcx+8], edx
    inc     dword ptr [rip+bt_nt]
9:  ret

# vmap(edi=B-rep vertex) -> eax = its tessellation vertex (made once)
vmap:
    push    rbx
    mov     ebx, edi
    mov     rax, [rip+bt_vmap]
    mov     eax, [rax+rbx*4]
    cmp     eax, -1
    jne     9f
    mov     edi, ebx
    call    p_vx
    mov     rdi, rax
    call    tv_add
    mov     rcx, [rip+bt_vmap]
    mov     [rcx+rbx*4], eax
9:  pop     rbx
    ret

# =============================================================================
#  Edges
# =============================================================================
# es_push(rdi=curve, xmm0=t) - a sample at t
es_push:
    mov     eax, [rip+es_n]
    cmp     eax, MAXEP
    jae     9f
    push    rbx
    sub     rsp, 80
    lea     rcx, [rip+es_t]
    movsd   [rcx+rax*8], xmm0
    lea     rsi, [rsp]
    call    crv_eval
    mov     eax, [rip+es_n]
    lea     rcx, [rax+rax*2]
    lea     rdx, [rip+es_p]
    movupd  xmm0, [rsp]
    movupd  [rdx+rcx*8], xmm0
    mov     rax, [rsp+16]
    mov     [rdx+rcx*8+16], rax
    inc     dword ptr [rip+es_n]
    add     rsp, 80
    pop     rbx
9:  ret

# ed_tess(edi=edge) - its polyline (ED_POLY: x y z t per point), made once
ed_tess:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 104
    call    p_ed
    mov     rbx, rax
    cmp     qword ptr [rbx+ED_POLY], 0
    jne     .Let_out
    mov     dword ptr [rip+es_n], 0
    test    dword ptr [rbx+ED_FLAGS], EF_DEGEN
    jnz     .Let_degen
    mov     edi, [rbx+ED_CURVE]
    call    p_cv
    mov     r12, rax
    # first pieces: lines 1; conics every 15 degrees; polylines their points;
    # other NURBS 4 per knot span
    mov     r13d, 1
    mov     eax, [r12+CV_TYPE]
    cmp     eax, CT_LINE
    je      2f
    cmp     eax, CT_NURBS
    je      1f
    movsd   xmm0, [rbx+ED_T1]
    subsd   xmm0, [rbx+ED_T0]
    andpd   xmm0, [rip+bt_absm]
    divsd   xmm0, [rip+bt_step]
    cvttsd2si r13d, xmm0
    inc     r13d
    jmp     2f
1:  cmp     dword ptr [r12+CV_DEG], 1
    je      .Let_knots
    mov     r13d, [r12+CV_N]
    sub     r13d, [r12+CV_DEG]
    shl     r13d, 2
11: cmp     r13d, 1
    jge     2f
    mov     r13d, 1
2:  cmp     r13d, MAXEP/4
    jbe     3f
    mov     r13d, MAXEP/4
3:  xor     r14d, r14d                  # t = t0 + (t1 - t0) i / n
4:  cmp     r14d, r13d
    ja      5f
    cvtsi2sd xmm0, r14d
    cvtsi2sd xmm1, r13d
    divsd   xmm0, xmm1
    movsd   xmm1, [rbx+ED_T1]
    subsd   xmm1, [rbx+ED_T0]
    mulsd   xmm0, xmm1
    addsd   xmm0, [rbx+ED_T0]
    mov     rdi, r12
    call    es_push
    inc     r14d
    jmp     4b
5:  # refine: a piece whose middle is off its chord by more than the
    # tolerance is split (the new point goes at the end, then sorted in)
    xor     r14d, r14d
.Let_ref:
    mov     eax, [rip+es_n]
    dec     eax
    cmp     r14d, eax
    jae     .Let_store
    cmp     dword ptr [rip+es_n], MAXEP-1
    jae     .Let_store
    cmp     dword ptr [r12+CV_TYPE], CT_LINE
    je      .Let_store
    lea     rcx, [rip+es_t]
    movsd   xmm0, [rcx+r14*8]
    addsd   xmm0, [rcx+r14*8+8]
    mulsd   xmm0, [rip+bt_half]
    movsd   [rsp+96], xmm0
    mov     rdi, r12
    lea     rsi, [rsp]
    call    crv_eval
    lea     rax, [r14+r14*2]            # chord middle
    lea     rdx, [rip+es_p]
    lea     rdx, [rdx+rax*8]
    xor     ecx, ecx
    xorpd   xmm3, xmm3
6:  movsd   xmm0, [rdx+rcx*8]
    addsd   xmm0, [rdx+rcx*8+24]
    mulsd   xmm0, [rip+bt_half]
    subsd   xmm0, [rsp+rcx*8]
    mulsd   xmm0, xmm0
    addsd   xmm3, xmm0
    inc     ecx
    cmp     ecx, 3
    jb      6b
    sqrtsd  xmm3, xmm3
    comisd  xmm3, [rip+bt_tol]
    jbe     .Let_next
    # insert after r14: move the rest up one
    mov     ecx, [rip+es_n]
7:  cmp     ecx, r14d
    jbe     8f
    lea     eax, [rcx-1]
    cmp     eax, r14d
    je      8f
    lea     rdx, [rip+es_t]
    movsd   xmm0, [rdx+rax*8]
    movsd   [rdx+rcx*8], xmm0
    lea     rdx, [rip+es_p]
    lea     r8, [rax+rax*2]
    lea     r9, [rcx+rcx*2]
    movupd  xmm0, [rdx+r8*8]
    movupd  [rdx+r9*8], xmm0
    mov     r10, [rdx+r8*8+16]
    mov     [rdx+r9*8+16], r10
    dec     ecx
    jmp     7b
8:  lea     ecx, [r14+1]
    lea     rdx, [rip+es_t]
    movsd   xmm0, [rsp+96]
    movsd   [rdx+rcx*8], xmm0
    lea     rdx, [rip+es_p]
    lea     r9, [rcx+rcx*2]
    movupd  xmm0, [rsp]
    movupd  [rdx+r9*8], xmm0
    mov     r10, [rsp+16]
    mov     [rdx+r9*8+16], r10
    inc     dword ptr [rip+es_n]
    jmp     .Let_ref
.Let_next:
    inc     r14d
    jmp     .Let_ref
.Let_knots:
    # a polyline: its own points between t0 and t1 (knots 1 .. N), in order
    movsd   xmm0, [rbx+ED_T0]
    mov     rdi, r12
    call    es_push
    mov     r13d, 1                     # forwards: knots 1 .. N
    mov     r15d, 1
    movsd   xmm0, [rbx+ED_T1]
    comisd  xmm0, [rbx+ED_T0]
    jae     1f
    mov     r13d, [r12+CV_N]            # backwards: N .. 1
    mov     r15d, -1
1:  cmp     r13d, 1
    jl      3f
    cmp     r13d, [r12+CV_N]
    jg      3f
    mov     rax, [r12+CV_KN]
    movsd   xmm0, [rax+r13*8]
    movsd   xmm1, [rbx+ED_T0]           # strictly between t0 and t1
    movsd   xmm2, [rbx+ED_T1]
    movsd   xmm3, xmm1
    minsd   xmm3, xmm2
    maxsd   xmm1, xmm2
    comisd  xmm0, xmm3
    jbe     2f
    comisd  xmm0, xmm1
    jae     2f
    mov     rdi, r12
    call    es_push
2:  add     r13d, r15d
    jmp     1b
3:  movsd   xmm0, [rbx+ED_T1]
    mov     rdi, r12
    call    es_push
    jmp     .Let_store
.Let_degen:
    mov     edi, [rbx+ED_V0]            # one point
    call    p_vx
    lea     rdx, [rip+es_p]
    movupd  xmm0, [rax]
    movupd  [rdx], xmm0
    mov     rcx, [rax+16]
    mov     [rdx+16], rcx
    lea     rdx, [rip+es_t]
    mov     qword ptr [rdx], 0
    mov     dword ptr [rip+es_n], 1
.Let_store:
    # the ends are the vertices exactly
    mov     edi, [rbx+ED_V0]
    call    p_vx
    lea     rdx, [rip+es_p]
    movupd  xmm0, [rax]
    movupd  [rdx], xmm0
    mov     rcx, [rax+16]
    mov     [rdx+16], rcx
    mov     edi, [rbx+ED_V1]
    call    p_vx
    mov     ecx, [rip+es_n]
    dec     ecx
    lea     rcx, [rcx+rcx*2]
    lea     rdx, [rip+es_p]
    movupd  xmm0, [rax]
    movupd  [rdx+rcx*8], xmm0
    mov     r8, [rax+16]
    mov     [rdx+rcx*8+16], r8
    mov     edi, [rip+es_n]
    shl     edi, 5
    call    bk_data
    mov     [rbx+ED_POLY], rax
    mov     ecx, [rip+es_n]
    mov     [rbx+ED_NPOLY], ecx
    xor     edx, edx
9:  cmp     edx, ecx
    jae     .Let_out
    lea     r8, [rdx+rdx*2]
    lea     r9, [rip+es_p]
    movupd  xmm0, [r9+r8*8]
    mov     r10, [r9+r8*8+16]
    mov     r11d, edx
    shl     r11d, 5
    movupd  [rax+r11], xmm0
    mov     [rax+r11+16], r10
    lea     r9, [rip+es_t]
    mov     r10, [r9+rdx*8]
    mov     [rax+r11+24], r10
    inc     edx
    jmp     9b
.Let_out:
    add     rsp, 104
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  The triangulation of one face (in scaled (u, v))
# =============================================================================
# cp(eax=point) -> rax = &ct_p[point]
cp:
    shl     eax, 4
    lea     rcx, [rip+ct_p]
    add     rax, rcx
    ret

# orient(rdi=a, rsi=b, rdx=c: points) -> xmm0 = (b - a) x (c - a)
orient:
    movsd   xmm0, [rsi]
    subsd   xmm0, [rdi]
    movsd   xmm1, [rdx+8]
    subsd   xmm1, [rdi+8]
    mulsd   xmm0, xmm1
    movsd   xmm1, [rsi+8]
    subsd   xmm1, [rdi+8]
    movsd   xmm2, [rdx]
    subsd   xmm2, [rdi]
    mulsd   xmm1, xmm2
    subsd   xmm0, xmm1
    ret

# tri_pts(edi=triangle) - r8, r9, r10 = its points' coordinates
tri_pts:
    lea     rax, [rdi+rdi*2]
    lea     rcx, [rip+ct_v]
    lea     rcx, [rcx+rax*4]
    lea     r11, [rip+ct_p]
    mov     eax, [rcx]
    shl     rax, 4
    lea     r8, [r11+rax]
    mov     eax, [rcx+4]
    shl     rax, 4
    lea     r9, [r11+rax]
    mov     eax, [rcx+8]
    shl     rax, 4
    lea     r10, [r11+rax]
    ret

# tv_get(edi=triangle, esi=corner) -> eax = its point
tv_get:
    lea     eax, [rdi+rdi*2]
    add     eax, esi
    lea     rcx, [rip+ct_v]
    mov     eax, [rcx+rax*4]
    ret
# tn_get(edi=triangle, esi=edge) -> eax = the neighbour across it
tn_get:
    lea     eax, [rdi+rdi*2]
    add     eax, esi
    lea     rcx, [rip+ct_n]
    mov     eax, [rcx+rax*4]
    ret
# tn_set(edi=triangle, esi=edge, edx=neighbour)
tn_set:
    lea     eax, [rdi+rdi*2]
    add     eax, esi
    lea     rcx, [rip+ct_n]
    mov     [rcx+rax*4], edx
    ret
# tn_repoint(edi=triangle (-1: none), esi=from, edx=to) - its neighbour link
#   to 'from' goes to 'to'
tn_repoint:
    test    edi, edi
    js      9f
    lea     eax, [rdi+rdi*2]
    lea     rcx, [rip+ct_n]
    lea     rcx, [rcx+rax*4]
    cmp     [rcx], esi
    jne     1f
    mov     [rcx], edx
    ret
1:  cmp     [rcx+4], esi
    jne     2f
    mov     [rcx+4], edx
    ret
2:  cmp     [rcx+8], esi
    jne     9f
    mov     [rcx+8], edx
9:  ret

# con_edge(edi=a, esi=b) -> eax = 1 if a-b is a boundary edge
con_edge:
    lea     rcx, [rip+ft_nxt]
    xor     eax, eax
    cmp     [rcx+rdi*4], esi
    je      1f
    cmp     [rcx+rsi*4], edi
    jne     9f
1:  mov     eax, 1
9:  ret

# ct_adjacency - neighbours from matching edges (an open-addressing table)
ct_adjacency:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     eax, [rip+ct_nt]            # table: a power of two >= 4 * 3 nt
    lea     eax, [rax+rax*2]
    shl     eax, 2
    mov     ecx, 64
1:  cmp     ecx, eax
    jae     2f
    shl     ecx, 1
    jmp     1b
2:  mov     [rip+ct_hcap], ecx
    mov     edi, ecx
    shl     edi, 4                      # key (u64), value (u32), pad
    call    bk_data
    mov     [rip+ct_hash], rax
    mov     rdi, rax
    mov     ecx, [rip+ct_hcap]
    shl     ecx, 1
    mov     rax, -1
    rep     stosq
    # every edge (a, b) into the table; neighbours: -1
    xor     ebx, ebx
.Lca_t:
    cmp     ebx, [rip+ct_nt]
    jae     .Lca_match
    xor     r12d, r12d
3:  cmp     r12d, 3
    jae     4f
    mov     edi, ebx
    mov     esi, r12d
    mov     edx, -1
    call    tn_set
    mov     edi, ebx
    mov     esi, r12d
    call    edge_key
    mov     r13, rax
    call    h_slot
    mov     [rax], r13
    lea     ecx, [rbx+rbx*2]
    add     ecx, r12d
    mov     [rax+8], ecx
    inc     r12d
    jmp     3b
4:  inc     ebx
    jmp     .Lca_t
.Lca_match:
    xor     ebx, ebx
.Lca_m:
    cmp     ebx, [rip+ct_nt]
    jae     .Lca_out
    xor     r12d, r12d
5:  cmp     r12d, 3
    jae     6f
    mov     edi, ebx                    # the twin (b, a)
    mov     esi, r12d
    call    edge_key
    rol     rax, 32
    mov     r13, rax
    call    h_slot
    cmp     [rax], r13
    jne     51f
    mov     eax, [rax+8]                # its triangle
    xor     edx, edx
    mov     ecx, 3
    div     ecx
    mov     edx, eax
    mov     edi, ebx
    mov     esi, r12d
    call    tn_set
51: inc     r12d
    jmp     5b
6:  inc     ebx
    jmp     .Lca_m
.Lca_out:
    add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
# edge_key(edi=triangle, esi=edge) -> rax = a << 32 | b
edge_key:
    push    rbx
    mov     ebx, edi
    call    tv_get
    push    rax
    lea     ecx, [rsi+1]
    cmp     ecx, 3
    jb      1f
    xor     ecx, ecx
1:  mov     edi, ebx
    mov     esi, ecx
    call    tv_get
    pop     rcx
    shl     rcx, 32
    or      rax, rcx
    pop     rbx
    ret
# h_slot(r13=key) -> rax = its slot (the key's, or the first empty)
h_slot:
    mov     rax, r13
    mov     rcx, 0x9e3779b97f4a7c15
    imul    rax, rcx
    shr     rax, 32
    mov     ecx, [rip+ct_hcap]
    dec     ecx
    and     eax, ecx
1:  mov     rdx, rax
    shl     rdx, 4
    add     rdx, [rip+ct_hash]
    cmp     qword ptr [rdx], -1
    je      2f
    cmp     [rdx], r13
    je      2f
    inc     eax
    and     eax, ecx
    jmp     1b
2:  mov     rax, rdx
    ret

# ct_flip(edi=triangle, esi=edge) -> eax = 1 if the edge was flipped (to be
#   Delaunay); the outer edges go on the stack
.equ FL_T,   0
.equ FL_I,   4
.equ FL_N,   8
.equ FL_J,   12
.equ FL_A,   16
.equ FL_B,   20
.equ FL_C,   24
.equ FL_D,   28
.equ FL_A1,  32                         # neighbours: t across (b,c), (c,a)
.equ FL_A2,  36
.equ FL_B1,  40                         # n across (a,d), (d,b)
.equ FL_B2,  44
.equ FL_CT,  48                         # constrained bits of t, n
.equ FL_CN,  52
ct_flip:
    push    rbx
    push    r12
    sub     rsp, 72
    mov     [rsp+FL_T], edi
    mov     [rsp+FL_I], esi
    call    tn_get
    test    eax, eax
    js      .Lfl_no
    mov     [rsp+FL_N], eax
    mov     edi, [rsp+FL_T]             # a, b, c
    mov     esi, [rsp+FL_I]
    call    tv_get
    mov     [rsp+FL_A], eax
    mov     esi, [rsp+FL_I]
    call    next3
    mov     ebx, esi
    mov     edi, [rsp+FL_T]
    call    tv_get
    mov     [rsp+FL_B], eax
    call    next3
    mov     r12d, esi
    mov     edi, [rsp+FL_T]
    call    tv_get
    mov     [rsp+FL_C], eax
    mov     edi, [rsp+FL_A]             # a boundary edge stays
    mov     esi, [rsp+FL_B]
    call    con_edge
    test    eax, eax
    jnz     .Lfl_no
    mov     edi, [rsp+FL_T]
    mov     esi, ebx
    call    tn_get
    mov     [rsp+FL_A1], eax
    mov     edi, [rsp+FL_T]
    mov     esi, r12d
    call    tn_get
    mov     [rsp+FL_A2], eax
    # j: n's edge (b, a)
    xor     ecx, ecx
1:  cmp     ecx, 3
    jae     .Lfl_no
    mov     edi, [rsp+FL_N]
    mov     esi, ecx
    push    rcx
    sub     rsp, 8
    call    tv_get
    add     rsp, 8
    pop     rcx
    cmp     eax, [rsp+FL_B]
    je      2f
    inc     ecx
    jmp     1b
2:  mov     [rsp+FL_J], ecx
    mov     esi, ecx                    # check: the next is a
    call    next3
    mov     ebx, esi
    mov     edi, [rsp+FL_N]
    call    tv_get
    cmp     eax, [rsp+FL_A]
    jne     .Lfl_no
    mov     esi, ebx
    call    next3
    mov     r12d, esi
    mov     edi, [rsp+FL_N]
    call    tv_get
    mov     [rsp+FL_D], eax
    mov     edi, [rsp+FL_N]
    mov     esi, ebx
    call    tn_get
    mov     [rsp+FL_B1], eax
    mov     edi, [rsp+FL_N]
    mov     esi, r12d
    call    tn_get
    mov     [rsp+FL_B2], eax
    # convex: (c, a, d) and (d, b, c) both counter-clockwise
    mov     eax, [rsp+FL_C]
    call    cp
    mov     r8, rax
    mov     eax, [rsp+FL_A]
    call    cp
    mov     r9, rax
    mov     eax, [rsp+FL_D]
    call    cp
    mov     r10, rax
    mov     rdi, r8
    mov     rsi, r9
    mov     rdx, r10
    call    orient
    comisd  xmm0, [rip+bt_tiny]
    jbe     .Lfl_no
    mov     eax, [rsp+FL_B]
    call    cp
    mov     rsi, rax
    mov     rdi, r10
    mov     rdx, r8
    call    orient
    comisd  xmm0, [rip+bt_tiny]
    jbe     .Lfl_no
    # d inside the circle through a, b, c?
    mov     eax, [rsp+FL_A]
    call    cp
    mov     rdi, rax
    mov     eax, [rsp+FL_B]
    call    cp
    mov     rsi, rax
    mov     eax, [rsp+FL_C]
    call    cp
    mov     rdx, rax
    mov     eax, [rsp+FL_D]
    call    cp
    mov     rcx, rax
    call    incircle
    xorpd   xmm1, xmm1
    comisd  xmm0, xmm1
    jbe     .Lfl_no
    # t = (c, a, d), n = (d, b, c)
    mov     edi, [rsp+FL_T]
    lea     eax, [rdi+rdi*2]
    lea     rcx, [rip+ct_v]
    mov     edx, [rsp+FL_C]
    mov     [rcx+rax*4], edx
    mov     edx, [rsp+FL_A]
    mov     [rcx+rax*4+4], edx
    mov     edx, [rsp+FL_D]
    mov     [rcx+rax*4+8], edx
    lea     rcx, [rip+ct_n]
    mov     edx, [rsp+FL_A2]
    mov     [rcx+rax*4], edx
    mov     edx, [rsp+FL_B1]
    mov     [rcx+rax*4+4], edx
    mov     edx, [rsp+FL_N]
    mov     [rcx+rax*4+8], edx
    mov     edi, [rsp+FL_N]
    lea     eax, [rdi+rdi*2]
    lea     rcx, [rip+ct_v]
    mov     edx, [rsp+FL_D]
    mov     [rcx+rax*4], edx
    mov     edx, [rsp+FL_B]
    mov     [rcx+rax*4+4], edx
    mov     edx, [rsp+FL_C]
    mov     [rcx+rax*4+8], edx
    lea     rcx, [rip+ct_n]
    mov     edx, [rsp+FL_B2]
    mov     [rcx+rax*4], edx
    mov     edx, [rsp+FL_A1]
    mov     [rcx+rax*4+4], edx
    mov     edx, [rsp+FL_T]
    mov     [rcx+rax*4+8], edx
    mov     edi, [rsp+FL_A1]            # A1 now borders n, B1 borders t
    mov     esi, [rsp+FL_T]
    mov     edx, [rsp+FL_N]
    call    tn_repoint
    mov     edi, [rsp+FL_B1]
    mov     esi, [rsp+FL_N]
    mov     edx, [rsp+FL_T]
    call    tn_repoint
    mov     edi, [rsp+FL_T]             # check t's (a, d) and n's (d, b)
    mov     esi, 1
    call    ct_push
    mov     edi, [rsp+FL_N]
    xor     esi, esi
    call    ct_push
    mov     edi, [rsp+FL_T]             # (and their other outer edges)
    xor     esi, esi
    call    ct_push
    mov     edi, [rsp+FL_N]
    mov     esi, 1
    call    ct_push
    mov     eax, 1
    jmp     .Lfl_out
.Lfl_no:
    xor     eax, eax
.Lfl_out:
    add     rsp, 72
    pop     r12
    pop     rbx
    ret
# next3(esi) -> esi = (esi + 1) mod 3
next3:
    inc     esi
    cmp     esi, 3
    jb      1f
    xor     esi, esi
1:  ret

# incircle(rdi=a, rsi=b, rdx=c, rcx=d) -> xmm0 > 0: d inside the circle of
#   the counter-clockwise a, b, c
incircle:
    movsd   xmm0, [rdi]                 # a - d
    subsd   xmm0, [rcx]
    movsd   xmm1, [rdi+8]
    subsd   xmm1, [rcx+8]
    movsd   xmm2, [rsi]                 # b - d
    subsd   xmm2, [rcx]
    movsd   xmm3, [rsi+8]
    subsd   xmm3, [rcx+8]
    movsd   xmm4, [rdx]                 # c - d
    subsd   xmm4, [rcx]
    movsd   xmm5, [rdx+8]
    subsd   xmm5, [rcx+8]
    movsd   xmm6, xmm2                  # (bx cy - cx by)
    mulsd   xmm6, xmm5
    movsd   xmm7, xmm4
    mulsd   xmm7, xmm3
    subsd   xmm6, xmm7
    movsd   xmm7, xmm0                  # * (ax^2 + ay^2)
    mulsd   xmm7, xmm0
    movsd   xmm8, xmm1
    mulsd   xmm8, xmm1
    addsd   xmm7, xmm8
    mulsd   xmm6, xmm7
    movsd   xmm9, xmm4                  # (cx ay - ax cy)
    mulsd   xmm9, xmm1
    movsd   xmm7, xmm0
    mulsd   xmm7, xmm5
    subsd   xmm9, xmm7
    movsd   xmm7, xmm2                  # * (bx^2 + by^2)
    mulsd   xmm7, xmm2
    movsd   xmm8, xmm3
    mulsd   xmm8, xmm3
    addsd   xmm7, xmm8
    mulsd   xmm9, xmm7
    addsd   xmm6, xmm9
    movsd   xmm9, xmm0                  # (ax by - bx ay)
    mulsd   xmm9, xmm3
    movsd   xmm7, xmm2
    mulsd   xmm7, xmm1
    subsd   xmm9, xmm7
    movsd   xmm7, xmm4                  # * (cx^2 + cy^2)
    mulsd   xmm7, xmm4
    movsd   xmm8, xmm5
    mulsd   xmm8, xmm5
    addsd   xmm7, xmm8
    mulsd   xmm9, xmm7
    addsd   xmm6, xmm9
    movsd   xmm0, xmm6
    ret

# ct_push(edi=triangle, esi=edge)
ct_push:
    mov     eax, [rip+ct_ns]
    cmp     eax, MAXCT
    jae     9f
    lea     rcx, [rip+ct_stk]
    mov     [rcx+rax*8], edi
    mov     [rcx+rax*8+4], esi
    inc     dword ptr [rip+ct_ns]
9:  ret

# ct_legalize - flip until the stack is empty (bounded)
ct_legalize:
    push    rbx
    xor     ebx, ebx
1:  cmp     dword ptr [rip+ct_ns], 0
    je      9f
    inc     ebx
    cmp     ebx, 4*MAXCT
    ja      8f
    dec     dword ptr [rip+ct_ns]
    mov     eax, [rip+ct_ns]
    lea     rcx, [rip+ct_stk]
    mov     edi, [rcx+rax*8]
    mov     esi, [rcx+rax*8+4]
    call    ct_flip
    jmp     1b
8:  mov     dword ptr [rip+ct_ns], 0
9:  pop     rbx
    ret

# ct_delaunay - every edge checked (and flipped while that helps)
ct_delaunay:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     dword ptr [rip+ct_ns], 0
    xor     ebx, ebx
1:  cmp     ebx, [rip+ct_nt]
    jae     3f
    xor     r12d, r12d
2:  mov     edi, ebx
    mov     esi, r12d
    call    ct_push
    inc     r12d
    cmp     r12d, 3
    jb      2b
    inc     ebx
    jmp     1b
3:  call    ct_legalize
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# ct_locate(rdi=point) -> eax = the triangle holding it, or -1 (a walk,
#   then every triangle)
ct_locate:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 16
    mov     r12, rdi
    mov     ebx, [rip+ct_last]
    cmp     ebx, [rip+ct_nt]
    jb      1f
    xor     ebx, ebx
1:  xor     r13d, r13d                  # steps
.Llo_walk:
    inc     r13d
    cmp     r13d, 4096
    ja      .Llo_scan
    mov     edi, ebx
    call    tri_pts
    mov     [rsp], r10
    mov     rdi, r8                     # outside edge 0 (a b)?
    mov     rsi, r9
    mov     rdx, r12
    push    r8
    push    r9
    call    orient
    pop     r9
    pop     r8
    xorpd   xmm1, xmm1
    comisd  xmm0, xmm1
    jae     2f
    xor     esi, esi
    jmp     .Llo_step
2:  mov     rdi, r9
    mov     rsi, [rsp]
    mov     rdx, r12
    push    r8
    push    r9
    call    orient
    pop     r9
    pop     r8
    xorpd   xmm1, xmm1
    comisd  xmm0, xmm1
    jae     3f
    mov     esi, 1
    jmp     .Llo_step
3:  mov     rdi, [rsp]
    mov     rsi, r8
    mov     rdx, r12
    call    orient
    xorpd   xmm1, xmm1
    comisd  xmm0, xmm1
    jae     .Llo_found
    mov     esi, 2
.Llo_step:
    mov     edi, ebx
    call    tn_get
    test    eax, eax
    js      .Llo_scan
    mov     ebx, eax
    jmp     .Llo_walk
.Llo_scan:
    xor     ebx, ebx
4:  cmp     ebx, [rip+ct_nt]
    jae     .Llo_none
    mov     edi, ebx
    call    tri_pts
    mov     [rsp], r10
    mov     [rsp+8], r9
    mov     rdi, r8
    mov     rsi, r9
    mov     rdx, r12
    push    r8
    sub     rsp, 8
    call    orient
    add     rsp, 8
    pop     r8
    xorpd   xmm1, xmm1
    comisd  xmm0, xmm1
    jb      5f
    mov     rdi, [rsp+8]
    mov     rsi, [rsp]
    mov     rdx, r12
    push    r8
    sub     rsp, 8
    call    orient
    add     rsp, 8
    pop     r8
    xorpd   xmm1, xmm1
    comisd  xmm0, xmm1
    jb      5f
    mov     rdi, [rsp]
    mov     rsi, r8
    mov     rdx, r12
    call    orient
    xorpd   xmm1, xmm1
    comisd  xmm0, xmm1
    jae     .Llo_found
5:  inc     ebx
    jmp     4b
.Llo_none:
    mov     eax, -1
    jmp     9f
.Llo_found:
    mov     [rip+ct_last], ebx
    mov     eax, ebx
9:  add     rsp, 16
    pop     r13
    pop     r12
    pop     rbx
    ret

# ct_insert(edi=point) - split the triangle holding it in three, then flips
ct_insert:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 40
    mov     r12d, edi
    mov     eax, edi
    call    cp
    mov     rdi, rax
    call    ct_locate
    test    eax, eax
    js      .Lci_out
    mov     ebx, eax                    # t = (a, b, c)
    mov     eax, [rip+ct_nt]
    add     eax, 2
    cmp     eax, MAXCT
    ja      .Lci_out
    mov     r13d, [rip+ct_nt]           # t1, t2
    lea     r14d, [r13+1]
    add     dword ptr [rip+ct_nt], 2
    lea     eax, [rbx+rbx*2]
    lea     rcx, [rip+ct_v]
    mov     edx, [rcx+rax*4]
    mov     [rsp], edx                  # a
    mov     edx, [rcx+rax*4+4]
    mov     [rsp+4], edx                # b
    mov     edx, [rcx+rax*4+8]
    mov     [rsp+8], edx                # c
    lea     rcx, [rip+ct_n]
    mov     edx, [rcx+rax*4+4]
    mov     [rsp+12], edx               # across (b, c)
    mov     edx, [rcx+rax*4+8]
    mov     [rsp+16], edx               # across (c, a)
    # t = (a, b, p): n (old0, t1, t2)
    lea     rcx, [rip+ct_v]
    mov     [rcx+rax*4+8], r12d
    lea     rcx, [rip+ct_n]
    mov     [rcx+rax*4+4], r13d
    mov     [rcx+rax*4+8], r14d
    # t1 = (b, c, p): n (old1, t2, t)
    lea     eax, [r13+r13*2]
    lea     rcx, [rip+ct_v]
    mov     edx, [rsp+4]
    mov     [rcx+rax*4], edx
    mov     edx, [rsp+8]
    mov     [rcx+rax*4+4], edx
    mov     [rcx+rax*4+8], r12d
    lea     rcx, [rip+ct_n]
    mov     edx, [rsp+12]
    mov     [rcx+rax*4], edx
    mov     [rcx+rax*4+4], r14d
    mov     [rcx+rax*4+8], ebx
    # t2 = (c, a, p): n (old2, t, t1)
    lea     eax, [r14+r14*2]
    lea     rcx, [rip+ct_v]
    mov     edx, [rsp+8]
    mov     [rcx+rax*4], edx
    mov     edx, [rsp]
    mov     [rcx+rax*4+4], edx
    mov     [rcx+rax*4+8], r12d
    lea     rcx, [rip+ct_n]
    mov     edx, [rsp+16]
    mov     [rcx+rax*4], edx
    mov     [rcx+rax*4+4], ebx
    mov     [rcx+rax*4+8], r13d
    mov     edi, [rsp+12]               # the old neighbours point at t1, t2
    mov     esi, ebx
    mov     edx, r13d
    call    tn_repoint
    mov     edi, [rsp+16]
    mov     esi, ebx
    mov     edx, r14d
    call    tn_repoint
    mov     dword ptr [rip+ct_ns], 0
    mov     edi, ebx
    xor     esi, esi
    call    ct_push
    mov     edi, r13d
    xor     esi, esi
    call    ct_push
    mov     edi, r14d
    xor     esi, esi
    call    ct_push
    call    ct_legalize
.Lci_out:
    add     rsp, 40
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Faces
# =============================================================================
# fp_add(xmm0=u, xmm1=v (true), edx=tessellation vertex) -> eax = a face
#   point (scaled into ct_p), or -1 when full
fp_add:
    mov     eax, [rip+ct_np]
    cmp     eax, MAXCP
    jae     8f
    mov     ecx, eax
    shl     ecx, 4
    lea     r8, [rip+ft_uv]
    movsd   [r8+rcx], xmm0
    movsd   [r8+rcx+8], xmm1
    mulsd   xmm0, [rip+ft_su]
    mulsd   xmm1, [rip+ft_sv]
    lea     r8, [rip+ct_p]
    movsd   [r8+rcx], xmm0
    movsd   [r8+rcx+8], xmm1
    lea     r8, [rip+ft_mv]
    mov     [r8+rax*4], edx
    lea     r8, [rip+ft_nxt]
    mov     dword ptr [r8+rax*4], -1
    inc     dword ptr [rip+ct_np]
    ret
8:  mov     eax, -1
    ret

# fc_tess(edi=face) - its triangles into the body's
.equ FT_F,    0
.equ FT_L,    4
.equ FT_LN,   8
.equ FT_C,    12
.equ FT_CN,   16
.equ FT_E,    24                        # the edge record
.equ FT_REV,  32
.equ FT_K,    36
.equ FT_NP,   40
.equ FT_LS,   44                        # this loop's first point
.equ FT_TS,   48                        # the coedge's edge t at start, end
.equ FT_TE,   56
.equ FT_UV,   64                        # ce_uv out
.equ FT_EV,   96                        # 6 doubles
.equ FT_G,    144                       # guess
.equ FT_MV,   160
.equ FT_KN,   164
fc_tess:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 184
    mov     [rsp+FT_F], edi
    call    p_fc
    mov     rbx, rax
    mov     eax, [rbx+FC_SENSE]
    mov     [rip+ft_sense], eax
    mov     edi, [rbx+FC_SURF]
    call    p_sf
    mov     [rip+ft_surf], rax
    mov     r12, rax
    mov     eax, [r12+SF_TYPE]          # curved: points inside
    xor     ecx, ecx
    cmp     eax, ST_PLANE
    je      2f
1:  mov     ecx, 1
2:  mov     [rip+ft_curved], ecx
    # metric scales at the box's middle: |Su|, |Sv| (v negated for sense 1)
    movsd   xmm0, [rbx+FC_U0]
    addsd   xmm0, [rbx+FC_U1]
    mulsd   xmm0, [rip+bt_half]
    movsd   xmm1, [rbx+FC_V0]
    addsd   xmm1, [rbx+FC_V1]
    mulsd   xmm1, [rip+bt_half]
    mov     rdi, r12
    lea     rsi, [rsp+FT_UV]            # (72 bytes: into FT_EV, unused yet)
    call    srf_eval
    lea     rdi, [rsp+FT_UV+24]
    call    v3len
    maxsd   xmm0, [rip+bt_tiny]
    movsd   [rip+ft_su], xmm0
    lea     rdi, [rsp+FT_UV+48]
    call    v3len
    maxsd   xmm0, [rip+bt_tiny]
    cmp     dword ptr [rip+ft_sense], 0
    je      3f
    xorpd   xmm0, [rip+bt_negm]
3:  movsd   [rip+ft_sv], xmm0
    # the loops' points
    xor     eax, eax
    mov     [rip+ct_np], eax
    mov     [rip+pf_nl], eax
    mov     eax, [rbx+FC_LOOP]
    mov     [rsp+FT_L], eax
    add     eax, [rbx+FC_NLOOP]
    mov     [rsp+FT_LN], eax
.Lft_loop:
    mov     eax, [rsp+FT_L]
    cmp     eax, [rsp+FT_LN]
    jae     .Lft_tri
    mov     eax, [rip+pf_nl]
    cmp     eax, PF_MAXL
    jae     .Lft_tri
    mov     ecx, [rip+ct_np]
    mov     [rsp+FT_LS], ecx
    mov     edi, [rsp+FT_L]
    call    p_lp
    mov     ecx, [rax+LP_FIRST]
    mov     [rsp+FT_C], ecx
    add     ecx, [rax+LP_N]
    mov     [rsp+FT_CN], ecx
.Lft_ce:
    mov     eax, [rsp+FT_C]
    cmp     eax, [rsp+FT_CN]
    jae     .Lft_lend
    mov     edi, eax
    call    p_ce
    mov     r13, rax
    mov     ecx, [r13+CE_REV]
    mov     [rsp+FT_REV], ecx
    mov     edi, [r13+CE_EDGE]
    call    p_ed
    mov     [rsp+FT_E], rax
    mov     r14, rax
    test    dword ptr [r14+ED_FLAGS], EF_DEGEN
    jnz     .Lft_degen
    movsd   xmm0, [r14+ED_T0]
    movsd   xmm1, [r14+ED_T1]
    cmp     dword ptr [rsp+FT_REV], 0
    je      4f
    movsd   xmm2, xmm0
    movsd   xmm0, xmm1
    movsd   xmm1, xmm2
4:  movsd   [rsp+FT_TS], xmm0
    movsd   [rsp+FT_TE], xmm1
    mov     ecx, [r14+ED_NPOLY]
    dec     ecx
    mov     [rsp+FT_KN], ecx            # points 0 .. n - 2 in walking order
    mov     dword ptr [rsp+FT_K], 0
.Lft_pt:
    mov     eax, [rsp+FT_K]
    cmp     eax, [rsp+FT_KN]
    jae     .Lft_cnext
    mov     ecx, eax                    # the edge's point index
    cmp     dword ptr [rsp+FT_REV], 0
    je      5f
    mov     ecx, [r14+ED_NPOLY]
    dec     ecx
    sub     ecx, eax
5:  mov     [rsp+FT_NP], ecx
    # its tessellation vertex: the edge's ends are vertices
    test    ecx, ecx
    jnz     51f
    mov     edi, [r14+ED_V0]
    call    vmap
    jmp     53f
51: mov     edx, [r14+ED_NPOLY]
    dec     edx
    cmp     ecx, edx
    jne     52f
    mov     edi, [r14+ED_V1]
    call    vmap
    jmp     53f
52: call    edge_inner
53: mov     [rsp+FT_MV], eax
    # (u, v): the pcurve's guess, refined on the surface
    mov     eax, [rsp+FT_NP]
    shl     eax, 5
    add     rax, [r14+ED_POLY]
    movupd  xmm0, [rax]
    movupd  [rsp+FT_EV], xmm0
    mov     rcx, [rax+16]
    mov     [rsp+FT_EV+16], rcx
    movsd   xmm0, [rax+24]              # s = (t - ts) / (te - ts)
    subsd   xmm0, [rsp+FT_TS]
    movsd   xmm1, [rsp+FT_TE]
    subsd   xmm1, [rsp+FT_TS]
    divsd   xmm0, xmm1
    mov     edi, [rsp+FT_C]
    lea     rsi, [rsp+FT_UV]
    call    ce_uv
    movsd   xmm0, [rsp+FT_UV]
    movsd   xmm1, [rsp+FT_UV+8]
    mov     rdi, [rip+ft_surf]
    cmp     dword ptr [rdi+SF_TYPE], ST_NURBS
    je      6f
    cmp     dword ptr [rdi+SF_TYPE], ST_PLANE
    je      7f
    movsd   [rsp+FT_G], xmm0
    movsd   [rsp+FT_G+8], xmm1
    lea     rsi, [rsp+FT_EV]
    call    sf_invert
    test    eax, eax
    jz      8f
    movsd   xmm0, [rsp+FT_G]            # a pole: the guess
    movsd   xmm1, [rsp+FT_G+8]
    jmp     8f
6:  lea     rsi, [rsp+FT_EV]
    call    sf_project
    jmp     8f
7:  lea     rsi, [rsp+FT_EV]
    call    sf_invert
8:  mov     edx, [rsp+FT_MV]
    call    fp_add
    inc     dword ptr [rsp+FT_K]
    jmp     .Lft_pt
.Lft_degen:
    # a pole: its pcurve sampled, every point the pole
    mov     edi, [r14+ED_V0]
    call    vmap
    mov     [rsp+FT_MV], eax
    mov     dword ptr [rsp+FT_K], 0
9:  cmp     dword ptr [rsp+FT_K], 8
    jae     .Lft_cnext
    cvtsi2sd xmm0, dword ptr [rsp+FT_K]
    mov     eax, 8
    cvtsi2sd xmm1, eax
    divsd   xmm0, xmm1
    mov     edi, [rsp+FT_C]
    lea     rsi, [rsp+FT_UV]
    call    ce_uv
    movsd   xmm0, [rsp+FT_UV]
    movsd   xmm1, [rsp+FT_UV+8]
    mov     edx, [rsp+FT_MV]
    call    fp_add
    inc     dword ptr [rsp+FT_K]
    jmp     9b
.Lft_cnext:
    inc     dword ptr [rsp+FT_C]
    jmp     .Lft_ce
.Lft_lend:
    # the loop for prof.s: its points, next links
    mov     eax, [rip+pf_nl]
    mov     ecx, [rsp+FT_LS]
    lea     rdx, [rip+pf_ls]
    mov     [rdx+rax*4], ecx
    mov     edx, [rip+ct_np]
    sub     edx, ecx
    lea     r8, [rip+pf_ln]
    mov     [r8+rax*4], edx
    lea     r8, [rip+pf_par]
    mov     dword ptr [r8+rax*4], -1
    lea     r8, [rip+pf_dep]
    mov     dword ptr [r8+rax*4], 0
    test    eax, eax
    jz      10f
    lea     r8, [rip+pf_par]
    mov     dword ptr [r8+rax*4], 0
    lea     r8, [rip+pf_dep]
    mov     dword ptr [r8+rax*4], 1
10: xor     r8d, r8d                    # next links around the loop
11: cmp     r8d, edx
    jae     12f
    lea     r9d, [r8+1]
    cmp     r9d, edx
    jb      111f
    xor     r9d, r9d
111:add     r9d, ecx
    lea     r10d, [rcx+r8]
    lea     r11, [rip+ft_nxt]
    mov     [r11+r10*4], r9d
    inc     r8d
    jmp     11b
12: inc     dword ptr [rip+pf_nl]
    inc     dword ptr [rsp+FT_L]
    jmp     .Lft_loop
.Lft_tri:
    mov     ecx, [rip+ct_np]
    cmp     ecx, 3
    jb      .Lft_out
    cmp     ecx, PF_MAXP
    ja      .Lft_out
    # prof.s's points: the scaled (u, v); its scale for tolerances
    mov     [rip+pf_np], ecx
    lea     rsi, [rip+ct_p]
    lea     rdi, [rip+pf_pt]
    shl     ecx, 1
    rep     movsq
    xorpd   xmm0, xmm0
    lea     rsi, [rip+ct_p]
    mov     ecx, [rip+ct_np]
    shl     ecx, 1
13: dec     ecx
    js      14f
    movsd   xmm1, [rsi+rcx*8]
    andpd   xmm1, [rip+bt_absm]
    maxsd   xmm0, xmm1
    jmp     13b
14: maxsd   xmm0, [rip+bt_tiny]
    movsd   [rip+pf_scale], xmm0
    xor     edi, edi
    call    pf_merge
    call    pf_earclip
    mov     ecx, [rip+pf_ntri]          # into the flip structure
    cmp     ecx, MAXCT/2
    jbe     15f
    mov     ecx, MAXCT/2
15: mov     [rip+ct_nt], ecx
    lea     rsi, [rip+pf_tri]
    lea     rdi, [rip+ct_v]
    imul    ecx, ecx, 3
    rep     movsd
    mov     dword ptr [rip+ct_last], 0
    call    ct_adjacency
    call    ct_delaunay
    cmp     dword ptr [rip+ft_curved], 0
    je      .Lft_emit
    call    inner_points
.Lft_emit:
    xor     r15d, r15d
16: cmp     r15d, [rip+ct_nt]
    jae     .Lft_out
    lea     eax, [r15+r15*2]
    lea     rcx, [rip+ct_v]
    lea     rcx, [rcx+rax*4]
    lea     rdx, [rip+ft_mv]
    mov     eax, [rcx]
    mov     edi, [rdx+rax*4]
    mov     eax, [rcx+4]
    mov     esi, [rdx+rax*4]
    mov     eax, [rcx+8]
    mov     edx, [rdx+rax*4]
    cmp     edi, esi                    # (collapsed at a pole: dropped)
    je      17f
    cmp     esi, edx
    je      17f
    cmp     edi, edx
    je      17f
    call    tt_add
17: inc     r15d
    jmp     16b
.Lft_out:
    add     rsp, 184
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# edge_inner(ecx=point index (1 .. n-2); fc_tess frame: r14=edge) -> eax =
#   its tessellation vertex (the edge's inner points are made together)
edge_inner:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     ebx, ecx
    cmp     dword ptr [r14+ED_AUX], -1
    jne     2f
    mov     eax, [rip+bt_nv]            # first use: all its inner points
    mov     [r14+ED_AUX], eax
    mov     r12d, 1
1:  mov     eax, [r14+ED_NPOLY]
    dec     eax
    cmp     r12d, eax
    jae     2f
    mov     eax, r12d
    shl     eax, 5
    mov     rdi, [r14+ED_POLY]
    add     rdi, rax
    call    tv_add
    inc     r12d
    jmp     1b
2:  mov     eax, [r14+ED_AUX]
    add     eax, ebx
    dec     eax
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# inner_points - a grid inside a doubly curved face at the sampling step,
#   points well inside its loops inserted
inner_points:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 120
    mov     edi, [rsp+120+56+FT_F]      # (fc_tess's face)
    call    p_fc
    mov     rbx, rax
    # steps: 10 degrees on angles; NURBS: the box in 16
    movsd   xmm0, [rip+bt_fine]
    movsd   xmm1, xmm0
    mov     rax, [rip+ft_surf]
    cmp     dword ptr [rax+SF_TYPE], ST_CYL
    je      11f
    cmp     dword ptr [rax+SF_TYPE], ST_CONE
    je      11f
    cmp     dword ptr [rax+SF_TYPE], ST_NURBS
    jne     1f
    movsd   xmm0, [rbx+FC_U1]
    subsd   xmm0, [rbx+FC_U0]
    mov     eax, 16
    cvtsi2sd xmm2, eax
    divsd   xmm0, xmm2
    movsd   xmm1, [rbx+FC_V1]
    subsd   xmm1, [rbx+FC_V0]
    divsd   xmm1, xmm2
    jmp     1f
11: movsd   xmm1, xmm0                  # cylinders, cones: v (a length) at
    mulsd   xmm1, [rip+ft_su]           #  the step the angle makes on the
    movsd   xmm2, [rip+ft_sv]           #  surface
    andpd   xmm2, [rip+bt_absm]
    divsd   xmm1, xmm2
1:  maxsd   xmm0, [rip+bt_tiny]
    maxsd   xmm1, [rip+bt_tiny]
    movsd   [rsp], xmm0                 # du, dv
    movsd   [rsp+8], xmm1
    # keep away from the boundary: 0.45 step in the scaled metric
    movsd   xmm2, xmm0
    mulsd   xmm2, [rip+ft_su]
    andpd   xmm2, [rip+bt_absm]
    movsd   xmm3, xmm1
    mulsd   xmm3, [rip+ft_sv]
    andpd   xmm3, [rip+bt_absm]
    minsd   xmm2, xmm3
    mulsd   xmm2, [rip+bt_keep]
    mulsd   xmm2, xmm2
    movsd   [rsp+16], xmm2              # (squared)
    mov     ebp, [rip+ct_np]            # boundary points: 0 .. ebp - 1
    movsd   xmm0, [rbx+FC_U0]
    addsd   xmm0, [rsp]
    movsd   [rsp+24], xmm0              # u
.Lip_u:
    movsd   xmm0, [rsp+24]
    comisd  xmm0, [rbx+FC_U1]
    jae     .Lip_out
    movsd   xmm0, [rbx+FC_V0]
    addsd   xmm0, [rsp+8]
    movsd   [rsp+32], xmm0              # v
.Lip_v:
    movsd   xmm0, [rsp+32]
    comisd  xmm0, [rbx+FC_V1]
    jae     .Lip_unext
    movsd   xmm0, [rsp+24]              # scaled
    mulsd   xmm0, [rip+ft_su]
    movsd   [rsp+40], xmm0
    movsd   xmm1, [rsp+32]
    mulsd   xmm1, [rip+ft_sv]
    movsd   [rsp+48], xmm1
    call    in_loops                    # inside the loops (even-odd)
    test    eax, eax
    jz      .Lip_vnext
    xor     ecx, ecx                    # far from every boundary point
    lea     rsi, [rip+ct_p]
2:  cmp     ecx, ebp
    jae     3f
    mov     edx, ecx
    shl     edx, 4
    movsd   xmm0, [rsi+rdx]
    subsd   xmm0, [rsp+40]
    mulsd   xmm0, xmm0
    movsd   xmm1, [rsi+rdx+8]
    subsd   xmm1, [rsp+48]
    mulsd   xmm1, xmm1
    addsd   xmm0, xmm1
    comisd  xmm0, [rsp+16]
    jb      .Lip_vnext
    inc     ecx
    jmp     2b
3:  mov     rdi, [rip+ft_surf]          # its point on the surface
    movsd   xmm0, [rsp+24]
    movsd   xmm1, [rsp+32]
    lea     rsi, [rsp+56]
    call    srf_eval
    lea     rdi, [rsp+56]
    call    tv_add
    mov     edx, eax
    movsd   xmm0, [rsp+24]
    movsd   xmm1, [rsp+32]
    call    fp_add
    test    eax, eax
    js      .Lip_out
    mov     edi, eax
    call    ct_insert
.Lip_vnext:
    movsd   xmm0, [rsp+32]
    addsd   xmm0, [rsp+8]
    movsd   [rsp+32], xmm0
    jmp     .Lip_v
.Lip_unext:
    movsd   xmm0, [rsp+24]
    addsd   xmm0, [rsp]
    movsd   [rsp+24], xmm0
    jmp     .Lip_u
.Lip_out:
    add     rsp, 120
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# in_loops(xmm0=u, xmm1=v scaled; prof.s's loops) -> eax = 1 inside
in_loops:
    xor     eax, eax
    lea     rsi, [rip+pf_pt]
    xor     r10d, r10d
1:  cmp     r10d, [rip+pf_nl]
    jae     9f
    lea     rdx, [rip+pf_ls]
    mov     ecx, [rdx+r10*4]
    lea     rdx, [rip+pf_ln]
    mov     edx, [rdx+r10*4]
    xor     r8d, r8d
2:  cmp     r8d, edx
    jae     5f
    lea     r9d, [rcx+r8]
    shl     r9d, 4
    lea     r11d, [r8+1]
    cmp     r11d, edx
    jb      3f
    xor     r11d, r11d
3:  add     r11d, ecx
    shl     r11d, 4
    movsd   xmm2, [rsi+r9+8]
    movsd   xmm3, [rsi+r11+8]
    xor     edi, edi
    comisd  xmm2, xmm1
    seta    dil
    push    rax
    xor     eax, eax
    comisd  xmm3, xmm1
    seta    al
    cmp     eax, edi
    pop     rax
    je      4f
    movsd   xmm4, xmm1
    subsd   xmm4, xmm2
    movsd   xmm5, [rsi+r11]
    subsd   xmm5, [rsi+r9]
    mulsd   xmm4, xmm5
    subsd   xmm3, xmm2
    divsd   xmm4, xmm3
    addsd   xmm4, [rsi+r9]
    comisd  xmm0, xmm4
    jae     4f
    xor     eax, 1
4:  inc     r8d
    jmp     2b
5:  inc     r10d
    jmp     1b
9:  ret

# =============================================================================
#  Bodies
# =============================================================================
# bd_tess(edi=body) - its triangles (BD_TRI), at chord height bt_tol (set
#   from its size when 0)
bd_tess:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 24
    mov     r15d, edi
    call    bt_init
    xor     eax, eax
    mov     [rip+bt_nv], eax
    mov     [rip+bt_nt], eax
    lea     rdi, [rip+bk_vx]            # vertex map: -1 for every vertex
    mov     rdi, [rdi+AR_USED]
    shr     rdi, 3
    add     rdi, 16
    call    bk_data
    mov     [rip+bt_vmap], rax
    mov     rdi, rax
    mov     rcx, [rip+bk_vx+AR_USED]
    shr     rcx, 5
    inc     rcx
    mov     eax, -1
    rep     stosd
    # the tolerance from the vertices' extent when not set
    xorpd   xmm0, xmm0
    ucomisd xmm0, [rip+bt_tol]
    jne     1f
    mov     edi, r15d
    call    bd_size
    mulsd   xmm0, [rip+bt_rel]
    maxsd   xmm0, [rip+bt_tiny]
    movsd   [rip+bt_tol], xmm0
1:  mov     edi, r15d                   # edges: sampled, inner points unmade
    call    p_bd
    mov     ebx, [rax+BD_FIRST]
    mov     r12d, [rax+BD_NF]
    add     r12d, ebx
2:  cmp     ebx, r12d
    jae     5f
    mov     edi, ebx
    call    p_fc
    mov     r13d, [rax+FC_LOOP]
    mov     r14d, [rax+FC_NLOOP]
    add     r14d, r13d
3:  cmp     r13d, r14d
    jae     41f
    mov     edi, r13d
    call    p_lp
    mov     ebp, [rax+LP_FIRST]
    mov     ecx, [rax+LP_N]
    add     ecx, ebp
    mov     [rsp], ecx
4:  cmp     ebp, [rsp]
    jae     40f
    mov     edi, ebp
    call    p_ce
    mov     edi, [rax+CE_EDGE]
    push    rdi
    sub     rsp, 8
    call    ed_tess
    add     rsp, 8
    pop     rdi
    call    p_ed
    mov     dword ptr [rax+ED_AUX], -1
    inc     ebp
    jmp     4b
40: inc     r13d
    jmp     3b
41: inc     ebx
    jmp     2b
5:  mov     edi, r15d                   # faces
    call    p_bd
    mov     ebx, [rax+BD_FIRST]
    mov     r12d, [rax+BD_NF]
    add     r12d, ebx
6:  cmp     ebx, r12d
    jae     7f
    mov     edi, ebx
    call    fc_tess
    inc     ebx
    jmp     6b
7:  mov     edi, TS_SZ                  # kept: a copy of exactly that size
    call    bk_data
    mov     rbx, rax
    mov     eax, [rip+bt_nv]
    mov     [rbx+TS_NV], eax
    mov     eax, [rip+bt_nt]
    mov     [rbx+TS_NT], eax
    mov     edi, [rip+bt_nv]
    imul    rdi, rdi, 24
    add     rdi, 16
    call    bk_data
    mov     [rbx+TS_PV], rax
    mov     rdi, rax
    mov     rsi, [rip+bt_va+AR_BASE]
    mov     ecx, [rip+bt_nv]
    imul    rcx, rcx, 3
    rep     movsq
    mov     edi, [rip+bt_nt]
    imul    rdi, rdi, 12
    add     rdi, 16
    call    bk_data
    mov     [rbx+TS_PT], rax
    mov     rdi, rax
    mov     rsi, [rip+bt_ta+AR_BASE]
    mov     ecx, [rip+bt_nt]
    imul    rcx, rcx, 3
    rep     movsd
    mov     edi, r15d
    call    p_bd
    mov     [rax+BD_TRI], rbx
    add     rsp, 24
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# bd_size(edi=body) -> xmm0 = the diagonal of its vertices' box (bd_reach)
bd_reach:
bd_size:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 56
    movsd   xmm0, [rip+bt_big]
    movsd   [rsp], xmm0
    movsd   [rsp+8], xmm0
    movsd   [rsp+16], xmm0
    xorpd   xmm0, [rip+bt_negm]
    movsd   [rsp+24], xmm0
    movsd   [rsp+32], xmm0
    movsd   [rsp+40], xmm0
    call    p_bd
    mov     ebx, [rax+BD_FIRST]
    mov     r12d, [rax+BD_NF]
    add     r12d, ebx
1:  cmp     ebx, r12d
    jae     5f
    mov     edi, ebx
    call    p_fc
    mov     r13d, [rax+FC_LOOP]
    mov     r14d, [rax+FC_NLOOP]
    add     r14d, r13d
2:  cmp     r13d, r14d
    jae     41f
    mov     edi, r13d
    call    p_lp
    mov     ebp, [rax+LP_FIRST]
    mov     r15d, [rax+LP_N]
    add     r15d, ebp
3:  cmp     ebp, r15d
    jae     40f
    mov     edi, ebp
    call    p_ce
    mov     edi, [rax+CE_EDGE]
    call    p_ed
    mov     edi, [rax+ED_V0]
    call    p_vx
    xor     ecx, ecx
4:  movsd   xmm0, [rax+rcx*8]
    minsd   xmm1, xmm0
    movsd   xmm1, [rsp+rcx*8]
    minsd   xmm1, xmm0
    movsd   [rsp+rcx*8], xmm1
    movsd   xmm1, [rsp+24+rcx*8]
    maxsd   xmm1, xmm0
    movsd   [rsp+24+rcx*8], xmm1
    inc     ecx
    cmp     ecx, 3
    jb      4b
    inc     ebp
    jmp     3b
40: inc     r13d
    jmp     2b
41: inc     ebx
    jmp     1b
5:  xorpd   xmm0, xmm0
    xor     ecx, ecx
6:  movsd   xmm1, [rsp+24+rcx*8]
    subsd   xmm1, [rsp+rcx*8]
    mulsd   xmm1, xmm1
    addsd   xmm0, xmm1
    inc     ecx
    cmp     ecx, 3
    jb      6b
    sqrtsd  xmm0, xmm0
    add     rsp, 56
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# bd_tomesh(edi=body) -> rax = a mesh of its triangles (tessellated if not
#   yet), or 0
bd_tomesh:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 24
    mov     ebx, edi
    call    p_bd
    cmp     qword ptr [rax+BD_TRI], 0
    jne     1f
    mov     edi, ebx
    call    bd_tess
1:  mov     edi, ebx
    call    p_bd
    mov     r12, [rax+BD_TRI]
    mov     edi, [r12+TS_NV]
    mov     esi, [r12+TS_NT]
    imul    esi, esi, 3
    mov     edx, [r12+TS_NT]
    call    mesh_new
    test    rax, rax
    jz      9f
    mov     r13, rax
    xor     r14d, r14d
2:  cmp     r14d, [r12+TS_NV]
    jae     3f
    imul    rax, r14, 24
    add     rax, [r12+TS_PV]
    cvtsd2ss xmm0, [rax]
    cvtsd2ss xmm1, [rax+8]
    cvtsd2ss xmm2, [rax+16]
    mov     rdi, r13
    call    mesh_add_vert
    inc     r14d
    jmp     2b
3:  xor     r14d, r14d
4:  cmp     r14d, [r12+TS_NT]
    jae     5f
    imul    rsi, r14, 12
    add     rsi, [r12+TS_PT]
    mov     rdi, r13
    mov     edx, 3
    call    mesh_add_poly
    inc     r14d
    jmp     4b
5:  mov     rdi, r13
    call    mesh_finish
    mov     rax, r13
9:  add     rsp, 24
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# bd_inside(edi=body, rsi=point) -> eax = 1 inside its tessellation: rays in
#   three directions, the majority of their crossing parities
bd_inside:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     r12, rsi
    call    p_bd
    mov     rbx, [rax+BD_TRI]
    xor     eax, eax
    test    rbx, rbx
    jz      9f
    xor     r13d, r13d                  # votes
    xor     r14d, r14d
1:  cmp     r14d, 3
    jae     2f
    imul    eax, r14d, 24
    lea     rdx, [rip+bt_dirs]
    add     rdx, rax
    mov     rdi, rbx
    mov     rsi, r12
    call    ray_parity
    add     r13d, eax
    inc     r14d
    jmp     1b
2:  xor     eax, eax
    cmp     r13d, 2
    setae   al
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ray_parity(rdi=triangles, rsi=origin, rdx=direction) -> eax = crossings & 1
#   (Moller-Trumbore)
ray_parity:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 112
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13, rdx
    xor     r14d, r14d                  # crossings
    xor     r15d, r15d
.Lrp_t:
    cmp     r15d, [rbx+TS_NT]
    jae     .Lrp_out
    imul    rax, r15, 12
    add     rax, [rbx+TS_PT]
    mov     rcx, [rbx+TS_PV]
    mov     edx, [rax]
    imul    rdx, rdx, 24
    lea     r8, [rcx+rdx]               # v0
    mov     edx, [rax+4]
    imul    rdx, rdx, 24
    lea     r9, [rcx+rdx]               # v1
    mov     edx, [rax+8]
    imul    rdx, rdx, 24
    lea     r10, [rcx+rdx]              # v2
    lea     rdi, [rsp]                  # e1 = v1 - v0, e2 = v2 - v0
    mov     rsi, r9
    mov     rdx, r8
    push    r8
    push    r10
    call    v3sub
    pop     r10
    pop     r8
    lea     rdi, [rsp+24]
    mov     rsi, r10
    mov     rdx, r8
    push    r8
    sub     rsp, 8
    call    v3sub
    add     rsp, 8
    pop     r8
    lea     rdi, [rsp+48]               # p = d x e2
    mov     rsi, r13
    lea     rdx, [rsp+24]
    push    r8
    sub     rsp, 8
    call    v3cross
    add     rsp, 8
    pop     r8
    lea     rdi, [rsp]                  # det = e1 . p
    lea     rsi, [rsp+48]
    call    v3dot
    movsd   xmm1, xmm0
    andpd   xmm1, [rip+bt_absm]
    comisd  xmm1, [rip+bt_tiny]
    jbe     .Lrp_next
    movsd   xmm7, [rip+bt_one]
    divsd   xmm7, xmm0
    movsd   [rsp+104], xmm7             # 1 / det
    lea     rdi, [rsp+72]               # s = o - v0
    mov     rsi, r12
    mov     rdx, r8
    call    v3sub
    lea     rdi, [rsp+72]               # u = s . p / det
    lea     rsi, [rsp+48]
    call    v3dot
    mulsd   xmm0, [rsp+104]
    xorpd   xmm1, xmm1
    comisd  xmm0, xmm1
    jb      .Lrp_next
    comisd  xmm0, [rip+bt_one]
    ja      .Lrp_next
    movsd   [rsp+96], xmm0
    lea     rdi, [rsp+48]               # q = s x e1
    lea     rsi, [rsp+72]
    lea     rdx, [rsp]
    call    v3cross
    mov     rdi, r13                    # v = d . q / det
    lea     rsi, [rsp+48]
    call    v3dot
    mulsd   xmm0, [rsp+104]
    xorpd   xmm1, xmm1
    comisd  xmm0, xmm1
    jb      .Lrp_next
    addsd   xmm0, [rsp+96]
    comisd  xmm0, [rip+bt_one]
    ja      .Lrp_next
    lea     rdi, [rsp+24]               # t = e2 . q / det > 0
    lea     rsi, [rsp+48]
    call    v3dot
    mulsd   xmm0, [rsp+104]
    xorpd   xmm1, xmm1
    comisd  xmm0, xmm1
    jbe     .Lrp_next
    inc     r14d
.Lrp_next:
    inc     r15d
    jmp     .Lrp_t
.Lrp_out:
    mov     eax, r14d
    and     eax, 1
    add     rsp, 112
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.section .note.GNU-stack,"",@progbits
