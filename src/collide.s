# =============================================================================
#  BeeModel - convex collision: support functions, GJK, EPA.
#
#  A part (of a rigid body) is a convex core plus a radius: a box core
#  (half extents; a sphere is a box of size 0, a capsule a box of half
#  height along Y) or a hull (its points). A proxy places a part in the
#  world: the body's rotation rows, the part's centre.
#
#  collide(A, B) runs GJK on the cores' Minkowski difference A - B. When
#  they are apart it gives the closest points (the distance less the radii
#  is the separation); when the cores overlap, EPA expands the simplex to
#  the face of A - B nearest the origin (the depth and normal). The result:
#  the separation (negative when they overlap), a point on each surface and
#  the normal from A to B. Re-entrant: all its memory is on the stack, so
#  workers collide pairs in parallel.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"

.globl collide
.globl part_support
.globl proxy_support
.globl px_place
.globl tri_closest

# a part
.equ PT_TYPE,   0                       # 0 a box core, 1 a hull
.equ PT_NV,     4                       # hull points
.equ PT_VERTS,  8                       #  (vec4, part-local)
.equ PT_RAD,    16                      # radius around the core
.equ PT_HALF,   32                      # box: half extents (vec4)
.equ PT_OFF,    48                      # its centre in the body (vec4)
# a proxy
.equ PX_R0,     0                       # the body's rotation, rows
.equ PX_R1,     16
.equ PX_R2,     32
.equ PX_C,      48                      # the part's centre in the world
.equ PX_PART,   64
.equ PX_SZ,     80
# GJK's simplex (on the stack, 16-aligned)
.equ GJ_N,      0
.equ GJ_PA,     8
.equ GJ_PB,     16
.equ GJ_W,      32                      # 4 x vec4: A - B,
.equ GJ_A,      96                      #  A's point,
.equ GJ_B,      160                     #  B's point
.equ GJ_L,      224                     # barycentric weights
.equ GJ_V,      240                     # the closest point to the origin
.equ GJ_T,      256                     # scratch (tri_closest's out: 64)
.equ GJ_T2,     320
.equ GJ_SZ,     448
# tri_closest's out
.equ TC_V,      0
.equ TC_U,      16                      # weights (3 floats)
.equ TC_MASK,   28                      # vertices kept (bits)
# EPA
.equ EP_MAXV,   64
.equ EP_MAXF,   128
.equ EF_SZ,     32                      # i0 i1 i2 dead, normal (vec4)...
.equ EF_N,      16                      # (normal xyz, distance in w)
# the result
.equ CR_SEP,    0
.equ CR_PA,     16
.equ CR_PB,     32
.equ CR_N,      48

.macro DOT3 d, s
    dpps    \d, \s, 0x71
.endm
# d = a x b (t: scratch; a's and b's lane 3 must be 0)
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
cx_sign:        .long 0x80000000, 0x80000000, 0x80000000, 0
cx_xyz:         .long -1, -1, -1, 0
cx_one4:        .float 1, 1, 1, 0
cx_axes:        .float 1, 0, 0, 0,  0, 1, 0, 0,  0, 0, 1, 0
                .float -1, 0, 0, 0,  0, -1, 0, 0,  0, 0, -1, 0
cx_one:         .float 1.0
cx_tiny:        .float 1.0e-12
cx_eps:         .float 1.0e-6
cx_epa:         .float 1.0e-4
cx_dup:         .float 1.0e-10
cx_small:       .float 1.0e-8
.text

# -----------------------------------------------------------------------------
# Supports
# -----------------------------------------------------------------------------
# part_support(rdi=part, xmm0=direction, part-local) -> xmm0 = the core's
#   farthest point that way (part-local)
part_support:
    cmp     dword ptr [rdi+PT_TYPE], 1
    je      1f
    andps   xmm0, [rip+cx_sign]         # a box: the half extents, signed
    orps    xmm0, [rdi+PT_HALF]
    ret
1:  mov     rsi, [rdi+PT_VERTS]         # a hull: its farthest point
    mov     ecx, [rdi+PT_NV]
    movaps  xmm2, [rsi]
    movaps  xmm1, xmm2
    DOT3    xmm1, xmm0
    dec     ecx
    jle     3f
2:  add     rsi, 16
    movaps  xmm3, [rsi]
    movaps  xmm4, xmm3
    DOT3    xmm4, xmm0
    comiss  xmm4, xmm1
    jbe     21f
    movaps  xmm1, xmm4
    movaps  xmm2, xmm3
21: dec     ecx
    jnz     2b
3:  movaps  xmm0, xmm2
    ret

# proxy_support(rdi=proxy, xmm0=direction, world) -> xmm0 = the world point
proxy_support:
    push    rbx
    mov     rbx, rdi
    movaps  xmm1, xmm0                  # R^T d = dx R0 + dy R1 + dz R2
    shufps  xmm1, xmm1, 0x00
    mulps   xmm1, [rbx+PX_R0]
    movaps  xmm2, xmm0
    shufps  xmm2, xmm2, 0x55
    mulps   xmm2, [rbx+PX_R1]
    addps   xmm1, xmm2
    movaps  xmm2, xmm0
    shufps  xmm2, xmm2, 0xAA
    mulps   xmm2, [rbx+PX_R2]
    addps   xmm1, xmm2
    andps   xmm1, [rip+cx_xyz]
    movaps  xmm0, xmm1
    mov     rdi, [rbx+PX_PART]
    call    part_support
    movaps  xmm1, [rbx+PX_R0]           # C + R s
    DOT3    xmm1, xmm0
    movaps  xmm2, [rbx+PX_R1]
    DOT3    xmm2, xmm0
    movaps  xmm3, [rbx+PX_R2]
    DOT3    xmm3, xmm0
    unpcklps xmm1, xmm2
    movlhps xmm1, xmm3
    addps   xmm1, [rbx+PX_C]
    movaps  xmm0, xmm1
    pop     rbx
    ret

