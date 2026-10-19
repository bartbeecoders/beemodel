# =============================================================================
#  BeeModel - signed distance (F-rep) kernel
#
#  Shapes are small graphs of nodes: primitives (sphere, box, cylinder,
#  torus), lattices (gyroid, grid of struts), smooth union / subtraction /
#  intersection (polynomial smooth min with radius k), shells and rigid
#  transforms. sdf_eval walks the graph for one point. sdf_mesh samples the
#  field on a grid around the shape's bounds (one z slice per job, all
#  threads) and meshes it by marching tetrahedra: every cube splits into six
#  tetrahedra around its main diagonal (the same split everywhere, so
#  neighbours share their faces' edges), each crossing a vertex on its edge,
#  one or two triangles per tetrahedron, facing out. No case is ambiguous, so
#  the mesh is manifold; the field is positive at the padded border, so it is
#  closed.
#
#  Lengths are scene units, angles radians. Node 0 is "none".
# =============================================================================
.intel_syntax noprefix
.include "const.inc"

.globl sdf_new
.globl sdf_count
.globl sdf_clear
.globl sdf_eval
.globl sdf_mesh
.globl sdf_bounds
.globl sdf_err
.globl sdf_n
.globl sdf_prism
.globl sdf_invert
.globl mesh_append
.globl sdf_fmesh

.equ ND_SZ,     256
.equ ND_TYPE,   0
.equ ND_A,      4
.equ ND_B,      8
.equ ND_P,      16                      # 6 floats
.equ ND_M,      40                      # 12 floats: world -> node (inverse)
.equ ND_BB,     88                      # min[3], max[3]
.equ ND_FWD,    112                     # 12 floats: node -> world (bounds)
.equ MAXN,      4096
.equ S_SPHERE,  1
.equ S_BOX,     2
.equ S_CYL,     3
.equ S_TORUS,   4
.equ S_GYROID,  5
.equ S_GRID,    6
.equ S_UNION,   10
.equ S_SUB,     11
.equ S_ISECT,   12
.equ S_SHELL,   13
.equ S_XFORM,   14
.equ S_PRISM,   15                      # a profile (prof.s loops) extruded
.equ MAXPTS,    40000000                # grid points (160 MB of floats)
.equ MAP_ANON_PRIV, 0x22

.section .rodata
.align 16
sf_abs:         .long 0x7fffffff, 0x7fffffff, 0x7fffffff, 0x7fffffff
sf_zero:        .float 0.0
sf_half:        .float 0.5
sf_quarter:     .float 0.25
sf_one:         .float 1.0
sf_two:         .float 2.0
sf_big:         .float 1.0e30
sf_inf:         .float 1.0e9                    # "unbounded"
sf_limit:       .float 1.0e5
sf_2pi:         .float 6.2831853
sf_gyro:        .float 0.7                      # |g| / s scale (|grad g| ~ 1.4 s)
sf_tiny:        .float 1.0e-20
sf_tlo:         .float 0.001
sf_thi:         .float 0.999
e_unbounded:    .asciz "the shape is unbounded (intersect a lattice with a solid)"
e_empty:        .asciz "the shape is empty"
e_large:        .asciz "too fine: fewer cells, please"
e_nomem:        .asciz "out of memory"
e_full:         .asciz "too many shape nodes (sclear() starts again)"

.section .bss
.align 16
sdf_nodes:      .skip ND_SZ*MAXN
sdf_n:          .skip 4
sdf_err:        .skip 8                 # the last error message
.align 8
sm_f:           .skip 8                 # field values
sm_fbytes:      .skip 8
sm_cell:        .skip 8                 # cell -> vertex (or -1)
sm_cbytes:      .skip 8
sm_root:        .skip 4
sm_nx:          .skip 4                 # points per axis
sm_ny:          .skip 4
sm_nz:          .skip 4
sm_org:         .skip 12
sm_h:           .skip 4
sm_nv:          .skip 4
sm_nq:          .skip 4
sm_mesh:        .skip 8

.text

# node(edi=id) -> rax = its record
.macro NODE reg, reg32, id
    mov     \reg32, \id
    shl     \reg, 8
    add     \reg, rcx
.endm

sdf_count:
    mov     eax, [rip+sdf_n]
    ret
sdf_clear:
    mov     dword ptr [rip+sdf_n], 0
    ret

# sdf_new(edi=type, esi=a, edx=b, rcx=float[6] params or 0, r8=float[12]
#   inverse transform or 0, r9=float[12] forward transform) -> eax = id
#   (0: full); its bounds follow
sdf_new:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r12d, edi
    mov     r13d, esi
    mov     r14d, edx
    mov     r15, rcx
    mov     eax, [rip+sdf_n]
    test    eax, eax
    jnz     1f
    inc     eax                         # (id 0 = none)
1:  cmp     eax, MAXN
    jae     8f
    mov     ebx, eax
    lea     edx, [rax+1]
    mov     [rip+sdf_n], edx
    mov     rdi, rbx
    shl     rdi, 8
    lea     rax, [rip+sdf_nodes]
    add     rdi, rax
    push    rdi
    xor     eax, eax
    mov     ecx, ND_SZ
    rep     stosb
    pop     rdi
    mov     [rdi+ND_TYPE], r12d
    mov     [rdi+ND_A], r13d
    mov     [rdi+ND_B], r14d
    test    r15, r15
    jz      2f
    push    rdi
    lea     rdi, [rdi+ND_P]
    mov     rsi, r15
    mov     ecx, 24
    rep     movsb
    pop     rdi
2:  test    r8, r8
    jz      3f
    push    rdi
    lea     rdi, [rdi+ND_M]
    mov     rsi, r8
    mov     ecx, 48
    rep     movsb
    mov     rdi, [rsp]
    lea     rdi, [rdi+ND_FWD]
    mov     rsi, r9
    mov     ecx, 48
    rep     movsb
    pop     rdi
3:  mov     rbx, rdi
    call    bounds                      # rbx = node
    mov     rax, rbx
    lea     rcx, [rip+sdf_nodes]
    sub     rax, rcx
    shr     rax, 8
    jmp     9f
8:  lea     rax, [rip+e_full]
    mov     [rip+sdf_err], rax
    xor     eax, eax
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# sdf_bounds(edi=id) -> rax = float[6] min, max
sdf_bounds:
    lea     rcx, [rip+sdf_nodes]
    NODE    rax, eax, edi
    add     rax, ND_BB
    ret

# setbb(rbx=node; xmm0..2 = min, xmm3..5 = max)
setbb:
    movss   [rbx+ND_BB], xmm0
    movss   [rbx+ND_BB+4], xmm1
    movss   [rbx+ND_BB+8], xmm2
    movss   [rbx+ND_BB+12], xmm3
    movss   [rbx+ND_BB+16], xmm4
    movss   [rbx+ND_BB+20], xmm5
    ret

# symbb(xmm0, xmm1, xmm2 = half sizes) - the box -h .. h
symbb:
    movss   xmm3, xmm0
    movss   xmm4, xmm1
    movss   xmm5, xmm2
    xorps   xmm6, xmm6
    movss   xmm7, xmm6
    subss   xmm7, xmm0
    movss   xmm0, xmm7
    movss   xmm7, xmm6
    subss   xmm7, xmm1
    movss   xmm1, xmm7
    movss   xmm7, xmm6
    subss   xmm7, xmm2
    movss   xmm2, xmm7
    jmp     setbb

# bounds (rbx = node) - a box around where the shape can be negative
bounds:
    push    r12
    push    r13
    sub     rsp, 56
    mov     eax, [rbx+ND_TYPE]
    lea     rcx, [rip+sdf_nodes]
    cmp     eax, S_SPHERE
    je      .Lbb_sphere
    cmp     eax, S_BOX
    je      .Lbb_box
    cmp     eax, S_CYL
    je      .Lbb_cyl
    cmp     eax, S_TORUS
    je      .Lbb_torus
    cmp     eax, S_UNION
    je      .Lbb_union
    cmp     eax, S_SUB
    je      .Lbb_sub
    cmp     eax, S_ISECT
    je      .Lbb_isect
    cmp     eax, S_SHELL
    je      .Lbb_shell
    cmp     eax, S_XFORM
    je      .Lbb_xform
    cmp     eax, S_PRISM
    je      .Lbb_out                    # (sdf_prism sets it)
    movss   xmm0, [rip+sf_inf]          # lattices: everywhere
    movss   xmm1, xmm0
    movss   xmm2, xmm0
    call    symbb
    jmp     .Lbb_out
