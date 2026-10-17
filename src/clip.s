# =============================================================================
#  BeeModel - contact points between two polytopes, by clipping faces.
#
#  GJK / EPA give one point and the normal. Two boxes resting face on face
#  touch along a whole face, and a stack only stands when its contact
#  points are that face's corners. poly_clip takes each body's feature
#  along the normal (its points within a small tolerance of its support
#  plane: a face, an edge or a vertex). When one of them is a face it is
#  the reference: its outline (a convex polygon, in order) clips the other
#  feature (Sutherland-Hodgman, against the planes through its edges); what
#  is left, at or below the reference face (within the contact margin), are
#  the contact points, reduced to four (the deepest, the one farthest from
#  it, then the most area on each side). The normal is the reference face's.
#  Boxes give their eight corners, hulls their points; rounded parts (a
#  radius) are not polytopes and keep GJK's point. Re-entrant: everything
#  is on the stack.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"

.globl poly_clip

.equ PT_TYPE,   0                       # (collide.s)
.equ PT_NV,     4
.equ PT_VERTS,  8
.equ PT_RAD,    16
.equ PT_HALF,   32
.equ PX_R0,     0
.equ PX_R1,     16
.equ PX_R2,     32
.equ PX_C,      48
.equ PX_PART,   64
.equ CR_SEP,    0
.equ CR_PA,     16
.equ CR_PB,     32
.equ CR_N,      48
.equ CR_SZ,     64
.equ CL_MAXV,   64                      # points a feature
.equ CL_MAXP,   160                     # points while clipping

# the frame
.equ CL_VA,     0                       # A's points (world)
.equ CL_VB,     CL_VA + CL_MAXV*16
.equ CL_FA,     CL_VB + CL_MAXV*16      # A's feature
.equ CL_FB,     CL_FA + CL_MAXV*16
.equ CL_P0,     CL_FB + CL_MAXV*16      # clipping, back and forth
.equ CL_P1,     CL_P0 + CL_MAXP*16
.equ CL_TMP,    CL_P1 + CL_MAXP*16      # (ordering)
.equ CL_N,      CL_TMP + CL_MAXV*16     # the normal (A to B)
.equ CL_T1,     CL_N + 16
.equ CL_T2,     CL_T1 + 16
.equ CL_E0,     CL_T2 + 16
.equ CL_M,      CL_E0 + 16
.equ CL_OUT,    CL_M + 16
.equ CL_NA,     CL_OUT + 8              # counts
.equ CL_NB,     CL_NA + 4
.equ CL_NFA,    CL_NB + 4
.equ CL_NFB,    CL_NFA + 4
.equ CL_NREF,   CL_NFB + 4
.equ CL_NP,     CL_NREF + 4
.equ CL_FLIP,   CL_NP + 4               # 1: B's face is the reference
.equ CL_D,      CL_FLIP + 4             # the reference plane: n . x = d
.equ CL_TA,     CL_D + 4                # tolerances
.equ CL_TB,     CL_TA + 4
.equ CL_I,      CL_TB + 4
.equ CL_PXA,    CL_I + 4 + 4
.equ CL_PXB,    CL_PXA + 8
.equ CL_PIN,    CL_PXB + 8              # the points left (pointer)
.equ CL_K,      CL_PIN + 8              # chosen (4 ints)
.equ CL_MG,     CL_K + 16               # points kept this far above the face
.equ CL_SZ,     (CL_MG + 4 + 15) & -16

.macro DOT3 d, s
    dpps    \d, \s, 0x71
.endm
.macro CROSS d, a, b, t
    movaps  \d, \b
    shufps  \d, \d, 0xC9
    mulps   \d, \a
    movaps  \t, \a
    shufps  \t, \t, 0xC9
    mulps   \t, \b
    subps   \d, \t
    shufps  \d, \d, 0xC9
.endm

.section .rodata
.align 16
cl_xyz:         .long -1, -1, -1, 0
cl_sign:        .long 0x80000000, 0x80000000, 0x80000000, 0
cl_corner:      .float -1, -1, -1, 0,   1, -1, -1, 0,  -1, 1, -1, 0,   1, 1, -1, 0
                .float -1, -1,  1, 0,   1, -1,  1, 0,  -1, 1,  1, 0,   1, 1,  1, 0