# px_place(rdi=proxy, rsi=rotation rows (3 x vec4), rdx=body position
#   (vec4), rcx=part) - the proxy of a part of a body
px_place:
    movaps  xmm0, [rsi]
    movaps  [rdi+PX_R0], xmm0
    movaps  xmm1, [rsi+16]
    movaps  [rdi+PX_R1], xmm1
    movaps  xmm2, [rsi+32]
    movaps  [rdi+PX_R2], xmm2
    mov     [rdi+PX_PART], rcx
    movaps  xmm3, [rcx+PT_OFF]          # C = P + R off
    DOT3    xmm0, xmm3
    DOT3    xmm1, xmm3
    DOT3    xmm2, xmm3
    unpcklps xmm0, xmm1
    movlhps xmm0, xmm2
    addps   xmm0, [rdx]
    andps   xmm0, [rip+cx_xyz]
    movaps  [rdi+PX_C], xmm0
    ret

# gj_support(rbx=simplex, ecx=slot, xmm0=direction) - A's point along d,
#   B's along -d, their difference, into the slot; xmm0 = the difference
gj_support:
    push    r12
    push    r13
    sub     rsp, 40
    mov     r12d, ecx
    movaps  [rsp], xmm0
    mov     rdi, [rbx+GJ_PA]
    call    proxy_support
    shl     r12, 4
    movaps  [rbx+GJ_A+r12], xmm0
    movaps  xmm0, [rsp]
    xorps   xmm0, [rip+cx_sign]
    mov     rdi, [rbx+GJ_PB]
    call    proxy_support
    movaps  [rbx+GJ_B+r12], xmm0
    movaps  xmm1, [rbx+GJ_A+r12]
    subps   xmm1, xmm0
    movaps  [rbx+GJ_W+r12], xmm1
    movaps  xmm0, xmm1
    add     rsp, 40
    pop     r13
    pop     r12
    ret

# -----------------------------------------------------------------------------
# The closest point of a simplex to the origin
# -----------------------------------------------------------------------------
# seg_closest(rdi=a, rsi=b, rdx=out) - out: v, weights, mask
seg_closest:
    movaps  xmm0, [rdi]
    movaps  xmm1, [rsi]
    subps   xmm1, xmm0                  # ab
    movaps  xmm2, xmm0
    DOT3    xmm2, xmm1                  # a . ab
    movaps  xmm3, xmm1
    DOT3    xmm3, xmm3                  # |ab|^2
    xorps   xmm4, xmm4
    subss   xmm4, xmm2                  # t |ab|^2 = -a . ab
    xorps   xmm5, xmm5
    comiss  xmm4, xmm5
    jbe     1f
    comiss  xmm4, xmm3
    jae     2f
    divss   xmm4, xmm3                  # inside: a + t ab
    movaps  xmm5, xmm4
    shufps  xmm5, xmm5, 0
    mulps   xmm5, xmm1
    addps   xmm5, xmm0
    movaps  [rdx+TC_V], xmm5
    movss   xmm5, [rip+cx_one]
    subss   xmm5, xmm4
    movss   [rdx+TC_U], xmm5
    movss   [rdx+TC_U+4], xmm4
    mov     dword ptr [rdx+TC_MASK], 3
    ret
1:  movaps  [rdx+TC_V], xmm0            # a
    mov     eax, [rip+cx_one]
    mov     [rdx+TC_U], eax
    mov     dword ptr [rdx+TC_MASK], 1
    ret
2:  movaps  xmm0, [rsi]                 # b
    movaps  [rdx+TC_V], xmm0
    mov     eax, [rip+cx_one]
    mov     [rdx+TC_U+4], eax
    mov     dword ptr [rdx+TC_MASK], 2
    ret

# tri_closest(rdi=a, rsi=b, rdx=c, rcx=out) - Ericson's regions: the
#   closest point of the triangle to the origin, its weights, the vertices
#   that make it
tri_closest:
    push    rbp
    mov     rbp, rsp
    and     rsp, -16
    sub     rsp, 64
    movaps  xmm0, [rdi]                 # a
    movaps  xmm1, [rsi]
    subps   xmm1, xmm0                  # ab
    movaps  xmm2, [rdx]
    subps   xmm2, xmm0                  # ac
    movaps  [rsp], xmm1
    movaps  [rsp+16], xmm2
    xorps   xmm3, xmm3
    subps   xmm3, xmm0                  # ap = -a
    movaps  xmm4, xmm1
    DOT3    xmm4, xmm3                  # d1
    movaps  xmm5, xmm2
    DOT3    xmm5, xmm3                  # d2
    xorps   xmm7, xmm7
    comiss  xmm4, xmm7
    ja      1f
    comiss  xmm5, xmm7
    ja      1f
    movaps  [rcx+TC_V], xmm0            # vertex a
    mov     eax, [rip+cx_one]
    mov     [rcx+TC_U], eax
    mov     dword ptr [rcx+TC_U+4], 0
    mov     dword ptr [rcx+TC_U+8], 0
    mov     dword ptr [rcx+TC_MASK], 1
    jmp     9f
1:  movss   [rsp+32], xmm4              # d1
    movss   [rsp+36], xmm5              # d2
    xorps   xmm3, xmm3
    subps   xmm3, [rsi]                 # bp = -b
    movaps  xmm4, xmm1
    DOT3    xmm4, xmm3                  # d3
    movaps  xmm5, xmm2
    DOT3    xmm5, xmm3                  # d4
    movss   [rsp+40], xmm4
    movss   [rsp+44], xmm5
    comiss  xmm4, xmm7
    jb      2f
    comiss  xmm5, xmm4
    ja      2f
    movaps  xmm0, [rsi]                 # vertex b
    movaps  [rcx+TC_V], xmm0
    mov     eax, [rip+cx_one]
    mov     dword ptr [rcx+TC_U], 0
    mov     [rcx+TC_U+4], eax
    mov     dword ptr [rcx+TC_U+8], 0
    mov     dword ptr [rcx+TC_MASK], 2
    jmp     9f