.Lbb_sphere:
    movss   xmm0, [rbx+ND_P]
    movss   xmm1, xmm0
    movss   xmm2, xmm0
    call    symbb
    jmp     .Lbb_out
.Lbb_box:
    movss   xmm0, [rbx+ND_P]
    movss   xmm1, [rbx+ND_P+4]
    movss   xmm2, [rbx+ND_P+8]
    call    symbb
    jmp     .Lbb_out
.Lbb_cyl:
    movss   xmm0, [rbx+ND_P]            # r, h (along y)
    movss   xmm1, [rbx+ND_P+4]
    mulss   xmm1, [rip+sf_half]
    movss   xmm2, xmm0
    call    symbb
    jmp     .Lbb_out
.Lbb_torus:
    movss   xmm0, [rbx+ND_P]            # R + r, r, R + r
    addss   xmm0, [rbx+ND_P+4]
    movss   xmm1, [rbx+ND_P+4]
    movss   xmm2, xmm0
    call    symbb
    jmp     .Lbb_out
.Lbb_union:                             # both, grown by k / 4
    NODE    r12, r12d, [rbx+ND_A]
    NODE    r13, r13d, [rbx+ND_B]
    xor     ecx, ecx
1:  movss   xmm0, [r12+ND_BB+rcx*4]
    minss   xmm0, [r13+ND_BB+rcx*4]
    movss   xmm1, [rbx+ND_P]
    mulss   xmm1, [rip+sf_quarter]
    subss   xmm0, xmm1
    movss   [rbx+ND_BB+rcx*4], xmm0
    movss   xmm0, [r12+ND_BB+12+rcx*4]
    maxss   xmm0, [r13+ND_BB+12+rcx*4]
    addss   xmm0, xmm1
    movss   [rbx+ND_BB+12+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      1b
    jmp     .Lbb_out
.Lbb_sub:                               # a's
    NODE    r12, r12d, [rbx+ND_A]
    mov     rax, [r12+ND_BB]
    mov     [rbx+ND_BB], rax
    mov     rax, [r12+ND_BB+8]
    mov     [rbx+ND_BB+8], rax
    mov     rax, [r12+ND_BB+16]
    mov     [rbx+ND_BB+16], rax
    jmp     .Lbb_out
.Lbb_isect:                             # the overlap
    NODE    r12, r12d, [rbx+ND_A]
    NODE    r13, r13d, [rbx+ND_B]
    xor     ecx, ecx
1:  movss   xmm0, [r12+ND_BB+rcx*4]
    maxss   xmm0, [r13+ND_BB+rcx*4]
    movss   [rbx+ND_BB+rcx*4], xmm0
    movss   xmm0, [r12+ND_BB+12+rcx*4]
    minss   xmm0, [r13+ND_BB+12+rcx*4]
    movss   [rbx+ND_BB+12+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      1b
    jmp     .Lbb_out
.Lbb_shell:                             # a's, grown by t / 2
    NODE    r12, r12d, [rbx+ND_A]
    movss   xmm1, [rbx+ND_P]
    mulss   xmm1, [rip+sf_half]
    xor     ecx, ecx
1:  movss   xmm0, [r12+ND_BB+rcx*4]
    subss   xmm0, xmm1
    movss   [rbx+ND_BB+rcx*4], xmm0
    movss   xmm0, [r12+ND_BB+12+rcx*4]
    addss   xmm0, xmm1
    movss   [rbx+ND_BB+12+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      1b
    jmp     .Lbb_out
.Lbb_xform:                             # the child's 8 corners, moved
    NODE    r12, r12d, [rbx+ND_A]             #  forwards
    movss   xmm0, [rip+sf_big]
    movss   [rbx+ND_BB], xmm0
    movss   [rbx+ND_BB+4], xmm0
    movss   [rbx+ND_BB+8], xmm0
    xorps   xmm1, xmm1
    subss   xmm1, xmm0
    movss   [rbx+ND_BB+12], xmm1
    movss   [rbx+ND_BB+16], xmm1
    movss   [rbx+ND_BB+20], xmm1
    movss   xmm0, [r12+ND_BB+12]        # unbounded children stay so
    comiss  xmm0, [rip+sf_limit]
    jae     .Lbb_xunb
    xor     r13d, r13d                  # corner bits
2:  xor     ecx, ecx
3:  mov     eax, r13d
    shr     eax, cl
    and     eax, 1
    imul    eax, eax, 12
    lea     rdx, [rax+rcx*4]
    movss   xmm0, [r12+ND_BB+rdx]
    movss   [rsp+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      3b
    lea     rdi, [rbx+ND_FWD]
    lea     rsi, [rsp]
    lea     rdx, [rsp+16]
    call    xform_point
    xor     ecx, ecx
4:  movss   xmm0, [rsp+16+rcx*4]
    movss   xmm1, [rbx+ND_BB+rcx*4]
    minss   xmm1, xmm0
    movss   [rbx+ND_BB+rcx*4], xmm1
    movss   xmm1, [rbx+ND_BB+12+rcx*4]
    maxss   xmm1, xmm0
    movss   [rbx+ND_BB+12+rcx*4], xmm1
    inc     ecx
    cmp     ecx, 3
    jb      4b
    inc     r13d
    cmp     r13d, 8
    jb      2b
    jmp     .Lbb_out
.Lbb_xunb:
    movss   xmm0, [rip+sf_inf]
    movss   xmm1, xmm0
    movss   xmm2, xmm0
    call    symbb
.Lbb_out:
    add     rsp, 56
    pop     r13
    pop     r12
    ret

# =============================================================================
#  Evaluation
# =============================================================================
# sdf_eval(edi=id, xmm0..2 = point) -> xmm0 = signed distance
sdf_eval:
    lea     rcx, [rip+sdf_nodes]
    NODE    r8, r8d, edi
    mov     eax, [r8+ND_TYPE]
    cmp     eax, S_SPHERE
    je      .Lev_sphere
    cmp     eax, S_BOX
    je      .Lev_box
    cmp     eax, S_CYL
    je      .Lev_cyl
    cmp     eax, S_TORUS
    je      .Lev_torus
    cmp     eax, S_GYROID
    je      .Lev_gyroid
    cmp     eax, S_GRID
    je      .Lev_grid
    cmp     eax, S_XFORM
    je      .Lev_xform
    cmp     eax, S_SHELL
    je      .Lev_shell
    cmp     eax, S_PRISM
    je      .Lev_prism
    cmp     eax, S_UNION
    jb      .Lev_none
    cmp     eax, S_ISECT
    jbe     .Lev_bool
.Lev_none:
    movss   xmm0, [rip+sf_big]
    ret
.Lev_sphere:
    mulss   xmm0, xmm0
    mulss   xmm1, xmm1
    mulss   xmm2, xmm2
    addss   xmm0, xmm1
    addss   xmm0, xmm2
    sqrtss  xmm0, xmm0
    subss   xmm0, [r8+ND_P]
    ret
.Lev_box:                               # q = |p| - h + rr: |max(q, 0)| +
    movss   xmm7, [r8+ND_P+12]          #  min(max q, 0) - rr
    andps   xmm0, [rip+sf_abs]
    andps   xmm1, [rip+sf_abs]
    andps   xmm2, [rip+sf_abs]
    subss   xmm0, [r8+ND_P]
    subss   xmm1, [r8+ND_P+4]
    subss   xmm2, [r8+ND_P+8]
    addss   xmm0, xmm7
    addss   xmm1, xmm7
    addss   xmm2, xmm7
    movss   xmm3, xmm0                  # inner: min(max(qx, qy, qz), 0)
    maxss   xmm3, xmm1
    maxss   xmm3, xmm2
    minss   xmm3, [rip+sf_zero]
    xorps   xmm6, xmm6
    maxss   xmm0, xmm6
    maxss   xmm1, xmm6
    maxss   xmm2, xmm6
    mulss   xmm0, xmm0
    mulss   xmm1, xmm1
    mulss   xmm2, xmm2
    addss   xmm0, xmm1
    addss   xmm0, xmm2
    sqrtss  xmm0, xmm0
    addss   xmm0, xmm3
    subss   xmm0, xmm7
    ret
.Lev_cyl:                               # d = (|xz| - r, |y| - h/2)
    mulss   xmm0, xmm0
    mulss   xmm2, xmm2
    addss   xmm0, xmm2
    sqrtss  xmm0, xmm0
    subss   xmm0, [r8+ND_P]
    andps   xmm1, [rip+sf_abs]
    movss   xmm3, [r8+ND_P+4]
    mulss   xmm3, [rip+sf_half]
    subss   xmm1, xmm3
.Lev_2d:                                # min(max(d), 0) + |max(d, 0)|
    movss   xmm3, xmm0
    maxss   xmm3, xmm1
    minss   xmm3, [rip+sf_zero]
    xorps   xmm6, xmm6
    maxss   xmm0, xmm6
    maxss   xmm1, xmm6
    mulss   xmm0, xmm0
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    sqrtss  xmm0, xmm0
    addss   xmm0, xmm3
    ret
.Lev_torus:                             # |(|xz| - R, y)| - r
    mulss   xmm0, xmm0
    mulss   xmm2, xmm2
    addss   xmm0, xmm2
    sqrtss  xmm0, xmm0
    subss   xmm0, [r8+ND_P]
    mulss   xmm0, xmm0
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    sqrtss  xmm0, xmm0
    subss   xmm0, [r8+ND_P+4]
    ret
.Lev_gyroid:                            # s = 2pi / cell:
    sub     rsp, 40                     #  |sin sx cos sy + sin sy cos sz +
    movss   xmm3, [rip+sf_2pi]          #   sin sz cos sx| 0.6 / s - t / 2
    divss   xmm3, [r8+ND_P]
    movss   [rsp+32], xmm3
    mulss   xmm0, xmm3
    mulss   xmm1, xmm3
    mulss   xmm2, xmm3
    movss   [rsp], xmm0
    movss   [rsp+8], xmm1
    movss   [rsp+16], xmm2
    fld     dword ptr [rsp]
    fsincos
    fstp    dword ptr [rsp+4]           # cos x
    fstp    dword ptr [rsp]             # sin x
    fld     dword ptr [rsp+8]
    fsincos
    fstp    dword ptr [rsp+12]
    fstp    dword ptr [rsp+8]
    fld     dword ptr [rsp+16]
    fsincos
    fstp    dword ptr [rsp+20]
    fstp    dword ptr [rsp+16]
    movss   xmm0, [rsp]                 # sx cy
    mulss   xmm0, [rsp+12]
    movss   xmm1, [rsp+8]               # sy cz
    mulss   xmm1, [rsp+20]
    addss   xmm0, xmm1
    movss   xmm1, [rsp+16]              # sz cx
    mulss   xmm1, [rsp+4]
    addss   xmm0, xmm1
    andps   xmm0, [rip+sf_abs]
    mulss   xmm0, [rip+sf_gyro]
    divss   xmm0, [rsp+32]
    movss   xmm1, [r8+ND_P+4]
    mulss   xmm1, [rip+sf_half]
    subss   xmm0, xmm1
    add     rsp, 40
    ret
.Lev_grid:                              # struts along x, y, z on a cubic
    movss   xmm3, [r8+ND_P]             #  grid: u = p - cell floor(p / cell
    movss   xmm4, xmm3                  #  + 1/2) (the nearest node), then
    mulss   xmm4, [rip+sf_half]         #  min over axes of |u_other| - r
    xor     ecx, ecx
    sub     rsp, 24
    movss   [rsp], xmm0
    movss   [rsp+4], xmm1
    movss   [rsp+8], xmm2
1:  movss   xmm5, [rsp+rcx*4]
    movss   xmm6, xmm5
    divss   xmm6, xmm3
    addss   xmm6, [rip+sf_half]
    roundss xmm6, xmm6, 9               # floor
    mulss   xmm6, xmm3
    subss   xmm5, xmm6
    mulss   xmm5, xmm5
    movss   [rsp+12+rcx*4], xmm5        # u^2
    inc     ecx
    cmp     ecx, 3
    jb      1b
    movss   xmm0, [rsp+16]              # along x: uy^2 + uz^2
    addss   xmm0, [rsp+20]
    movss   xmm1, [rsp+12]              # along y: ux^2 + uz^2
    addss   xmm1, [rsp+20]
    minss   xmm0, xmm1
    movss   xmm1, [rsp+12]              # along z
    addss   xmm1, [rsp+16]
    minss   xmm0, xmm1
    sqrtss  xmm0, xmm0
    subss   xmm0, [r8+ND_P+4]
    add     rsp, 24
    ret
.Lev_xform:                             # the child at M p
    sub     rsp, 40
    movss   [rsp], xmm0
    movss   [rsp+4], xmm1
    movss   [rsp+8], xmm2
    mov     [rsp+32], r8
    lea     rdi, [r8+ND_M]
    lea     rsi, [rsp]
    lea     rdx, [rsp+16]
    call    xform_point
    mov     r8, [rsp+32]
    mov     edi, [r8+ND_A]
    movss   xmm0, [rsp+16]
    movss   xmm1, [rsp+20]
    movss   xmm2, [rsp+24]
    add     rsp, 40
    jmp     sdf_eval
.Lev_prism:                             # (sketch-local p) plane coords, then
    sub     rsp, 40                     #  (2D distance, |w| beyond w0 .. w1)
    mov     eax, [r8+ND_P]              # plane: 0 XY, 1 XZ, 2 YZ
    cmp     eax, 1
    je      1f
    ja      2f
    movss   xmm3, xmm0                  # u = x, v = y, w = z
    movss   xmm4, xmm1
    movss   xmm5, xmm2
    jmp     3f
1:  movss   xmm3, xmm0                  # u = x, v = -z, w = y
    xorps   xmm4, xmm4
    subss   xmm4, xmm2
    movss   xmm5, xmm1
    jmp     3f
2:  xorps   xmm3, xmm3                  # u = -z, v = y, w = x
    subss   xmm3, xmm2
    movss   xmm4, xmm1
    movss   xmm5, xmm0
3:  subss   xmm5, [r8+ND_P+4]           # - offset
    movss   [rsp], xmm3
    movss   [rsp+4], xmm4
    movss   [rsp+8], xmm5
    mov     rsi, [r8+ND_FWD]            # segments (u0 v0 u1 v1)
    mov     ecx, [r8+ND_B]
    movss   xmm6, [rip+sf_big]          # min distance^2
    xor     edx, edx                    # crossings
4:  test    ecx, ecx
    jz      6f
    movss   xmm0, [rsi+8]               # e = b - a, w = p - a
    subss   xmm0, [rsi]
    movss   xmm1, [rsi+12]
    subss   xmm1, [rsi+4]
    movss   xmm2, xmm3
    subss   xmm2, [rsi]
    movss   xmm7, xmm4
    subss   xmm7, [rsi+4]
    movss   [rsp+12], xmm2
    movss   [rsp+16], xmm7
    mulss   xmm2, xmm0                  # t = clamp(w . e / e . e)
    mulss   xmm7, xmm1
    addss   xmm2, xmm7
    movss   xmm7, xmm0
    mulss   xmm7, xmm0
    movss   [rsp+20], xmm1
    mulss   xmm1, xmm1
    addss   xmm7, xmm1
    maxss   xmm7, [rip+sf_tiny]
    divss   xmm2, xmm7
    maxss   xmm2, [rip+sf_zero]
    minss   xmm2, [rip+sf_one]
    movss   xmm1, [rsp+20]
    movss   xmm7, xmm0                  # w - e t
    mulss   xmm7, xmm2
    movss   [rsp+24], xmm7
    movss   xmm7, [rsp+12]
    subss   xmm7, [rsp+24]
    mulss   xmm7, xmm7
    mulss   xmm1, xmm2
    movss   xmm2, [rsp+16]
    subss   xmm2, xmm1
    mulss   xmm2, xmm2
    addss   xmm7, xmm2
    minss   xmm6, xmm7
    movss   xmm0, [rsi+4]               # crossing of +u from p: (va > v) !=
    xor     eax, eax                    #  (vb > v) and to the right
    comiss  xmm0, xmm4
    seta    al
    xor     r9d, r9d
    movss   xmm1, [rsi+12]
    comiss  xmm1, xmm4
    seta    r9b
    cmp     eax, r9d
    je      5f
    movss   xmm2, xmm4                  # u at v: ua + (v - va)(ub - ua)/(vb - va)
    subss   xmm2, xmm0
    movss   xmm7, [rsi+8]
    subss   xmm7, [rsi]
    mulss   xmm2, xmm7
    subss   xmm1, xmm0
    divss   xmm2, xmm1
    addss   xmm2, [rsi]
    comiss  xmm2, xmm3
    jbe     5f
    xor     edx, 1
5:  add     rsi, 16
    dec     ecx
    jmp     4b
6:  sqrtss  xmm0, xmm6                  # inside: negative
    test    edx, edx
    jz      7f
    xorps   xmm1, xmm1
    subss   xmm1, xmm0
    movss   xmm0, xmm1
7:  movss   xmm1, [r8+ND_P+8]           # w0 - w, w - w1
    subss   xmm1, [rsp+8]
    movss   xmm2, [rsp+8]
    subss   xmm2, [r8+ND_P+12]
    maxss   xmm1, xmm2
    add     rsp, 40
    jmp     .Lev_2d
.Lev_shell:                             # |d| - t / 2
    sub     rsp, 24
    mov     [rsp], r8
    mov     edi, [r8+ND_A]
    call    sdf_eval
    mov     r8, [rsp]
    andps   xmm0, [rip+sf_abs]
    movss   xmm1, [r8+ND_P]
    mulss   xmm1, [rip+sf_half]
    subss   xmm0, xmm1
    add     rsp, 24
    ret
.Lev_bool:
    sub     rsp, 40
    mov     [rsp], r8
    movss   [rsp+8], xmm0
    movss   [rsp+12], xmm1
    movss   [rsp+16], xmm2
    mov     edi, [r8+ND_A]
    call    sdf_eval
    movss   [rsp+20], xmm0              # a
    mov     r8, [rsp]
    mov     edi, [r8+ND_B]
    movss   xmm0, [rsp+8]
    movss   xmm1, [rsp+12]
    movss   xmm2, [rsp+16]
    call    sdf_eval                    # b
    mov     r8, [rsp]
    movss   xmm1, xmm0
    movss   xmm0, [rsp+20]
    movss   xmm2, [r8+ND_P]             # k
    mov     eax, [r8+ND_TYPE]
    cmp     eax, S_UNION
    je      1f
    xorps   xmm3, xmm3                  # subtract: smax(a, -b); intersect:
    cmp     eax, S_SUB                  #  smax(a, b) = -smin(-a, -b)
    jne     2f
    xorps   xmm4, xmm4
    subss   xmm4, xmm1
    movss   xmm1, xmm4
2:  xorps   xmm4, xmm4
    subss   xmm4, xmm0
    movss   xmm0, xmm4
    xorps   xmm4, xmm4
    subss   xmm4, xmm1
    movss   xmm1, xmm4
    call    smin
    xorps   xmm4, xmm4
    subss   xmm4, xmm0
    movss   xmm0, xmm4
    add     rsp, 40
    ret
1:  call    smin
    add     rsp, 40
    ret

# smin(xmm0=a, xmm1=b, xmm2=k) -> xmm0: min(a, b) - h^2 k / 4,
#   h = max(k - |a - b|, 0) / k (the plain min when k <= 0)
smin:
    xorps   xmm3, xmm3
    comiss  xmm2, xmm3
    ja      1f
    minss   xmm0, xmm1
    ret
1:  movss   xmm3, xmm0
    subss   xmm3, xmm1
    andps   xmm3, [rip+sf_abs]
    movss   xmm4, xmm2
    subss   xmm4, xmm3
    maxss   xmm4, [rip+sf_zero]
    divss   xmm4, xmm2
    mulss   xmm4, xmm4
    mulss   xmm4, xmm2
    mulss   xmm4, [rip+sf_quarter]
    minss   xmm0, xmm1
    subss   xmm0, xmm4
    ret

# =============================================================================
#  Meshing
# =============================================================================
# sdf_mesh(edi=id, esi=cells along the largest side) -> rax = a closed mesh
#   (world coordinates), or 0 with sdf_err set
sdf_mesh:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 72
    mov     [rip+sm_root], edi
    mov     r12d, esi
    cmp     r12d, 4
    jge     1f
    mov     r12d, 4
1:  lea     rcx, [rip+sdf_nodes]
    NODE    rbx, ebx, edi
    xor     ecx, ecx                    # bounded, not empty
    movss   xmm7, [rip+sf_zero]         # largest side
2:  movss   xmm0, [rbx+ND_BB+rcx*4]
    movss   xmm1, [rbx+ND_BB+12+rcx*4]
    movss   xmm2, xmm0
    andps   xmm2, [rip+sf_abs]
    comiss  xmm2, [rip+sf_limit]
    jae     .Lsm_unb
    movss   xmm2, xmm1
    andps   xmm2, [rip+sf_abs]
    comiss  xmm2, [rip+sf_limit]
    jae     .Lsm_unb
    subss   xmm1, xmm0
    comiss  xmm1, [rip+sf_zero]
    jbe     .Lsm_empty
    maxss   xmm7, xmm1
    inc     ecx
    cmp     ecx, 3
    jb      2b
    cvtsi2ss xmm0, r12d                 # h = side / cells
    divss   xmm7, xmm0
    movss   [rip+sm_h], xmm7
    xor     ecx, ecx                    # origin = min - 2h; n = side / h + 5
    lea     rdx, [rip+sm_nx]
3:  movss   xmm0, [rbx+ND_BB+rcx*4]
    movss   xmm1, xmm7
    addss   xmm1, xmm1
    subss   xmm0, xmm1
    lea     rax, [rip+sm_org]
    movss   [rax+rcx*4], xmm0
    movss   xmm0, [rbx+ND_BB+12+rcx*4]
    subss   xmm0, [rbx+ND_BB+rcx*4]
    divss   xmm0, xmm7
    cvttss2si eax, xmm0
    add     eax, 5
    mov     [rdx+rcx*4], eax
    inc     ecx
    cmp     ecx, 3
    jb      3b
    mov     ecx, [rip+sm_nz]            # not too many points
    mov     edx, [rip+sm_ny]
    mov     eax, [rip+sm_nx]
    imul    rax, rdx
    imul    rax, rcx
    cmp     rax, MAXPTS
    ja      .Lsm_large
    lea     rdi, [rax*4+4095]           # the field
    and     rdi, -4096
    mov     [rip+sm_fbytes], rdi
    call    map
    test    rax, rax
    jz      .Lsm_nomem
    mov     [rip+sm_f], rax
    lea     rdi, [rip+eval_slices]      # sample it, a z slice per chunk
    xor     esi, esi
    mov     edx, [rip+sm_nz]
    mov     ecx, 1
    call    parallel_for
.Lsm_edges:
    # edge -> vertex ids: 7 edges (x, y, z and the diagonals) per point
    mov     eax, [rip+sm_nx]
    mov     ecx, [rip+sm_ny]
    imul    rax, rcx
    mov     ecx, [rip+sm_nz]
    imul    rax, rcx
    imul    rax, rax, 28
    lea     rdi, [rax+4095]
    and     rdi, -4096
    mov     [rip+sm_cbytes], rdi
    call    map
    test    rax, rax
    jz      .Lsm_nomem2
    mov     [rip+sm_cell], rax
    mov     qword ptr [rip+sm_mesh], 0
    call    mt_verts                    # count (and number) the crossings
    call    mt_tris                     # count the triangles
    cmp     dword ptr [rip+sm_nq], 0
    je      .Lsm_empty2
    mov     edi, [rip+sm_nv]
    add     edi, 8
    mov     esi, [rip+sm_nq]
    lea     esi, [rsi+rsi*2+8]
    mov     edx, [rip+sm_nq]
    add     edx, 8
    call    mesh_new
    test    rax, rax
    jz      .Lsm_nomem3
    mov     [rip+sm_mesh], rax
    call    mt_verts
    call    mt_tris
    mov     rdi, [rip+sm_mesh]
    call    mesh_finish
    call    unmap_all
    mov     rax, [rip+sm_mesh]
    jmp     .Lsm_out
.Lsm_unb:
    lea     rax, [rip+e_unbounded]
    jmp     .Lsm_err
.Lsm_empty2:
    call    unmap_all
.Lsm_empty:
    lea     rax, [rip+e_empty]
    jmp     .Lsm_err
.Lsm_large:
    lea     rax, [rip+e_large]
    jmp     .Lsm_err
.Lsm_nomem3:
.Lsm_nomem2:
    call    unmap_all
.Lsm_nomem:
    lea     rax, [rip+e_nomem]
.Lsm_err:
    mov     [rip+sdf_err], rax
    xor     eax, eax
.Lsm_out:
    add     rsp, 72
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# sdf_fmesh(rdi=its origin x y z and spacing (4 floats), rsi=a field
#   (floats, (k ny + j) nx + i; negative inside, positive at the border),
#   edx=nx, ecx=ny, r8d=nz) -> rax = its surface: a closed mesh (the field
#   is the caller's), or 0
sdf_fmesh:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 72
    mov     eax, [rdi]
    mov     [rip+sm_org], eax
    mov     eax, [rdi+4]
    mov     [rip+sm_org+4], eax
    mov     eax, [rdi+8]
    mov     [rip+sm_org+8], eax
    mov     eax, [rdi+12]
    mov     [rip+sm_h], eax
    mov     [rip+sm_f], rsi
    mov     qword ptr [rip+sm_fbytes], 0    # (not ours: not unmapped)
    mov     [rip+sm_nx], edx
    mov     [rip+sm_ny], ecx
    mov     [rip+sm_nz], r8d
    jmp     .Lsm_edges

# map(rdi=bytes) -> rax = zeroed memory or 0
map:
    mov     rsi, rdi
    xor     edi, edi
    mov     edx, PROT_RW
    mov     r10d, MAP_ANON_PRIV
    mov     r8, -1
    xor     r9d, r9d
    mov     eax, SYS_MMAP
    syscall
    cmp     rax, -4096
    jb      1f
    xor     eax, eax
1:  ret

unmap_all:
    mov     rdi, [rip+sm_f]
    test    rdi, rdi
    jz      1f
    mov     rsi, [rip+sm_fbytes]
    mov     qword ptr [rip+sm_f], 0
    test    rsi, rsi
    jz      1f
    mov     eax, SYS_MUNMAP
    syscall
1:  mov     rdi, [rip+sm_cell]
    test    rdi, rdi
    jz      2f
    mov     rsi, [rip+sm_cbytes]
    mov     eax, SYS_MUNMAP
    syscall
    mov     qword ptr [rip+sm_cell], 0
2:  ret

# eval_slices(rdi=ctx, esi=begin, edx=end) - the field on z slices
eval_slices:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    mov     r12d, esi
    mov     r13d, edx
1:  cmp     r12d, r13d
    jae     9f
    xor     r14d, r14d                  # j
2:  cmp     r14d, [rip+sm_ny]
    jae     8f
    xor     r15d, r15d                  # i
3:  cmp     r15d, [rip+sm_nx]
    jae     7f
    cvtsi2ss xmm0, r15d
    cvtsi2ss xmm1, r14d
    cvtsi2ss xmm2, r12d
    movss   xmm3, [rip+sm_h]
    mulss   xmm0, xmm3
    mulss   xmm1, xmm3
    mulss   xmm2, xmm3
    addss   xmm0, [rip+sm_org]
    addss   xmm1, [rip+sm_org+4]
    addss   xmm2, [rip+sm_org+8]
    mov     edi, [rip+sm_root]
    call    sdf_eval
    mov     eax, r12d                   # (k ny + j) nx + i
    imul    eax, [rip+sm_ny]
    add     eax, r14d
    imul    eax, [rip+sm_nx]
    add     eax, r15d
    mov     rcx, [rip+sm_f]
    movss   [rcx+rax*4], xmm0
    inc     r15d
    jmp     3b
7:  inc     r14d
    jmp     2b
8:  inc     r12d
    jmp     1b
9:  add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# fval(ecx=i, edx=j, r8d=k) -> xmm0 (eax = index)
fval:
    mov     eax, r8d
    imul    eax, [rip+sm_ny]
    add     eax, edx
    imul    eax, [rip+sm_nx]
    add     eax, ecx
    mov     r9, [rip+sm_f]
    movss   xmm0, [r9+rax*4]
    ret

# corners(ecx, edx, r8d = cell) -> eax = inside mask (bit c: corner c < 0)
corners:
    push    rbx
    push    r12
    push    r13
    push    r14
    mov     r12d, ecx
    mov     r13d, edx
    mov     r14d, r8d
    xor     ebx, ebx
    xor     r10d, r10d
1:  mov     ecx, r10d
    and     ecx, 1
    add     ecx, r12d
    mov     edx, r10d
    shr     edx, 1
    and     edx, 1
    add     edx, r13d
    mov     r8d, r10d
    shr     r8d, 2
    add     r8d, r14d
    call    fval
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    jae     2f
    bts     ebx, r10d
2:  inc     r10d
    cmp     r10d, 8
    jb      1b
    mov     eax, ebx
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# pidx(ecx=i, edx=j, r8d=k) -> eax = point index
pidx:
    mov     eax, r8d
    imul    eax, [rip+sm_ny]
    add     eax, edx
    imul    eax, [rip+sm_nx]
    add     eax, ecx
    ret

# mt_verts - a vertex on every edge (point -> point + d, d = 1..7 as x y z
#   bits) whose ends differ in sign; ev[point * 7 + d - 1] = its id or -1.
#   Adds the vertices when sm_mesh is set, else only numbers them.
mt_verts:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 40
    xor     ebp, ebp                    # vertices
    xor     r15d, r15d                  # k
1:  cmp     r15d, [rip+sm_nz]
    jae     9f
    xor     r14d, r14d
2:  cmp     r14d, [rip+sm_ny]
    jae     8f
    xor     r13d, r13d
3:  cmp     r13d, [rip+sm_nx]
    jae     7f
    mov     ecx, r13d
    mov     edx, r14d
    mov     r8d, r15d
    call    fval
    movss   [rsp], xmm0                 # f0
    mov     [rsp+4], eax                # point
    mov     r12d, 1                     # d
4:  mov     ecx, r12d                   # the other end inside the grid?
    and     ecx, 1
    add     ecx, r13d
    cmp     ecx, [rip+sm_nx]
    jae     6f
    mov     edx, r12d
    shr     edx, 1
    and     edx, 1
    add     edx, r14d
    cmp     edx, [rip+sm_ny]
    jae     6f
    mov     r8d, r12d
    shr     r8d, 2
    add     r8d, r15d
    cmp     r8d, [rip+sm_nz]
    jae     6f
    call    fval
    movss   xmm1, [rsp]
    xorps   xmm2, xmm2
    xor     eax, eax
    comiss  xmm0, xmm2
    setb    al
    xor     ecx, ecx
    comiss  xmm1, xmm2
    setb    cl
    cmp     eax, ecx
    je      6f
    mov     ebx, ebp                    # a vertex
    inc     ebp
    cmp     qword ptr [rip+sm_mesh], 0
    je      5f
    subss   xmm1, xmm0                  # t = f0 / (f0 - f1), kept off the
    movss   xmm3, [rsp]                 #  ends (no two vertices meet)
    divss   xmm3, xmm1
    maxss   xmm3, [rip+sf_tlo]
    minss   xmm3, [rip+sf_thi]
    xor     ecx, ecx                    # world: org + h (p + t d)
    mov     [rsp+16], r13d
    mov     [rsp+20], r14d
    mov     [rsp+24], r15d
41: cvtsi2ss xmm0, dword ptr [rsp+16+rcx*4]
    bt      r12d, ecx
    jnc     42f
    addss   xmm0, xmm3
42: mulss   xmm0, [rip+sm_h]
    lea     rax, [rip+sm_org]
    addss   xmm0, [rax+rcx*4]
    movss   [rsp+28+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      41b
    mov     rdi, [rip+sm_mesh]
    movss   xmm0, [rsp+28]
    movss   xmm1, [rsp+32]
    movss   xmm2, [rsp+36]
    call    mesh_add_vert
5:  mov     eax, [rsp+4]
    imul    eax, eax, 7
    add     eax, r12d
    mov     rcx, [rip+sm_cell]
    mov     [rcx+rax*4-4], ebx
    jmp     61f
6:  mov     eax, [rsp+4]
    imul    eax, eax, 7
    add     eax, r12d
    mov     rcx, [rip+sm_cell]
    mov     dword ptr [rcx+rax*4-4], -1
61: inc     r12d
    cmp     r12d, 8
    jb      4b
    inc     r13d
    jmp     3b
7:  inc     r14d
    jmp     2b
8:  inc     r15d
    jmp     1b
9:  mov     [rip+sm_nv], ebp
    add     rsp, 40
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# mt_tris - the six tetrahedra (0, a, b, 7) of every cell: counted into
#   sm_nq, or (sm_mesh set) emitted facing out
mt_tris:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 104
    xor     ebp, ebp                    # triangles
    xor     r15d, r15d
1:  mov     eax, [rip+sm_nz]
    dec     eax
    cmp     r15d, eax
    jae     9f
    xor     r14d, r14d
2:  mov     eax, [rip+sm_ny]
    dec     eax
    cmp     r14d, eax
    jae     8f
    xor     r13d, r13d
3:  mov     eax, [rip+sm_nx]
    dec     eax
    cmp     r13d, eax
    jae     7f
    mov     ecx, r13d                   # the cube's 8 values and its mask
    mov     edx, r14d
    mov     r8d, r15d
    call    corners
    test    eax, eax
    jz      6f
    cmp     eax, 255
    je      6f
    mov     [rsp+96], eax               # mask
    mov     [rip+tev_frame], rsp
    mov     [rip+tc_i], r13d
    mov     [rip+tc_j], r14d
    mov     [rip+tc_k], r15d
    xor     r12d, r12d                  # tetrahedron
4:  lea     rax, [rip+tets]
    movzx   ecx, byte ptr [rax+r12*2]
    movzx   edx, byte ptr [rax+r12*2+1]
    mov     byte ptr [rsp+64], 0        # corners: 0, a, b, 7
    mov     [rsp+65], cl
    mov     [rsp+66], dl
    mov     byte ptr [rsp+67], 7
    xor     ebx, ebx                    # inside bits of the four
    xor     r8d, r8d
41: movzx   ecx, byte ptr [rsp+64+r8]
    mov     eax, [rsp+96]
    bt      eax, ecx
    jnc     42f
    bts     ebx, r8d
42: inc     r8d
    cmp     r8d, 4
    jb      41b
    test    ebx, ebx
    jz      5f
    cmp     ebx, 15
    je      5f
    popcnt  eax, ebx
    cmp     eax, 2
    je      43f
    inc     ebp                         # one triangle
    cmp     qword ptr [rip+sm_mesh], 0
    je      5f
    mov     edi, ebx
    call    tet_one
    jmp     5f
43: add     ebp, 2                      # two
    cmp     qword ptr [rip+sm_mesh], 0
    je      5f
    mov     edi, ebx
    call    tet_two
5:  inc     r12d
    cmp     r12d, 6
    jb      4b
6:  inc     r13d
    jmp     3b
7:  inc     r14d
    jmp     2b
8:  inc     r15d
    jmp     1b
9:  mov     [rip+sm_nq], ebp
    add     rsp, 104
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# tsign -> eax = the tetrahedron's orientation, +1 / -1: det(a, b, 7) of
#   its corner positions (bits) relative to corner 0
tsign:
    mov     rcx, [rip+tev_frame]
    movzx   eax, byte ptr [rcx+65]      # a
    movzx   edx, byte ptr [rcx+66]      # b
    sub     rsp, 40
    xor     r8d, r8d
1:  bt      eax, r8d
    setc    r9b
    movzx   r9d, r9b
    mov     [rsp+r8*4], r9d             # a
    bt      edx, r8d
    setc    r9b
    movzx   r9d, r9b
    mov     [rsp+12+r8*4], r9d          # b
    inc     r8d
    cmp     r8d, 3
    jb      1b
    mov     eax, [rsp+16]               # det(a, b, (1,1,1)) = a . (b x 1)
    sub     eax, [rsp+20]               # b x 1 = (by - bz, bz - bx, bx - by)
    imul    eax, [rsp]
    mov     ecx, [rsp+20]
    sub     ecx, [rsp+12]
    imul    ecx, [rsp+4]
    add     eax, ecx
    mov     ecx, [rsp+12]
    sub     ecx, [rsp+16]
    imul    ecx, [rsp+8]
    add     eax, ecx
    add     rsp, 40
    test    eax, eax
    mov     eax, 1
    jg      2f
    mov     eax, -1
2:  ret

# tet_one(edi=inside bits, one or three set) - the triangle around the lone
#   corner: for a positive tetrahedron, (1 2 3) around 0, (0 3 2) around 1,
#   (3 0 1) around 2, (2 1 0) around 3 face away from it
tet_one:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 32
    mov     ebx, edi
    popcnt  eax, ebx
    mov     ecx, ebx
    xor     r13d, r13d                  # flip: the lone corner is outside,
    cmp     eax, 1                      #  or the tetrahedron is negative
    je      1f
    not     ecx
    and     ecx, 15
    xor     r13d, 1
1:  bsf     r12d, ecx
    call    tsign
    test    eax, eax
    jns     2f
    xor     r13d, 1
2:  lea     rax, [rip+lone_tri]
    movzx   esi, byte ptr [rax+r12*4]
    mov     edi, r12d
    call    tev_up
    mov     [rsp], eax
    lea     rax, [rip+lone_tri]
    movzx   esi, byte ptr [rax+r12*4+1]
    mov     edi, r12d
    call    tev_up
    mov     [rsp+4], eax
    lea     rax, [rip+lone_tri]
    movzx   esi, byte ptr [rax+r12*4+2]
    mov     edi, r12d
    call    tev_up
    mov     [rsp+8], eax
    mov     edi, r13d
    lea     rsi, [rsp]
    call    tri_out
    add     rsp, 32
    pop     r13
    pop     r12
    pop     rbx
    ret

# tet_two(edi=inside bits, two set) - the quad between i1 i2 (inside) and
#   o1 o2: (i1o1, i1o2, i2o2, i2o1) faces out when (i1 i2 o1 o2) is positive
tet_two:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 40
    mov     ebx, edi
    bsf     r12d, ebx                   # i1 < i2, o1 < o2
    mov     eax, ebx
    btr     eax, r12d
    bsf     r13d, eax
    mov     eax, ebx
    not     eax
    and     eax, 15
    bsf     r14d, eax
    btr     eax, r14d
    bsf     r15d, eax
    xor     ebp, ebp                    # parity of (i1 i2 o1 o2): inversions
    mov     [rsp+16], r12d
    mov     [rsp+20], r13d
    mov     [rsp+24], r14d
    mov     [rsp+28], r15d
    xor     ecx, ecx
1:  lea     edx, [rcx+1]
2:  cmp     edx, 4
    jae     3f
    mov     eax, [rsp+16+rcx*4]
    cmp     eax, [rsp+16+rdx*4]
    jbe     21f
    xor     ebp, 1
21: inc     edx
    jmp     2b
3:  inc     ecx
    cmp     ecx, 3
    jb      1b
    call    tsign
    test    eax, eax
    jns     4f
    xor     ebp, 1
4:  mov     edi, r12d                   # (i1 o1) (i1 o2) (i2 o2) (i2 o1)
    mov     esi, r14d
    call    tev_up
    mov     [rsp], eax
    mov     edi, r12d
    mov     esi, r15d
    call    tev_up
    mov     [rsp+4], eax
    mov     edi, r13d
    mov     esi, r15d
    call    tev_up
    mov     [rsp+8], eax
    mov     edi, r13d
    mov     esi, r14d
    call    tev_up
    mov     [rsp+12], eax
    mov     edi, ebp                    # (0 1 2), (0 2 3)
    lea     rsi, [rsp]
    call    tri_out
    mov     eax, [rsp+8]
    mov     [rsp+4], eax
    mov     eax, [rsp+12]
    mov     [rsp+8], eax
    mov     edi, ebp
    lea     rsi, [rsp]
    call    tri_out
    add     rsp, 40
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# tev_up(edi=u, esi=v: tetrahedron corners 0..3) -> eax = the vertex on that
#   edge (tev_frame: the corner codes at +64; tc_i/j/k: the cell)
tev_up:
    mov     rcx, [rip+tev_frame]
    movzx   eax, byte ptr [rcx+64+rdi]
    movzx   edx, byte ptr [rcx+64+rsi]
    cmp     eax, edx                    # lo = the subset corner
    jbe     1f
    xchg    eax, edx
1:  xor     edx, eax                    # direction bits
    push    rdx
    mov     ecx, eax
    and     ecx, 1
    add     ecx, [rip+tc_i]
    mov     edx, eax
    shr     edx, 1
    and     edx, 1
    add     edx, [rip+tc_j]
    mov     r8d, eax
    shr     r8d, 2
    add     r8d, [rip+tc_k]
    call    pidx
    pop     rdx
    imul    eax, eax, 7
    add     eax, edx
    mov     rcx, [rip+sm_cell]
    mov     eax, [rcx+rax*4-4]
    ret

# tri_out(edi=1 to reverse, rsi=u32[3]) - one triangle
tri_out:
    sub     rsp, 24
    mov     eax, [rsi]
    mov     [rsp], eax
    mov     eax, [rsi+4]
    mov     ecx, [rsi+8]
    test    edi, edi
    jz      1f
    xchg    eax, ecx
1:  mov     [rsp+4], eax
    mov     [rsp+8], ecx
    mov     rdi, [rip+sm_mesh]
    lea     rsi, [rsp]
    mov     edx, 3
    call    mesh_add_poly
    add     rsp, 24
    ret

# =============================================================================
#  Profiles as shapes, transforms, meshes together
# =============================================================================
# sdf_prism(edi=plane 0 XY 1 XZ 2 YZ, xmm0=offset, xmm1=w0, xmm2=w1 (floats,
#   sketch-local)) -> eax = a node: the current prof.s loops (even-odd)
#   extruded from w0 to w1 along the plane's normal. Its segments live in
#   their own mapping (sdf_prism_free).
sdf_prism:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 48
    mov     r12d, edi
    movss   [rsp], xmm0
    movss   [rsp+4], xmm1
    movss   [rsp+8], xmm2
    mov     edi, [rip+pf_np]            # segments: one per loop point
    shl     edi, 4
    add     edi, 4095
    and     edi, -4096
    mov     [rsp+16], edi
    call    map
    test    rax, rax
    jz      8f
    mov     r13, rax
    xor     r14d, r14d                  # loop
    xor     r15d, r15d                  # segments written
    movss   xmm6, [rip+sf_big]          # u, v bounds
    movss   xmm7, xmm6
    xorps   xmm4, xmm4
    subss   xmm4, xmm6
    movss   xmm5, xmm4
1:  cmp     r14d, [rip+pf_nl]
    jae     3f
    lea     rax, [rip+pf_ls]
    mov     r8d, [rax+r14*4]
    lea     rax, [rip+pf_ln]
    mov     r9d, [rax+r14*4]
    xor     r10d, r10d
2:  cmp     r10d, r9d
    jae     21f
    lea     eax, [r8+r10]               # a
    shl     eax, 4
    lea     rcx, [rip+pf_pt]
    cvtsd2ss xmm0, [rcx+rax]
    cvtsd2ss xmm1, [rcx+rax+8]
    lea     eax, [r10+1]                # b
    xor     edx, edx
    div     r9d
    lea     eax, [r8+rdx]
    shl     eax, 4
    cvtsd2ss xmm2, [rcx+rax]
    cvtsd2ss xmm3, [rcx+rax+8]
    mov     eax, r15d
    shl     eax, 4
    movss   [r13+rax], xmm0
    movss   [r13+rax+4], xmm1
    movss   [r13+rax+8], xmm2
    movss   [r13+rax+12], xmm3
    minss   xmm6, xmm0
    minss   xmm7, xmm1
    maxss   xmm4, xmm0
    maxss   xmm5, xmm1
    inc     r15d
    inc     r10d
    jmp     2b
21: inc     r14d
    jmp     1b
3:  movss   [rsp+20], xmm6
    movss   [rsp+24], xmm7
    movss   [rsp+28], xmm4
    movss   [rsp+32], xmm5
    mov     [rsp+40], r12d              # params: plane, offset, w0, w1
    mov     eax, [rsp]
    mov     [rsp+44], eax
    lea     rcx, [rsp+40]               # (6 floats from here: plane .. w1)
    mov     eax, [rsp+4]
    mov     [rip+pp_par+8], eax
    mov     eax, [rsp+8]
    mov     [rip+pp_par+12], eax
    mov     eax, [rsp+40]
    mov     [rip+pp_par], eax
    mov     eax, [rsp+44]
    mov     [rip+pp_par+4], eax
    mov     edi, S_PRISM
    xor     esi, esi
    mov     edx, r15d                   # ND_B = segment count
    lea     rcx, [rip+pp_par]
    xor     r8d, r8d
    xor     r9d, r9d
    call    sdf_new
    test    eax, eax
    jz      7f
    mov     ebx, eax
    lea     rcx, [rip+sdf_nodes]
    NODE    rdx, edx, ebx
    mov     [rdx+ND_FWD], r13
    mov     eax, [rsp+16]
    mov     [rdx+ND_FWD+8], eax
    # bounds: u, v, w ranges mapped to x y z by the plane
    movss   xmm0, [rsp+4]               # w0 + offset, w1 + offset
    addss   xmm0, [rsp]
    movss   xmm1, [rsp+8]
    addss   xmm1, [rsp]
    cmp     r12d, 1
    je      4f
    ja      5f
    movss   xmm2, [rsp+20]              # XY: x = u, y = v, z = w
    movss   [rdx+ND_BB], xmm2
    movss   xmm2, [rsp+24]
    movss   [rdx+ND_BB+4], xmm2
    movss   [rdx+ND_BB+8], xmm0
    movss   xmm2, [rsp+28]
    movss   [rdx+ND_BB+12], xmm2
    movss   xmm2, [rsp+32]
    movss   [rdx+ND_BB+16], xmm2
    movss   [rdx+ND_BB+20], xmm1
    jmp     6f
4:  movss   xmm2, [rsp+20]              # XZ: x = u, y = w, z = -v
    movss   [rdx+ND_BB], xmm2
    movss   [rdx+ND_BB+4], xmm0
    xorps   xmm2, xmm2
    subss   xmm2, [rsp+32]
    movss   [rdx+ND_BB+8], xmm2
    movss   xmm2, [rsp+28]
    movss   [rdx+ND_BB+12], xmm2
    movss   [rdx+ND_BB+16], xmm1
    xorps   xmm2, xmm2
    subss   xmm2, [rsp+24]
    movss   [rdx+ND_BB+20], xmm2
    jmp     6f
5:  movss   [rdx+ND_BB], xmm0           # YZ: x = w, y = v, z = -u
    movss   xmm2, [rsp+24]
    movss   [rdx+ND_BB+4], xmm2
    xorps   xmm2, xmm2
    subss   xmm2, [rsp+28]
    movss   [rdx+ND_BB+8], xmm2
    movss   [rdx+ND_BB+12], xmm1
    movss   xmm2, [rsp+32]
    movss   [rdx+ND_BB+16], xmm2
    xorps   xmm2, xmm2
    subss   xmm2, [rsp+20]
    movss   [rdx+ND_BB+20], xmm2
6:  mov     eax, ebx
    jmp     9f
7:  mov     rdi, r13
    mov     esi, [rsp+16]
    mov     eax, SYS_MUNMAP
    syscall
8:  xor     eax, eax
9:  add     rsp, 48
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# sdf_prism_free(edi=node) - its segments go
.globl sdf_prism_free
sdf_prism_free:
    lea     rcx, [rip+sdf_nodes]
    NODE    rax, eax, edi
    mov     rdi, [rax+ND_FWD]
    test    rdi, rdi
    jz      1f
    mov     esi, [rax+ND_FWD+8]
    mov     qword ptr [rax+ND_FWD], 0
    mov     eax, SYS_MUNMAP
    syscall
1:  ret

# sdf_invert(rdi=float[12] m, rsi=float[12] out) - the inverse of a 3x4
#   affine matrix (cofactors; a singular one gives the identity)
sdf_invert:
    sub     rsp, 56
    # c[r][c] cofactor transposed: inv[i][j] = cof[j][i] / det
    movss   xmm0, [rdi+20]              # a11 a22 - a12 a21
    mulss   xmm0, [rdi+40]
    movss   xmm1, [rdi+24]
    mulss   xmm1, [rdi+36]
    subss   xmm0, xmm1
    movss   [rsp], xmm0                 # inv00
    movss   xmm0, [rdi+8]               # a02 a21 - a01 a22
    mulss   xmm0, [rdi+36]
    movss   xmm1, [rdi+4]
    mulss   xmm1, [rdi+40]
    subss   xmm0, xmm1
    movss   [rsp+4], xmm0               # inv01
    movss   xmm0, [rdi+4]               # a01 a12 - a02 a11
    mulss   xmm0, [rdi+24]
    movss   xmm1, [rdi+8]
    mulss   xmm1, [rdi+20]
    subss   xmm0, xmm1
    movss   [rsp+8], xmm0               # inv02
    movss   xmm0, [rdi+24]              # a12 a20 - a10 a22
    mulss   xmm0, [rdi+32]
    movss   xmm1, [rdi+16]
    mulss   xmm1, [rdi+40]
    subss   xmm0, xmm1
    movss   [rsp+12], xmm0              # inv10
    movss   xmm0, [rdi]                 # a00 a22 - a02 a20
    mulss   xmm0, [rdi+40]
    movss   xmm1, [rdi+8]
    mulss   xmm1, [rdi+32]
    subss   xmm0, xmm1
    movss   [rsp+16], xmm0              # inv11
    movss   xmm0, [rdi+8]               # a02 a10 - a00 a12
    mulss   xmm0, [rdi+16]
    movss   xmm1, [rdi]
    mulss   xmm1, [rdi+24]
    subss   xmm0, xmm1
    movss   [rsp+20], xmm0              # inv12
    movss   xmm0, [rdi+16]              # a10 a21 - a11 a20
    mulss   xmm0, [rdi+36]
    movss   xmm1, [rdi+20]
    mulss   xmm1, [rdi+32]
    subss   xmm0, xmm1
    movss   [rsp+24], xmm0              # inv20
    movss   xmm0, [rdi+4]               # a01 a20 - a00 a21
    mulss   xmm0, [rdi+32]
    movss   xmm1, [rdi]
    mulss   xmm1, [rdi+36]
    subss   xmm0, xmm1
    movss   [rsp+28], xmm0              # inv21
    movss   xmm0, [rdi]                 # a00 a11 - a01 a10
    mulss   xmm0, [rdi+20]
    movss   xmm1, [rdi+4]
    mulss   xmm1, [rdi+16]
    subss   xmm0, xmm1
    movss   [rsp+32], xmm0              # inv22
    movss   xmm0, [rdi]                 # det = a00 inv00 + a01 inv10 + a02 inv20
    mulss   xmm0, [rsp]
    movss   xmm1, [rdi+4]
    mulss   xmm1, [rsp+12]
    addss   xmm0, xmm1
    movss   xmm1, [rdi+8]
    mulss   xmm1, [rsp+24]
    addss   xmm0, xmm1
    movss   xmm1, xmm0
    andps   xmm1, [rip+sf_abs]
    comiss  xmm1, [rip+sf_tiny]
    ja      1f
    mov     ecx, 12                     # singular: the identity
    xor     eax, eax
2:  mov     dword ptr [rsi+rax*4], 0
    inc     eax
    loop    2b
    mov     eax, 0x3f800000
    mov     [rsi], eax
    mov     [rsi+20], eax
    mov     [rsi+40], eax
    add     rsp, 56
    ret
1:  movss   xmm1, [rip+sf_one]
    divss   xmm1, xmm0
    xor     ecx, ecx                    # rows: inv[r] / det, then -inv t
3:  mov     eax, ecx
    imul    eax, eax, 12
    mov     edx, ecx
    shl     edx, 4
    movss   xmm2, [rsp+rax]
    mulss   xmm2, xmm1
    movss   [rsi+rdx], xmm2
    movss   xmm3, [rsp+rax+4]
    mulss   xmm3, xmm1
    movss   [rsi+rdx+4], xmm3
    movss   xmm4, [rsp+rax+8]
    mulss   xmm4, xmm1
    movss   [rsi+rdx+8], xmm4
    mulss   xmm2, [rdi+12]
    mulss   xmm3, [rdi+28]
    addss   xmm2, xmm3
    mulss   xmm4, [rdi+44]
    addss   xmm2, xmm4
    xorps   xmm3, xmm3
    subss   xmm3, xmm2
    movss   [rsi+rdx+12], xmm3
    inc     ecx
    cmp     ecx, 3
    jb      3b
    add     rsp, 56
    ret

# mesh_append(rdi=a, rsi=b) -> rax = a new finished mesh holding both
mesh_append:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rbx, rdi
    mov     r12, rsi
    mov     edi, [rbx+ME_NVERTS]
    add     edi, [r12+ME_NVERTS]
    add     edi, 8
    mov     esi, [rbx+ME_NLOOPS]
    add     esi, [r12+ME_NLOOPS]
    add     esi, 8
    mov     edx, [rbx+ME_NPOLYS]
    add     edx, [r12+ME_NPOLYS]
    add     edx, 8
    call    mesh_new
    test    rax, rax
    jz      9f
    mov     r13, rax
    mov     rdi, rbx
    xor     esi, esi
    call    app_one
    mov     rdi, r12
    mov     esi, [rbx+ME_NVERTS]
    call    app_one
    mov     rdi, r13
    call    mesh_finish
    mov     rax, r13
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
# app_one(rdi=source, esi=vertex offset; r13 = destination)
app_one:
    push    rbx
    push    r12
    push    r14
    push    r15
    sub     rsp, 8
    mov     rbx, rdi
    mov     r12d, esi
    xor     r14d, r14d
1:  cmp     r14d, [rbx+ME_NVERTS]
    jae     2f
    mov     rax, [rbx+ME_POS]
    lea     rcx, [r14+r14*2]
    movss   xmm0, [rax+rcx*4]
    movss   xmm1, [rax+rcx*4+4]
    movss   xmm2, [rax+rcx*4+8]
    mov     rdi, r13
    call    mesh_add_vert
    inc     r14d
    jmp     1b
2:  xor     r14d, r14d                  # polygons, indices moved
3:  cmp     r14d, [rbx+ME_NPOLYS]
    jae     9f
    mov     rax, [rbx+ME_POFF]
    mov     ecx, [rax+r14*4]
    mov     edx, [rax+r14*4+4]
    sub     edx, ecx
    cmp     edx, 8192
    ja      5f
    mov     r15d, edx
    mov     rax, [rbx+ME_LOOPS]
    xor     r8d, r8d
4:  cmp     r8d, r15d
    jae     41f
    lea     r9d, [rcx+r8]
    mov     r9d, [rax+r9*4]
    add     r9d, r12d
    lea     r10, [rip+app_buf]
    mov     [r10+r8*4], r9d
    inc     r8d
    jmp     4b
41: mov     rdi, r13
    lea     rsi, [rip+app_buf]
    mov     edx, r15d
    call    mesh_add_poly
5:  inc     r14d
    jmp     3b
9:  add     rsp, 8
    pop     r15
    pop     r14
    pop     r12
    pop     rbx
    ret

.section .rodata
tets:           .byte 1, 3, 1, 5, 2, 3, 2, 6, 4, 5, 4, 6
lone_tri:       .byte 1, 2, 3, 0,  0, 3, 2, 0,  3, 0, 1, 0,  2, 1, 0, 0
.section .bss
cr_v:           .skip 32
.align 8
tev_frame:      .skip 8
tc_i:           .skip 4
tc_j:           .skip 4
tc_k:           .skip 4
pp_par:         .skip 24
app_buf:        .skip 4*8200

.section .note.GNU-stack,"",@progbits