cl_ex:          .float 1, 0, 0, 0
cl_ey:          .float 0, 1, 0, 0
cl_tolk:        .float 0.04                 # a feature: within 4% of the size
cl_tolmin:      .float 0.0005
cl_tolmax:      .float 0.02                 #  (2 cm at most: a big ground's
                                            #  top, not its sides)
cl_big:         .float 1e30
cl_eps:         .float 1e-9
cl_half:        .float 0.577
.text

# poly_clip(rdi=proxy A, rsi=proxy B, xmm0=normal from A to B (unit),
#   xmm1=the contact margin, rdx=out: 4 results) -> eax = contact points (0:
#   no face; use GJK's)
poly_clip:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    and     rsp, -16
    sub     rsp, CL_SZ
    mov     rbx, rsp
    andps   xmm0, [rip+cl_xyz]
    movaps  [rbx+CL_N], xmm0
    movss   [rbx+CL_MG], xmm1
    mov     [rbx+CL_PXA], rdi
    mov     [rbx+CL_PXB], rsi
    mov     [rbx+CL_OUT], rdx
    mov     rdi, [rbx+CL_PXA]           # the points, the tolerances
    lea     rsi, [rbx+CL_VA]
    call    cl_gather
    test    eax, eax
    jz      .Lpc_none
    mov     [rbx+CL_NA], eax
    mulss   xmm0, [rip+cl_tolk]
    maxss   xmm0, [rip+cl_tolmin]
    minss   xmm0, [rip+cl_tolmax]
    movss   [rbx+CL_TA], xmm0
    mov     rdi, [rbx+CL_PXB]
    lea     rsi, [rbx+CL_VB]
    call    cl_gather
    test    eax, eax
    jz      .Lpc_none
    mov     [rbx+CL_NB], eax
    mulss   xmm0, [rip+cl_tolk]
    maxss   xmm0, [rip+cl_tolmin]
    minss   xmm0, [rip+cl_tolmax]
    movss   [rbx+CL_TB], xmm0
    lea     rdi, [rbx+CL_VA]            # the features: A along n,
    mov     esi, [rbx+CL_NA]
    movaps  xmm0, [rbx+CL_N]
    movss   xmm1, [rbx+CL_TA]
    lea     rdx, [rbx+CL_FA]
    call    cl_feature
    mov     [rbx+CL_NFA], eax
    lea     rdi, [rbx+CL_VB]            #  B along -n
    mov     esi, [rbx+CL_NB]
    movaps  xmm0, [rbx+CL_N]
    xorps   xmm0, [rip+cl_sign]
    movss   xmm1, [rbx+CL_TB]
    lea     rdx, [rbx+CL_FB]
    call    cl_feature
    mov     [rbx+CL_NFB], eax
    # the reference: A's face if it is one, else B's
    mov     dword ptr [rbx+CL_FLIP], 0
    lea     r12, [rbx+CL_FA]            # reference
    mov     r13d, [rbx+CL_NFA]
    lea     r14, [rbx+CL_FB]            # incident
    mov     r15d, [rbx+CL_NFB]
    cmp     r13d, 3
    jae     1f
    cmp     r15d, 3
    jb      .Lpc_none
    mov     dword ptr [rbx+CL_FLIP], 1
    xchg    r12, r14
    xchg    r13d, r15d
1:  call    cl_basis                    # t1, t2 square to n (t1 x t2 = n)
    mov     rdi, r12                    # its outline, in order
    mov     esi, r13d
    lea     rdx, [rbx+CL_TMP]
    call    cl_order
    mov     r13d, eax
    cmp     r13d, 3
    jb      .Lpc_none
    mov     [rbx+CL_NREF], r13d
    # the reference face's own normal (Newell), turned like n; its plane
    xorps   xmm4, xmm4
    xor     ecx, ecx
2:  cmp     ecx, r13d
    jae     3f
    mov     eax, ecx
    shl     eax, 4
    movaps  xmm0, [r12+rax]
    lea     edx, [rcx+1]
    cmp     edx, r13d
    jb      21f
    xor     edx, edx
21: shl     edx, 4
    movaps  xmm1, [r12+rdx]
    CROSS   xmm2, xmm0, xmm1, xmm3
    addps   xmm4, xmm2
    inc     ecx
    jmp     2b