2:  movss   xmm6, [rsp+32]              # vc = d1 d4 - d3 d2
    mulss   xmm6, [rsp+44]
    movss   xmm3, [rsp+40]
    mulss   xmm3, [rsp+36]
    subss   xmm6, xmm3
    movss   [rsp+48], xmm6
    comiss  xmm6, xmm7
    ja      3f
    movss   xmm3, [rsp+32]
    comiss  xmm3, xmm7
    jb      3f
    movss   xmm4, [rsp+40]
    comiss  xmm4, xmm7
    ja      3f
    subss   xmm3, xmm4                  # edge ab: v = d1 / (d1 - d3)
    movss   xmm4, [rsp+32]
    divss   xmm4, xmm3
    movaps  xmm5, xmm4
    shufps  xmm5, xmm5, 0
    mulps   xmm5, [rsp]
    addps   xmm5, [rdi]
    movaps  [rcx+TC_V], xmm5
    movss   xmm5, [rip+cx_one]
    subss   xmm5, xmm4
    movss   [rcx+TC_U], xmm5
    movss   [rcx+TC_U+4], xmm4
    mov     dword ptr [rcx+TC_U+8], 0
    mov     dword ptr [rcx+TC_MASK], 3
    jmp     9f
3:  xorps   xmm3, xmm3
    subps   xmm3, [rdx]                 # cp = -c
    movaps  xmm4, [rsp]
    DOT3    xmm4, xmm3                  # d5
    movaps  xmm5, [rsp+16]
    DOT3    xmm5, xmm3                  # d6
    movss   [rsp+52], xmm4
    movss   [rsp+56], xmm5
    comiss  xmm5, xmm7
    jb      4f
    comiss  xmm4, xmm5
    ja      4f
    movaps  xmm0, [rdx]                 # vertex c
    movaps  [rcx+TC_V], xmm0
    mov     eax, [rip+cx_one]
    mov     dword ptr [rcx+TC_U], 0
    mov     dword ptr [rcx+TC_U+4], 0
    mov     [rcx+TC_U+8], eax
    mov     dword ptr [rcx+TC_MASK], 4
    jmp     9f
4:  movss   xmm6, [rsp+52]              # vb = d5 d2 - d1 d6
    mulss   xmm6, [rsp+36]
    movss   xmm3, [rsp+32]
    mulss   xmm3, [rsp+56]
    subss   xmm6, xmm3
    movss   [rsp+60], xmm6
    comiss  xmm6, xmm7
    ja      5f
    movss   xmm3, [rsp+36]
    comiss  xmm3, xmm7
    jb      5f
    movss   xmm4, [rsp+56]
    comiss  xmm4, xmm7
    ja      5f
    subss   xmm3, xmm4                  # edge ac: w = d2 / (d2 - d6)
    movss   xmm4, [rsp+36]
    divss   xmm4, xmm3
    movaps  xmm5, xmm4
    shufps  xmm5, xmm5, 0
    mulps   xmm5, [rsp+16]
    addps   xmm5, [rdi]
    movaps  [rcx+TC_V], xmm5
    movss   xmm5, [rip+cx_one]
    subss   xmm5, xmm4
    movss   [rcx+TC_U], xmm5
    mov     dword ptr [rcx+TC_U+4], 0
    movss   [rcx+TC_U+8], xmm4
    mov     dword ptr [rcx+TC_MASK], 5
    jmp     9f
5:  movss   xmm6, [rsp+40]              # va = d3 d6 - d5 d4
    mulss   xmm6, [rsp+56]
    movss   xmm3, [rsp+52]
    mulss   xmm3, [rsp+44]
    subss   xmm6, xmm3
    comiss  xmm6, xmm7
    ja      6f
    movss   xmm3, [rsp+44]              # d4 - d3
    subss   xmm3, [rsp+40]
    comiss  xmm3, xmm7
    jb      6f
    movss   xmm4, [rsp+52]              # d5 - d6
    subss   xmm4, [rsp+56]
    comiss  xmm4, xmm7
    jb      6f
    addss   xmm4, xmm3                  # edge bc: w = (d4-d3) / ((d4-d3) + (d5-d6))
    divss   xmm3, xmm4
    movaps  xmm5, [rdx]
    subps   xmm5, [rsi]
    movaps  xmm4, xmm3
    shufps  xmm4, xmm4, 0
    mulps   xmm5, xmm4
    addps   xmm5, [rsi]
    movaps  [rcx+TC_V], xmm5
    movss   xmm5, [rip+cx_one]
    subss   xmm5, xmm3
    mov     dword ptr [rcx+TC_U], 0
    movss   [rcx+TC_U+4], xmm5
    movss   [rcx+TC_U+8], xmm3
    mov     dword ptr [rcx+TC_MASK], 6
    jmp     9f
6:  addss   xmm6, [rsp+60]              # the face: va + vb + vc
    addss   xmm6, [rsp+48]
    comiss  xmm6, [rip+cx_tiny]
    ja      61f
    movss   xmm6, [rip+cx_tiny]
61: movss   xmm3, [rip+cx_one]
    divss   xmm3, xmm6
    movss   xmm4, [rsp+60]
    mulss   xmm4, xmm3                  # v
    movss   xmm5, [rsp+48]
    mulss   xmm5, xmm3                  # w
    movss   [rcx+TC_U+4], xmm4
    movss   [rcx+TC_U+8], xmm5
    movss   xmm3, [rip+cx_one]
    subss   xmm3, xmm4
    subss   xmm3, xmm5
    movss   [rcx+TC_U], xmm3
    shufps  xmm4, xmm4, 0
    mulps   xmm4, [rsp]
    shufps  xmm5, xmm5, 0
    mulps   xmm5, [rsp+16]
    addps   xmm4, xmm5
    addps   xmm4, [rdi]
    movaps  [rcx+TC_V], xmm4
    mov     dword ptr [rcx+TC_MASK], 7
9:  mov     rsp, rbp
    pop     rbp
    ret

# sx_apply(rbx=simplex, rdx=out of seg/tri_closest, ecx=its vertices'
#   slots (a | b << 8 | c << 16)) - keep the vertices the mask names, with
#   their weights; V = out's point
sx_apply:
    push    r12
    push    r13
    push    r14
    sub     rsp, 208                    # (copies: 3 x (w a b) + weights)
    mov     r12d, ecx
    mov     r13, rdx
    xor     r14d, r14d                  # kept
    xor     r8d, r8d                    # which of the three
1:  bt      dword ptr [r13+TC_MASK], r8d
    jnc     2f
    lea     ecx, [r8*8]
    mov     eax, r12d
    shr     eax, cl
    and     eax, 0xff
    shl     eax, 4
    imul    r9d, r14d, 48
    movaps  xmm0, [rbx+GJ_W+rax]
    movups  [rsp+r9], xmm0
    movaps  xmm0, [rbx+GJ_A+rax]
    movups  [rsp+r9+16], xmm0
    movaps  xmm0, [rbx+GJ_B+rax]
    movups  [rsp+r9+32], xmm0
    movss   xmm0, [r13+TC_U+r8*4]
    movss   [rsp+192+r14*4], xmm0
    inc     r14d
2:  inc     r8d
    cmp     r8d, 3
    jb      1b
    mov     [rbx+GJ_N], r14d
    xor     r8d, r8d
3:  cmp     r8d, r14d
    jae     4f
    imul    r9d, r8d, 48
    mov     eax, r8d
    shl     eax, 4
    movups  xmm0, [rsp+r9]
    movaps  [rbx+GJ_W+rax], xmm0
    movups  xmm0, [rsp+r9+16]
    movaps  [rbx+GJ_A+rax], xmm0
    movups  xmm0, [rsp+r9+32]
    movaps  [rbx+GJ_B+rax], xmm0
    movss   xmm0, [rsp+192+r8*4]
    movss   [rbx+GJ_L+r8*4], xmm0
    inc     r8d
    jmp     3b
4:  movaps  xmm0, [r13+TC_V]
    andps   xmm0, [rip+cx_xyz]
    movaps  [rbx+GJ_V], xmm0
    add     rsp, 208
    pop     r14
    pop     r13
    pop     r12
    ret

# sx_solve(rbx=simplex) -> eax = 1 when the simplex holds the origin; else
#   it is cut to the vertices of its closest feature, V that point
sx_solve:
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    mov     eax, [rbx+GJ_N]
    cmp     eax, 1
    je      .Lsx_1
    cmp     eax, 2
    je      .Lsx_2
    cmp     eax, 3
    je      .Lsx_3
    # a tetrahedron: each face with the origin outside it, the nearest
    mov     dword ptr [rbx+GJ_T2+60], 0x7f7fffff   # best |v|^2
    mov     dword ptr [rbx+GJ_T2+56], -1           # its face
    xor     r12d, r12d
1:  cmp     r12d, 4
    jae     3f
    lea     rax, [rip+tet_faces]
    mov     r13d, [rax+r12*4]           # a | b << 8 | c << 16 | d << 24
    mov     ecx, r13d
    call    sx_slot
    movaps  xmm0, [rbx+GJ_W+rax]        # a
    mov     ecx, r13d
    shr     ecx, 8
    call    sx_slot
    movaps  xmm1, [rbx+GJ_W+rax]
    subps   xmm1, xmm0                  # ab
    mov     ecx, r13d
    shr     ecx, 16
    call    sx_slot
    movaps  xmm2, [rbx+GJ_W+rax]
    subps   xmm2, xmm0                  # ac
    CROSS   xmm3, xmm1, xmm2, xmm4      # n
    mov     ecx, r13d
    shr     ecx, 24
    call    sx_slot
    movaps  xmm4, [rbx+GJ_W+rax]
    subps   xmm4, xmm0
    DOT3    xmm4, xmm3                  # n . (d - a)
    xorps   xmm5, xmm5
    subps   xmm5, xmm0
    DOT3    xmm5, xmm3                  # n . (0 - a)
    mulss   xmm4, xmm5
    xorps   xmm6, xmm6
    comiss  xmm4, xmm6                  # the origin and d apart (or flat)
    ja      2f
    ucomiss xmm5, xmm6
    jne     11f
    jnp     2f                          # (on its plane: inside as far as it goes)
11: mov     ecx, r13d
    call    sx_slot
    lea     rdi, [rbx+GJ_W+rax]
    mov     ecx, r13d
    shr     ecx, 8
    call    sx_slot
    lea     rsi, [rbx+GJ_W+rax]
    mov     ecx, r13d
    shr     ecx, 16
    call    sx_slot
    lea     rdx, [rbx+GJ_W+rax]
    lea     rcx, [rbx+GJ_T]
    call    tri_closest
    movaps  xmm0, [rbx+GJ_T+TC_V]
    DOT3    xmm0, xmm0
    comiss  xmm0, [rbx+GJ_T2+60]
    jae     2f
    movss   [rbx+GJ_T2+60], xmm0
    mov     [rbx+GJ_T2+56], r12d
    lea     rsi, [rbx+GJ_T]             # (kept: the best so far)
    lea     rdi, [rbx+GJ_T2]
    mov     ecx, 32
    rep     movsb
2:  inc     r12d
    jmp     1b
3:  mov     eax, [rbx+GJ_T2+56]
    test    eax, eax
    js      .Lsx_in
    lea     rcx, [rip+tet_faces]
    mov     ecx, [rcx+rax*4]
    and     ecx, 0xffffff
    lea     rdx, [rbx+GJ_T2]
    call    sx_apply
    jmp     .Lsx_out
.Lsx_in:
    mov     eax, 1
    jmp     9f
.Lsx_1:
    movaps  xmm0, [rbx+GJ_W]
    movaps  [rbx+GJ_V], xmm0
    mov     eax, [rip+cx_one]
    mov     [rbx+GJ_L], eax
    jmp     .Lsx_out
.Lsx_2:
    lea     rdi, [rbx+GJ_W]
    lea     rsi, [rbx+GJ_W+16]
    lea     rdx, [rbx+GJ_T]
    call    seg_closest
    mov     ecx, 0x0100
    lea     rdx, [rbx+GJ_T]
    call    sx_apply
    jmp     .Lsx_out
.Lsx_3:
    lea     rdi, [rbx+GJ_W]
    lea     rsi, [rbx+GJ_W+16]
    lea     rdx, [rbx+GJ_W+32]
    lea     rcx, [rbx+GJ_T]
    call    tri_closest
    mov     ecx, 0x020100
    lea     rdx, [rbx+GJ_T]
    call    sx_apply
.Lsx_out:
    xor     eax, eax
9:  add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    ret
sx_slot:                                # ecx's low byte -> rax = its offset
    movzx   eax, cl
    shl     eax, 4
    ret

.section .rodata
.align 4
tet_faces:      .long 0x03020100, 0x02030100, 0x01030200, 0x00030201
.text