3:  movaps  xmm0, xmm4
    DOT3    xmm0, xmm0
    comiss  xmm0, [rip+cl_eps]
    jbe     .Lpc_none
    sqrtss  xmm0, xmm0
    shufps  xmm0, xmm0, 0
    divps   xmm4, xmm0
    movaps  xmm1, xmm4                  # turned to point from A to B
    DOT3    xmm1, [rbx+CL_N]
    xorps   xmm2, xmm2
    comiss  xmm1, xmm2
    jae     31f
    xorps   xmm4, [rip+cl_sign]
31: movaps  [rbx+CL_N], xmm4            # n: the face's normal
    movaps  xmm0, [r12]
    DOT3    xmm0, xmm4
    movss   [rbx+CL_D], xmm0
    # the incident feature, in order when it is a face
    mov     rdi, r14
    mov     esi, r15d
    cmp     esi, 3
    jb      4f
    lea     rdx, [rbx+CL_TMP]
    call    cl_order
    mov     r15d, eax
4:  lea     rdi, [rbx+CL_P0]            # into the clip buffer
    mov     rsi, r14
    mov     ecx, r15d
    shl     ecx, 4
    rep     movsb
    mov     [rbx+CL_NP], r15d
    lea     rax, [rbx+CL_P0]
    mov     [rbx+CL_PIN], rax
    # clip by each edge's plane
    mov     dword ptr [rbx+CL_I], 0
5:  mov     ecx, [rbx+CL_I]
    cmp     ecx, [rbx+CL_NREF]
    jae     6f
    cmp     dword ptr [rbx+CL_NP], 0
    je      .Lpc_none
    mov     eax, ecx
    shl     eax, 4
    movaps  xmm0, [r12+rax]             # e0
    lea     edx, [rcx+1]
    cmp     edx, [rbx+CL_NREF]
    jb      51f
    xor     edx, edx
51: shl     edx, 4
    movaps  xmm1, [r12+rdx]
    subps   xmm1, xmm0                  # e1 - e0
    movaps  [rbx+CL_E0], xmm0
    movaps  xmm2, [rbx+CL_N]            # m = n x (e1 - e0), turned towards
    CROSS   xmm3, xmm2, xmm1, xmm4      #  the outline's centre (the average)
    xor     edx, edx
    xorps   xmm5, xmm5
52: cmp     edx, [rbx+CL_NREF]
    jae     53f
    mov     eax, edx
    shl     eax, 4
    addps   xmm5, [r12+rax]
    inc     edx
    jmp     52b
53: cvtsi2ss xmm6, dword ptr [rbx+CL_NREF]
    shufps  xmm6, xmm6, 0
    divps   xmm5, xmm6
    subps   xmm5, [rbx+CL_E0]
    DOT3    xmm5, xmm3
    xorps   xmm6, xmm6
    comiss  xmm5, xmm6
    jae     54f
    xorps   xmm3, [rip+cl_sign]
54: movaps  [rbx+CL_M], xmm3
    mov     rdi, [rbx+CL_PIN]           # in -> the other buffer
    mov     esi, [rbx+CL_NP]
    lea     rdx, [rbx+CL_P1]
    lea     rax, [rbx+CL_P0]
    cmp     rdi, rax
    je      55f
    lea     rdx, [rbx+CL_P0]
55: mov     [rbx+CL_PIN], rdx
    movaps  xmm0, [rbx+CL_E0]
    movaps  xmm1, [rbx+CL_M]
    call    cl_plane
    mov     [rbx+CL_NP], eax
    inc     dword ptr [rbx+CL_I]
    jmp     5b
    # the points left: their gaps to the reference plane; near enough kept
    #   (the gap in lane 3)
6:  mov     r12, [rbx+CL_PIN]
    xor     ecx, ecx
    xor     r13d, r13d                  # kept
61: cmp     ecx, [rbx+CL_NP]
    jae     62f
    mov     eax, ecx
    shl     eax, 4
    movaps  xmm0, [r12+rax]
    movaps  xmm1, xmm0
    DOT3    xmm1, [rbx+CL_N]
    subss   xmm1, [rbx+CL_D]            # A's face: the gap is n.p - d;
    cmp     dword ptr [rbx+CL_FLIP], 0  #  B's: d - n.p
    je      611f
    xorps   xmm1, [rip+cl_sign]
611:comiss  xmm1, [rbx+CL_MG]
    ja      612f
    andps   xmm0, [rip+cl_xyz]
    shufps  xmm1, xmm1, 0               # (x y z gap)
    blendps xmm0, xmm1, 8
    mov     edx, r13d
    shl     edx, 4
    movaps  [r12+rdx], xmm0
    inc     r13d
612:inc     ecx
    jmp     61b
62: test    r13d, r13d
    jz      .Lpc_none
    mov     [rbx+CL_NP], r13d
    call    cl_pick                     # four of them
    mov     r14, [rbx+CL_OUT]           # the results
    xor     r15d, r15d
    mov     r13d, eax
7:  cmp     r15d, r13d
    jae     8f
    mov     ecx, [rbx+CL_K+r15*4]
    shl     ecx, 4
    movaps  xmm0, [r12+rcx]             # p, gap
    movaps  xmm1, xmm0
    shufps  xmm1, xmm1, 0xFF
    movss   [r14+CR_SEP], xmm1
    andps   xmm0, [rip+cl_xyz]
    shufps  xmm1, xmm1, 0
    mulps   xmm1, [rbx+CL_N]            # gap n
    cmp     dword ptr [rbx+CL_FLIP], 0
    jne     71f
    movaps  [r14+CR_PB], xmm0           # on B; A's: p - gap n
    subps   xmm0, xmm1
    movaps  [r14+CR_PA], xmm0
    jmp     72f
71: movaps  [r14+CR_PA], xmm0           # on A; B's: p + gap n
    addps   xmm0, xmm1
    movaps  [r14+CR_PB], xmm0
72: movaps  xmm0, [rbx+CL_N]
    movaps  [r14+CR_N], xmm0
    add     r14, CR_SZ
    inc     r15d
    jmp     7b
8:  mov     eax, r15d
    jmp     .Lpc_out
.Lpc_none:
    xor     eax, eax
.Lpc_out:
    lea     rsp, [rbp-40]
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret

# cl_gather(rdi=proxy, rsi=out) -> eax = its points (world), xmm0 = how far
#   the farthest is from its centre (0 points: a rounded part)
cl_gather:
    push    r12
    push    r13
    push    r14
    mov     r12, rdi
    mov     r13, rsi
    mov     rax, [r12+PX_PART]
    xorps   xmm0, xmm0
    ucomiss xmm0, [rax+PT_RAD]
    jne     .Lcg_none
    xor     r14d, r14d
    cmp     dword ptr [rax+PT_TYPE], 0
    jne     .Lcg_hull
1:  cmp     r14d, 8                     # a box: its corners
    jae     .Lcg_ext
    mov     ecx, r14d
    shl     ecx, 4
    lea     rdx, [rip+cl_corner]
    movaps  xmm0, [rdx+rcx]
    mulps   xmm0, [rax+PT_HALF]
    call    cl_world
    mov     ecx, r14d
    shl     ecx, 4
    movaps  [r13+rcx], xmm0
    inc     r14d
    mov     rax, [r12+PX_PART]
    jmp     1b
.Lcg_hull:
    mov     ecx, [rax+PT_NV]
    cmp     ecx, CL_MAXV
    ja      .Lcg_none
2:  mov     rax, [r12+PX_PART]
    cmp     r14d, [rax+PT_NV]
    jae     .Lcg_ext
    mov     rdx, [rax+PT_VERTS]
    mov     ecx, r14d
    shl     ecx, 4
    movaps  xmm0, [rdx+rcx]
    andps   xmm0, [rip+cl_xyz]
    call    cl_world
    mov     ecx, r14d
    shl     ecx, 4
    movaps  [r13+rcx], xmm0
    inc     r14d
    jmp     2b
.Lcg_ext:
    xorps   xmm2, xmm2                  # the farthest from the centre
    xor     ecx, ecx
3:  cmp     ecx, r14d
    jae     4f
    mov     eax, ecx
    shl     eax, 4
    movaps  xmm0, [r13+rax]
    subps   xmm0, [r12+PX_C]
    DOT3    xmm0, xmm0
    maxss   xmm2, xmm0
    inc     ecx
    jmp     3b
4:  sqrtss  xmm0, xmm2
    mov     eax, r14d
    jmp     9f
.Lcg_none:
    xor     eax, eax
    xorps   xmm0, xmm0
9:  pop     r14
    pop     r13
    pop     r12
    ret