# -----------------------------------------------------------------------------
# GJK
# -----------------------------------------------------------------------------
# gjk(rbx=simplex with GJ_PA / GJ_PB) -> eax = 1 when the cores overlap;
#   else GJ_V the closest point of A - B to the origin, the simplex its
#   feature (the weights make the witness points)
gjk:
    push    r12
    push    r13
    sub     rsp, 24
    mov     rax, [rbx+GJ_PA]            # start: along centre A - centre B
    movaps  xmm0, [rax+PX_C]
    mov     rax, [rbx+GJ_PB]
    subps   xmm0, [rax+PX_C]
    movaps  xmm1, xmm0
    DOT3    xmm1, xmm1
    comiss  xmm1, [rip+cx_small]
    ja      1f
    movaps  xmm0, [rip+cx_axes]
1:  xor     ecx, ecx
    call    gj_support
    mov     dword ptr [rbx+GJ_N], 1
    movaps  [rbx+GJ_V], xmm0
    mov     eax, [rip+cx_one]
    mov     [rbx+GJ_L], eax
    mov     r12d, 64                    # iterations
2:  movaps  xmm0, [rbx+GJ_V]
    movaps  xmm1, xmm0
    DOT3    xmm1, xmm1                  # |v|^2
    comiss  xmm1, [rip+cx_tiny]
    jbe     .Lgj_hit
    movss   [rsp], xmm1
    xorps   xmm0, [rip+cx_sign]         # w = support(-v)
    mov     ecx, [rbx+GJ_N]
    call    gj_support
    movaps  xmm1, [rbx+GJ_V]            # |v|^2 - v . w <= eps |v|^2: done
    DOT3    xmm1, xmm0
    movss   xmm2, [rsp]
    subss   xmm2, xmm1
    movss   xmm3, [rsp]
    mulss   xmm3, [rip+cx_eps]
    comiss  xmm2, xmm3
    jbe     .Lgj_apart
    mov     ecx, [rbx+GJ_N]             # (the same point again: done)
    xor     edx, edx
3:  cmp     edx, ecx
    jae     4f
    mov     eax, edx
    shl     eax, 4
    movaps  xmm1, [rbx+GJ_W+rax]
    subps   xmm1, xmm0
    DOT3    xmm1, xmm1
    comiss  xmm1, [rip+cx_dup]
    jbe     .Lgj_apart
    inc     edx
    jmp     3b
4:  inc     dword ptr [rbx+GJ_N]
    call    sx_solve
    test    eax, eax
    jnz     .Lgj_hit
    dec     r12d
    jnz     2b
.Lgj_apart:
    xor     eax, eax
    jmp     9f
.Lgj_hit:
    mov     eax, 1
9:  add     rsp, 24
    pop     r13
    pop     r12
    ret

# gj_witness(rbx=simplex, rdi=out pa, rsi=out pb) - sum of weights x points
gj_witness:
    xorps   xmm0, xmm0
    xorps   xmm1, xmm1
    xor     ecx, ecx
1:  cmp     ecx, [rbx+GJ_N]
    jae     2f
    movss   xmm2, [rbx+GJ_L+rcx*4]
    shufps  xmm2, xmm2, 0
    mov     eax, ecx
    shl     eax, 4
    movaps  xmm3, [rbx+GJ_A+rax]
    mulps   xmm3, xmm2
    addps   xmm0, xmm3
    movaps  xmm3, [rbx+GJ_B+rax]
    mulps   xmm3, xmm2
    addps   xmm1, xmm3
    inc     ecx
    jmp     1b
2:  andps   xmm0, [rip+cx_xyz]
    andps   xmm1, [rip+cx_xyz]
    movaps  [rdi], xmm0
    movaps  [rsi], xmm1
    ret

# -----------------------------------------------------------------------------
# EPA
# -----------------------------------------------------------------------------
# The polytope, on the stack: vertices (w, a, b: 48 bytes each), faces, the
#   horizon's edges
.equ EP_V,      0
.equ EP_F,      EP_V + EP_MAXV*48
.equ EP_E,      EP_F + EP_MAXF*EF_SZ
.equ EP_NV,     EP_E + 4*EP_MAXF*2
.equ EP_NF,     EP_NV + 4
.equ EP_NE,     EP_NV + 8
.equ EP_SZ,     EP_NV + 16

# ep_face(r14=polytope, edi=i, esi=j, edx=k) - a face, its outward normal
#   and distance (no room: nothing)
ep_face:
    mov     eax, [r14+EP_NF]
    cmp     eax, EP_MAXF
    jae     9f
    inc     dword ptr [r14+EP_NF]
    imul    eax, eax, EF_SZ
    lea     r8, [r14+EP_F+rax]
    mov     [r8], edi
    mov     [r8+4], esi
    mov     [r8+8], edx
    mov     dword ptr [r8+12], 0
    imul    edi, edi, 48
    imul    esi, esi, 48
    imul    edx, edx, 48
    movaps  xmm0, [r14+EP_V+rdi]
    movaps  xmm1, [r14+EP_V+rsi]
    subps   xmm1, xmm0
    movaps  xmm2, [r14+EP_V+rdx]
    subps   xmm2, xmm0
    CROSS   xmm3, xmm1, xmm2, xmm4
    movaps  xmm4, xmm3
    DOT3    xmm4, xmm4
    sqrtss  xmm4, xmm4
    maxss   xmm4, [rip+cx_tiny]
    shufps  xmm4, xmm4, 0
    divps   xmm3, xmm4
    andps   xmm3, [rip+cx_xyz]
    movaps  xmm4, xmm3
    DOT3    xmm4, xmm0                  # distance (w)
    shufps  xmm4, xmm4, 0
    andps   xmm4, [rip+cx_w]
    orps    xmm3, xmm4
    movaps  [r8+EF_N], xmm3
9:  ret

# ep_edge(r14=polytope, edi=i, esi=j) - the horizon: an edge, or its
#   reverse gone when it is there
ep_edge:
    xor     ecx, ecx
1:  cmp     ecx, [r14+EP_NE]
    jae     3f
    cmp     [r14+EP_E+rcx*8], esi
    jne     2f
    cmp     [r14+EP_E+rcx*8+4], edi
    jne     2f
    mov     eax, [r14+EP_NE]            # the last into its place
    dec     eax
    mov     [r14+EP_NE], eax
    mov     rdx, [r14+EP_E+rax*8]
    mov     [r14+EP_E+rcx*8], rdx
    ret