# cl_world(xmm0=part-local point; r12 = proxy) -> xmm0 = C + R p
cl_world:
    movaps  xmm1, [r12+PX_R0]
    DOT3    xmm1, xmm0
    movaps  xmm2, [r12+PX_R1]
    DOT3    xmm2, xmm0
    movaps  xmm3, [r12+PX_R2]
    DOT3    xmm3, xmm0
    unpcklps xmm1, xmm2
    movlhps xmm1, xmm3
    addps   xmm1, [r12+PX_C]
    andps   xmm1, [rip+cl_xyz]
    movaps  xmm0, xmm1
    ret

# cl_feature(rdi=points, esi=count, xmm0=direction, xmm1=tolerance,
#   rdx=out) -> eax = the points within the tolerance of the farthest along
#   the direction
cl_feature:
    movss   xmm2, [rip+cl_big]          # the farthest: -1e30 up
    xorps   xmm2, [rip+cl_sign]
    xor     ecx, ecx
1:  cmp     ecx, esi
    jae     2f
    mov     eax, ecx
    shl     eax, 4
    movaps  xmm3, [rdi+rax]
    DOT3    xmm3, xmm0
    maxss   xmm2, xmm3
    inc     ecx
    jmp     1b
2:  subss   xmm2, xmm1                  # the cut
    xor     ecx, ecx
    xor     r8d, r8d
3:  cmp     ecx, esi
    jae     4f
    mov     eax, ecx
    shl     eax, 4
    movaps  xmm3, [rdi+rax]
    movaps  xmm4, xmm3
    DOT3    xmm4, xmm0
    comiss  xmm4, xmm2
    jb      31f
    mov     eax, r8d
    shl     eax, 4
    movaps  [rdx+rax], xmm3
    inc     r8d
31: inc     ecx
    jmp     3b
4:  mov     eax, r8d
    ret

# cl_basis (rbx = frame) - t1, t2 square to n, t1 x t2 = n
cl_basis:
    movaps  xmm0, [rbx+CL_N]
    movaps  xmm1, xmm0                  # a helper axis far from n
    andps   xmm1, [rip+cl_xyz]
    movss   xmm2, xmm1
    andps   xmm2, [rip+cl_sign]         # (|nx| < 0.577: x, else y)
    xorps   xmm2, xmm1
    comiss  xmm2, [rip+cl_half]
    movaps  xmm3, [rip+cl_ex]
    jb      1f
    movaps  xmm3, [rip+cl_ey]
1:  CROSS   xmm4, xmm3, xmm0, xmm5      # t1 = a x n, normalized
    movaps  xmm5, xmm4
    DOT3    xmm5, xmm5
    sqrtss  xmm5, xmm5
    shufps  xmm5, xmm5, 0
    divps   xmm4, xmm5
    movaps  [rbx+CL_T1], xmm4
    CROSS   xmm5, xmm0, xmm4, xmm6      # t2 = n x t1 (t1 x t2 = n)
    movaps  [rbx+CL_T2], xmm5
    ret

# cl_order(rdi=points (in and out), esi=count, rdx=scratch; rbx = frame) ->
#   eax = the points of their outline, in turn (gift wrapping: from the
#   point least along t1, each next one has all the others on its right
#   seen along n - clockwise; the clip planes face the centre either way)
cl_order:
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbx
    sub     rsp, 16
    mov     r12, rdi
    mov     r13d, esi
    mov     r14, rdx
    xor     ecx, ecx                    # the start: the least u (then v)
    xor     r15d, r15d
1:  inc     ecx
    cmp     ecx, r13d
    jae     2f
    mov     eax, ecx
    shl     eax, 4
    movaps  xmm0, [r12+rax]
    DOT3    xmm0, [rbx+CL_T1]
    mov     eax, r15d
    shl     eax, 4
    movaps  xmm1, [r12+rax]
    DOT3    xmm1, [rbx+CL_T1]
    comiss  xmm0, xmm1
    jae     1b
    mov     r15d, ecx
    jmp     1b
2:  xor     r8d, r8d                    # out count
    mov     r9d, r15d                   # p
3:  cmp     r8d, r13d
    jae     8f
    mov     eax, r9d
    shl     eax, 4
    movaps  xmm0, [r12+rax]
    mov     eax, r8d
    shl     eax, 4
    movaps  [r14+rax], xmm0
    inc     r8d
    # q: the next with every other point on the right of p -> q (r on the
    #   left replaces q; in line: the farther)
    mov     r10d, r9d
    inc     r10d
    cmp     r10d, r13d
    jb      31f
    xor     r10d, r10d