2:  inc     ecx
    jmp     1b
3:  cmp     ecx, EP_MAXF
    jae     9f
    mov     [r14+EP_E+rcx*8], edi
    mov     [r14+EP_E+rcx*8+4], esi
    inc     dword ptr [r14+EP_NE]
9:  ret

# epa(rbx=simplex holding the origin, rdi=result) -> eax = 1 when found:
#   result's normal (A to B), depth (CR_SEP, positive), witness points
epa:
    push    rbp
    mov     rbp, rsp
    push    r12
    push    r13
    push    r14
    push    r15
    and     rsp, -16
    sub     rsp, EP_SZ+64
    mov     r12, rdi
    lea     r14, [rsp+64]
    call    ep_grow                     # a tetrahedron first
    test    eax, eax
    jz      .Lep_fail
    mov     dword ptr [r14+EP_NV], 4
    mov     dword ptr [r14+EP_NF], 0
    xor     ecx, ecx                    # its vertices
1:  mov     eax, ecx
    shl     eax, 4
    imul    edx, ecx, 48
    movaps  xmm0, [rbx+GJ_W+rax]
    movaps  [r14+EP_V+rdx], xmm0
    movaps  xmm0, [rbx+GJ_A+rax]
    movaps  [r14+EP_V+rdx+16], xmm0
    movaps  xmm0, [rbx+GJ_B+rax]
    movaps  [r14+EP_V+rdx+32], xmm0
    inc     ecx
    cmp     ecx, 4
    jb      1b
    # faces, wound outward (away from the fourth vertex)
    lea     r15, [rip+tet_faces]
    xor     r13d, r13d
2:  mov     eax, [r15+r13*4]
    movzx   edi, al
    shr     eax, 8
    movzx   esi, al
    shr     eax, 8
    movzx   edx, al
    shr     eax, 8
    mov     r8d, eax                    # the opposite vertex
    mov     [rsp], r8d
    push    rdi
    push    rsi
    push    rdx
    sub     rsp, 8
    call    ep_face
    add     rsp, 8
    pop     rdx
    pop     rsi
    pop     rdi
    mov     eax, [r14+EP_NF]            # facing the fourth vertex: turn it
    dec     eax
    imul    eax, eax, EF_SZ
    lea     r8, [r14+EP_F+rax]
    mov     ecx, [rsp]
    imul    ecx, ecx, 48
    movaps  xmm0, [r14+EP_V+rcx]
    imul    ecx, edi, 48
    subps   xmm0, [r14+EP_V+rcx]
    DOT3    xmm0, [r8+EF_N]
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    jbe     3f
    dec     dword ptr [r14+EP_NF]
    mov     ecx, esi
    mov     esi, edx
    mov     edx, ecx
    call    ep_face
3:  inc     r13d
    cmp     r13d, 4
    jb      2b
    mov     r13d, 48                    # iterations
.Lep_loop:
    call    ep_nearest                  # r15 = the nearest face
    test    r15, r15
    jz      .Lep_fail
    movaps  xmm0, [r15+EF_N]
    andps   xmm0, [rip+cx_xyz]
    movaps  [rsp+16], xmm0
    mov     ecx, [r14+EP_NV]            # a new point that way
    cmp     ecx, EP_MAXV
    jae     .Lep_done
    call    ep_support
    movaps  xmm1, xmm0
    DOT3    xmm1, [rsp+16]
    movaps  xmm2, [r15+EF_N]
    shufps  xmm2, xmm2, 0xFF
    subss   xmm1, xmm2
    comiss  xmm1, [rip+cx_epa]
    jbe     .Lep_done
    dec     r13d
    jz      .Lep_done
    mov     r9d, [r14+EP_NV]            # the point joins
    inc     dword ptr [r14+EP_NV]
    mov     [rsp+32], r9d
    mov     dword ptr [r14+EP_NE], 0    # faces it sees go; the horizon
    xor     r10d, r10d
4:  cmp     r10d, [r14+EP_NF]
    jae     6f
    imul    eax, r10d, EF_SZ
    lea     r8, [r14+EP_F+rax]
    cmp     dword ptr [r8+12], 0
    jne     5f
    mov     ecx, [r8]
    imul    ecx, ecx, 48
    imul    edx, r9d, 48
    movaps  xmm0, [r14+EP_V+rdx]
    subps   xmm0, [r14+EP_V+rcx]
    DOT3    xmm0, [r8+EF_N]
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    jbe     5f
    mov     dword ptr [r8+12], 1
    mov     edi, [r8]
    mov     esi, [r8+4]
    push    r8
    push    r10
    call    ep_edge
    mov     r8, [rsp+8]
    mov     edi, [r8+4]
    mov     esi, [r8+8]
    call    ep_edge
    mov     r8, [rsp+8]
    mov     edi, [r8+8]
    mov     esi, [r8]
    call    ep_edge
    pop     r10
    pop     r8
    mov     r9d, [rsp+32]
5:  inc     r10d
    jmp     4b
6:  xor     r10d, r10d                  # dead faces out
    xor     r11d, r11d
61: cmp     r10d, [r14+EP_NF]
    jae     62f
    imul    eax, r10d, EF_SZ
    cmp     dword ptr [r14+EP_F+rax+12], 0
    jne     63f
    imul    ecx, r11d, EF_SZ
    movaps  xmm0, [r14+EP_F+rax]
    movaps  [r14+EP_F+rcx], xmm0
    movaps  xmm0, [r14+EP_F+rax+16]
    movaps  [r14+EP_F+rcx+16], xmm0
    inc     r11d
63: inc     r10d
    jmp     61b
62: mov     [r14+EP_NF], r11d
    xor     r10d, r10d                  # new faces: the horizon to the point
7:  cmp     r10d, [r14+EP_NE]
    jae     .Lep_loop
    mov     edi, [r14+EP_E+r10*8]
    mov     esi, [r14+EP_E+r10*8+4]
    mov     edx, [rsp+32]
    push    r10
    push    r10
    call    ep_face
    pop     r10
    pop     r10
    inc     r10d
    jmp     7b