31: xor     ecx, ecx
4:  cmp     ecx, r13d
    jae     5f
    cmp     ecx, r9d
    je      45f
    mov     eax, r9d
    shl     eax, 4
    movaps  xmm0, [r12+rax]             # p
    mov     eax, r10d
    shl     eax, 4
    movaps  xmm1, [r12+rax]
    subps   xmm1, xmm0                  # q - p
    mov     eax, ecx
    shl     eax, 4
    movaps  xmm2, [r12+rax]
    subps   xmm2, xmm0                  # r - p
    CROSS   xmm3, xmm1, xmm2, xmm4
    DOT3    xmm3, [rbx+CL_N]            # > 0: r left of p q
    xorps   xmm4, xmm4
    comiss  xmm3, xmm4
    jb      45f                         # r on the right: q stays
    ja      44f                         # on the left: r
    movaps  xmm5, xmm2                  # in line: the farther
    DOT3    xmm5, xmm5
    movaps  xmm6, xmm1
    DOT3    xmm6, xmm6
    comiss  xmm5, xmm6
    jbe     45f
44: mov     r10d, ecx
45: inc     ecx
    jmp     4b
5:  mov     r9d, r10d
    cmp     r9d, r15d
    jne     3b
8:  mov     ecx, r8d                    # back into the points
    mov     rdi, r12
    mov     rsi, r14
    shl     ecx, 4
    rep     movsb
    mov     eax, r8d
    add     rsp, 16
    pop     rbx
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    ret

# cl_plane(rdi=points in, esi=count, rdx=out, xmm0=a point on the plane,
#   xmm1=its inward normal) -> eax = the points kept (one a polygon of 3 or
#   more, Sutherland-Hodgman; 2 a segment; 1 a point)
cl_plane:
    push    r12
    push    r13
    push    r14
    mov     r12, rdi
    mov     r13d, esi
    mov     r14, rdx
    xor     r8d, r8d
    cmp     r13d, 3
    jae     .Lcp_poly
    xor     ecx, ecx                    # a point or a segment: ends kept or
1:  cmp     ecx, r13d                   #  moved to the plane
    jae     .Lcp_out
    mov     eax, ecx
    shl     eax, 4
    movaps  xmm2, [r12+rax]
    movaps  xmm3, xmm2
    subps   xmm3, xmm0
    DOT3    xmm3, xmm1
    xorps   xmm4, xmm4
    comiss  xmm3, xmm4
    jae     12f
    cmp     r13d, 2                     # out: the segment's crossing
    jne     13f
    mov     eax, ecx
    xor     eax, 1
    shl     eax, 4
    movaps  xmm5, [r12+rax]             # the other end
    movaps  xmm6, xmm5
    subps   xmm6, xmm0
    DOT3    xmm6, xmm1
    comiss  xmm6, xmm4
    jb      13f                         # both out
    movss   xmm7, xmm3                  # t = d / (d - d')
    subss   xmm7, xmm6
    divss   xmm3, xmm7
    shufps  xmm3, xmm3, 0
    subps   xmm5, xmm2
    mulps   xmm5, xmm3
    addps   xmm2, xmm5
12: mov     eax, r8d
    shl     eax, 4
    movaps  [r14+rax], xmm2
    inc     r8d
13: inc     ecx
    jmp     1b
.Lcp_poly:
    lea     r9d, [r13-1]                # prev
    xor     ecx, ecx
2:  cmp     ecx, r13d
    jae     .Lcp_out
    cmp     r8d, CL_MAXP-2
    jae     .Lcp_out
    mov     eax, ecx
    shl     eax, 4
    movaps  xmm2, [r12+rax]             # cur
    mov     eax, r9d
    shl     eax, 4
    movaps  xmm5, [r12+rax]             # prev
    movaps  xmm3, xmm2
    subps   xmm3, xmm0
    DOT3    xmm3, xmm1                  # dc
    movaps  xmm6, xmm5
    subps   xmm6, xmm0
    DOT3    xmm6, xmm1                  # dp
    xorps   xmm4, xmm4
    comiss  xmm3, xmm4
    jb      25f
    comiss  xmm6, xmm4                  # cur in: prev out - the crossing
    jae     24f
    call    cl_cross
24: mov     eax, r8d
    shl     eax, 4
    movaps  [r14+rax], xmm2
    inc     r8d
    jmp     26f