.Lep_done:                              # the face's point: its weights
    movaps  xmm0, [r15+EF_N]
    movaps  xmm7, xmm0
    shufps  xmm7, xmm7, 0xFF            # depth
    andps   xmm0, [rip+cx_xyz]
    movaps  [r12+CR_N], xmm0
    movss   [r12+CR_SEP], xmm7
    shufps  xmm7, xmm7, 0
    mulps   xmm7, xmm0                  # p = n d
    andps   xmm7, [rip+cx_xyz]
    mov     eax, [r15]
    imul    eax, eax, 48
    lea     rdi, [r14+EP_V+rax]
    mov     eax, [r15+4]
    imul    eax, eax, 48
    lea     rsi, [r14+EP_V+rax]
    mov     eax, [r15+8]
    imul    eax, eax, 48
    lea     rdx, [r14+EP_V+rax]
    movaps  xmm1, [rsi]                 # area weights against n
    subps   xmm1, xmm7
    movaps  xmm2, [rdx]
    subps   xmm2, xmm7
    CROSS   xmm3, xmm1, xmm2, xmm4
    DOT3    xmm3, xmm0                  # u (for a)
    movaps  xmm1, [rdx]
    subps   xmm1, xmm7
    movaps  xmm2, [rdi]
    subps   xmm2, xmm7
    CROSS   xmm5, xmm1, xmm2, xmm4
    DOT3    xmm5, xmm0                  # v (for b)
    movaps  xmm1, [rdi]
    subps   xmm1, xmm7
    movaps  xmm2, [rsi]
    subps   xmm2, xmm7
    CROSS   xmm6, xmm1, xmm2, xmm4
    DOT3    xmm6, xmm0                  # w (for c)
    movss   xmm1, xmm3
    addss   xmm1, xmm5
    addss   xmm1, xmm6
    movss   xmm2, xmm1
    andps   xmm2, [rip+cx_absm]
    comiss  xmm2, [rip+cx_tiny]
    ja      8f
    movss   xmm1, [rip+cx_one]          # (degenerate: the first vertex)
    movss   xmm3, xmm1
    xorps   xmm5, xmm5
    xorps   xmm6, xmm6
8:  movss   xmm2, [rip+cx_one]
    divss   xmm2, xmm1
    mulss   xmm3, xmm2
    mulss   xmm5, xmm2
    mulss   xmm6, xmm2
    shufps  xmm3, xmm3, 0
    shufps  xmm5, xmm5, 0
    shufps  xmm6, xmm6, 0
    movaps  xmm0, [rdi+16]
    mulps   xmm0, xmm3
    movaps  xmm1, [rsi+16]
    mulps   xmm1, xmm5
    addps   xmm0, xmm1
    movaps  xmm1, [rdx+16]
    mulps   xmm1, xmm6
    addps   xmm0, xmm1
    andps   xmm0, [rip+cx_xyz]
    movaps  [r12+CR_PA], xmm0
    movaps  xmm0, [rdi+32]
    mulps   xmm0, xmm3
    movaps  xmm1, [rsi+32]
    mulps   xmm1, xmm5
    addps   xmm0, xmm1
    movaps  xmm1, [rdx+32]
    mulps   xmm1, xmm6
    addps   xmm0, xmm1
    andps   xmm0, [rip+cx_xyz]
    movaps  [r12+CR_PB], xmm0
    mov     eax, 1
    jmp     9f
.Lep_fail:
    xor     eax, eax
9:  lea     rsp, [rbp-32]
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    ret

# ep_nearest(r14) -> r15 = the live face nearest the origin, or 0
ep_nearest:
    xor     r15d, r15d
    movss   xmm1, [rip+cx_big]
    xor     ecx, ecx
1:  cmp     ecx, [r14+EP_NF]
    jae     9f
    imul    eax, ecx, EF_SZ
    lea     rdx, [r14+EP_F+rax]
    movss   xmm0, [rdx+EF_N+12]
    comiss  xmm0, xmm1
    jae     2f
    movss   xmm1, xmm0
    mov     r15, rdx
2:  inc     ecx
    jmp     1b
9:  ret

# ep_support(r14, ecx=vertex slot; the direction at the caller's rsp+16) -> xmm0 = the new point (w), stored with a and b
ep_support:
    push    r12
    push    r13
    sub     rsp, 40
    mov     r12d, ecx
    movaps  xmm0, [rsp+80]              # (the caller's [rsp+16])
    movaps  [rsp], xmm0
    mov     rdi, [rbx+GJ_PA]
    call    proxy_support
    imul    r13d, r12d, 48
    movaps  [r14+EP_V+r13+16], xmm0
    movaps  xmm0, [rsp]
    xorps   xmm0, [rip+cx_sign]
    mov     rdi, [rbx+GJ_PB]
    call    proxy_support
    movaps  [r14+EP_V+r13+32], xmm0
    movaps  xmm1, [r14+EP_V+r13+16]
    subps   xmm1, xmm0
    movaps  [r14+EP_V+r13], xmm1
    movaps  xmm0, xmm1
    add     rsp, 40
    pop     r13
    pop     r12
    ret

# ep_grow(rbx=simplex) -> eax = 1 when it is (made) a tetrahedron with volume
ep_grow:
    push    r12
    push    r13
    sub     rsp, 40
    cmp     dword ptr [rbx+GJ_N], 1     # a point: any other point
    jne     2f
    xor     r12d, r12d
1:  cmp     r12d, 6
    jae     .Leg_no
    mov     eax, r12d
    shl     eax, 4
    lea     rcx, [rip+cx_axes]
    movaps  xmm0, [rcx+rax]
    mov     ecx, 1
    call    gj_support
    subps   xmm0, [rbx+GJ_W]
    DOT3    xmm0, xmm0
    inc     r12d
    comiss  xmm0, [rip+cx_small]
    jbe     1b
    mov     dword ptr [rbx+GJ_N], 2
2:  cmp     dword ptr [rbx+GJ_N], 2     # a segment: square to it
    jne     4f
    movaps  xmm6, [rbx+GJ_W+16]
    subps   xmm6, [rbx+GJ_W]
    movaps  [rsp], xmm6
    xor     r12d, r12d
3:  cmp     r12d, 6
    jae     .Leg_no
    mov     eax, r12d
    shl     eax, 4
    lea     rcx, [rip+cx_axes]
    movaps  xmm1, [rcx+rax]
    movaps  xmm6, [rsp]
    CROSS   xmm0, xmm6, xmm1, xmm2
    movaps  xmm2, xmm0
    DOT3    xmm2, xmm2
    inc     r12d
    comiss  xmm2, [rip+cx_small]
    jbe     3b
    mov     ecx, 2
    call    gj_support
    movaps  xmm1, xmm0                  # off the line?
    subps   xmm1, [rbx+GJ_W]
    movaps  xmm6, [rsp]
    CROSS   xmm2, xmm1, xmm6, xmm3
    DOT3    xmm2, xmm2
    comiss  xmm2, [rip+cx_small]
    jbe     3b
    mov     dword ptr [rbx+GJ_N], 3
4:  cmp     dword ptr [rbx+GJ_N], 3     # a triangle: along its normal
    jne     6f
    movaps  xmm1, [rbx+GJ_W+16]
    subps   xmm1, [rbx+GJ_W]
    movaps  xmm2, [rbx+GJ_W+32]
    subps   xmm2, [rbx+GJ_W]
    CROSS   xmm0, xmm1, xmm2, xmm3
    movaps  [rsp], xmm0
    mov     r12d, 2
5:  movaps  xmm0, [rsp]
    mov     ecx, 3
    call    gj_support
    subps   xmm0, [rbx+GJ_W]
    DOT3    xmm0, [rsp]
    andps   xmm0, [rip+cx_absm]
    comiss  xmm0, [rip+cx_small]
    ja      51f
    movaps  xmm0, [rsp]
    xorps   xmm0, [rip+cx_sign]
    movaps  [rsp], xmm0
    dec     r12d
    jnz     5b
    jmp     .Leg_no
51: mov     dword ptr [rbx+GJ_N], 4
6:  mov     eax, 1                      # a tetrahedron: with volume?
    movaps  xmm1, [rbx+GJ_W+16]
    subps   xmm1, [rbx+GJ_W]
    movaps  xmm2, [rbx+GJ_W+32]
    subps   xmm2, [rbx+GJ_W]
    CROSS   xmm0, xmm1, xmm2, xmm3
    movaps  xmm1, [rbx+GJ_W+48]
    subps   xmm1, [rbx+GJ_W]
    DOT3    xmm0, xmm1
    andps   xmm0, [rip+cx_absm]
    comiss  xmm0, [rip+cx_tiny]
    ja      9f
.Leg_no:
    xor     eax, eax
9:  add     rsp, 40
    pop     r13
    pop     r12
    ret

# -----------------------------------------------------------------------------
# collide(rdi=proxy A, rsi=proxy B, rdx=result) - the separation (negative:
#   overlapping), a point on each surface, the normal from A to B
# -----------------------------------------------------------------------------
collide:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12
    push    r13
    push    r14
    and     rsp, -16
    sub     rsp, GJ_SZ+64
    lea     rbx, [rsp+64]
    mov     [rbx+GJ_PA], rdi
    mov     [rbx+GJ_PB], rsi
    mov     r12, rdx
    call    gjk
    test    eax, eax
    jnz     2f
    lea     rdi, [r12+CR_PA]            # apart: the closest points
    lea     rsi, [r12+CR_PB]
    call    gj_witness
    movaps  xmm0, [r12+CR_PB]           # n = (b - a) / |b - a|
    subps   xmm0, [r12+CR_PA]
    movaps  xmm1, xmm0
    DOT3    xmm1, xmm1
    sqrtss  xmm1, xmm1
    comiss  xmm1, [rip+cx_small]
    jbe     2f                          # (touching: as overlapping)
    movss   [r12+CR_SEP], xmm1
    shufps  xmm1, xmm1, 0
    divps   xmm0, xmm1
    andps   xmm0, [rip+cx_xyz]
    movaps  [r12+CR_N], xmm0
    jmp     5f
2:  mov     rdi, r12                    # overlapping: EPA
    call    epa
    test    eax, eax
    jnz     3f
    mov     rax, [rbx+GJ_PA]            # (degenerate: centre to centre, 0)
    mov     rcx, [rbx+GJ_PB]
    movaps  xmm0, [rcx+PX_C]
    subps   xmm0, [rax+PX_C]
    movaps  xmm1, xmm0
    DOT3    xmm1, xmm1
    sqrtss  xmm1, xmm1
    maxss   xmm1, [rip+cx_tiny]
    shufps  xmm1, xmm1, 0
    divps   xmm0, xmm1
    andps   xmm0, [rip+cx_xyz]
    movaps  [r12+CR_N], xmm0
    lea     rdi, [r12+CR_PA]
    lea     rsi, [r12+CR_PB]
    call    gj_witness
    mov     dword ptr [r12+CR_SEP], 0
3:  movss   xmm0, [r12+CR_SEP]          # depth -> a negative separation
    xorps   xmm1, xmm1
    subss   xmm1, xmm0
    movss   [r12+CR_SEP], xmm1
5:  mov     rax, [rbx+GJ_PA]            # the radii: to the surfaces
    mov     rax, [rax+PX_PART]
    movss   xmm2, [rax+PT_RAD]
    mov     rax, [rbx+GJ_PB]
    mov     rax, [rax+PX_PART]
    movss   xmm3, [rax+PT_RAD]
    movss   xmm0, [r12+CR_SEP]
    subss   xmm0, xmm2
    subss   xmm0, xmm3
    movss   [r12+CR_SEP], xmm0
    movaps  xmm1, [r12+CR_N]
    shufps  xmm2, xmm2, 0
    mulps   xmm2, xmm1
    addps   xmm2, [r12+CR_PA]
    movaps  [r12+CR_PA], xmm2
    shufps  xmm3, xmm3, 0
    mulps   xmm3, xmm1
    movaps  xmm0, [r12+CR_PB]
    subps   xmm0, xmm3
    movaps  [r12+CR_PB], xmm0
    lea     rsp, [rbp-32]
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret

.section .rodata
.align 16
cx_w:           .long 0, 0, 0, -1
cx_absm:        .long 0x7fffffff, 0x7fffffff, 0x7fffffff, 0x7fffffff
cx_big:         .float 3.0e38
.text

.section .note.GNU-stack,"",@progbits