25: comiss  xmm6, xmm4                  # cur out: prev in - the crossing
    jb      26f
    call    cl_cross
26: mov     r9d, ecx
    inc     ecx
    jmp     2b
.Lcp_out:
    mov     eax, r8d
    pop     r14
    pop     r13
    pop     r12
    ret
# cl_cross(xmm2=cur, xmm3=dc, xmm5=prev, xmm6=dp; r14, r8d) - where prev ->
#   cur crosses the plane, added (xmm2, xmm3, xmm4 kept)
cl_cross:
    movss   xmm7, xmm6                  # t = dp / (dp - dc)
    subss   xmm7, xmm3
    movaps  xmm8, xmm6
    divss   xmm8, xmm7
    shufps  xmm8, xmm8, 0
    movaps  xmm9, xmm2
    subps   xmm9, xmm5
    mulps   xmm9, xmm8
    addps   xmm9, xmm5
    mov     eax, r8d
    shl     eax, 4
    movaps  [r14+rax], xmm9
    inc     r8d
    ret

# cl_pick (rbx = frame; points at CL_PIN with the gap in lane 3, CL_NP) ->
#   eax = how many chosen (CL_K): all when 4 or fewer, else the deepest,
#   the farthest from it, and the most area on each side of those two
cl_pick:
    push    r12
    mov     r12, [rbx+CL_PIN]
    mov     ecx, [rbx+CL_NP]
    cmp     ecx, 4
    ja      1f
    xor     eax, eax
17: cmp     eax, ecx
    jae     18f
    mov     [rbx+CL_K+rax*4], eax
    inc     eax
    jmp     17b
18: mov     eax, ecx
    pop     r12
    ret
1:  xor     edx, edx                    # k0: the deepest
    xor     eax, eax
11: inc     eax
    cmp     eax, [rbx+CL_NP]
    jae     12f
    mov     r8d, eax
    shl     r8d, 4
    movss   xmm0, [r12+r8+12]
    mov     r9d, edx
    shl     r9d, 4
    comiss  xmm0, [r12+r9+12]
    jae     11b
    mov     edx, eax
    jmp     11b
12: mov     [rbx+CL_K], edx
    mov     r9d, edx                    # k1: the farthest from it
    shl     r9d, 4
    movaps  xmm7, [r12+r9]
    andps   xmm7, [rip+cl_xyz]
    xorps   xmm6, xmm6
    mov     r10d, edx
    xor     eax, eax
13: cmp     eax, [rbx+CL_NP]
    jae     14f
    mov     r8d, eax
    shl     r8d, 4
    movaps  xmm0, [r12+r8]
    andps   xmm0, [rip+cl_xyz]
    subps   xmm0, xmm7
    DOT3    xmm0, xmm0
    comiss  xmm0, xmm6
    jbe     131f
    movss   xmm6, xmm0
    mov     r10d, eax
131:inc     eax
    jmp     13b
14: mov     [rbx+CL_K+4], r10d
    mov     r9d, r10d
    shl     r9d, 4
    movaps  xmm5, [r12+r9]
    andps   xmm5, [rip+cl_xyz]
    subps   xmm5, xmm7                  # k1 - k0
    movss   xmm8, [rip+cl_big]          # the most area each side
    xorps   xmm8, [rip+cl_sign]
    movss   xmm9, [rip+cl_big]
    mov     r10d, [rbx+CL_K]
    mov     r11d, r10d
    xor     eax, eax
15: cmp     eax, [rbx+CL_NP]
    jae     16f
    mov     r8d, eax
    shl     r8d, 4
    movaps  xmm0, [r12+r8]
    andps   xmm0, [rip+cl_xyz]
    subps   xmm0, xmm7
    CROSS   xmm1, xmm5, xmm0, xmm2
    DOT3    xmm1, [rbx+CL_N]
    comiss  xmm1, xmm8
    jbe     151f
    movss   xmm8, xmm1
    mov     r10d, eax
151:comiss  xmm1, xmm9
    jae     152f
    movss   xmm9, xmm1
    mov     r11d, eax
152:inc     eax
    jmp     15b
16: mov     [rbx+CL_K+8], r10d
    mov     [rbx+CL_K+12], r11d
    mov     eax, 4
    cmp     r10d, r11d                  # (one side only: three)
    jne     9f
    mov     eax, 3
9:  pop     r12
    ret

.section .note.GNU-stack,"",@progbits
