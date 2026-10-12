# =============================================================================
#  BeeModel - more modifiers: bevel (by angle), decimate (vertex clustering)
#  and remesh (voxels -> surface nets). Each takes a finished mesh and returns
#  a new finished one, or 0 for "unchanged".
# =============================================================================
.intel_syntax noprefix
.include "const.inc"

# exports
.globl mod_bevel
.globl mod_decimate
.globl mod_remesh

.equ MD_P,      8
.equ RM_MAX,    8000000             # remesh: most sample points

.section .bss
.align 8
dc_tab:         .skip 8
dc_h:           .skip 4
dc_inv:         .skip 4
rm_n:           .skip 12            # samples per axis
rm_min:         .skip 12
rm_v:           .skip 4
rm_in:          .skip 8             # inside flags per sample
rm_cnt:         .skip 8             # per x-line: crossing count / offsets
rm_x:           .skip 8             # crossings
rm_cell:        .skip 8             # cell -> vertex (or -1)
rm_lines:       .skip 4
rm_jitter:      .skip 8
rm_mesh:        .skip 8

.section .rodata
.align 4
x_half:         .float 0.5
x_one:          .float 1.0
x_d2r:          .float 0.017453292
x_eps:          .float 1.0e-12
x_tol:          .float 0.03
x_big:          .float 1.0e30
x_jy:           .float 0.000618034
x_jz:           .float 0.000414214
x_twelfth:      .float 1.5

.text

# =============================================================================
#  Bevel: edges sharper than the angle
# =============================================================================
mod_bevel:
    push    rbx
    push    r12
    sub     rsp, 24
    mov     rbx, rdi
    movss   xmm0, [rsi+MD_P]            # width
    movss   [rsp], xmm0
    cvttss2si r12d, [rsi+MD_P+4]        # segments
    movss   xmm0, [rsi+MD_P+8]          # angle -> cos
    mulss   xmm0, [rip+x_d2r]
    call    sincos
    movss   [rip+bv_cos], xmm1
    mov     dword ptr [rip+bv_angle], 1
    mov     rdi, rbx
    mov     esi, r12d
    movss   xmm0, [rsp]
    call    build_bevel
    mov     dword ptr [rip+bv_angle], 0
    test    rax, rax
    jz      9f
    mov     rbx, rax
    mov     rdi, rax
    call    mesh_finish
    mov     rdi, rbx
    call    mesh_compact
9:  add     rsp, 24
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Decimate: merge vertices on a grid; the cell size is tuned to the ratio
# =============================================================================
mod_decimate:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 56
    mov     rbx, rdi
    movss   xmm0, [rsi+MD_P]            # ratio
    comiss  xmm0, [rip+x_one]
    jae     .Ldc_none                   # 1: unchanged
    cvtsi2ss xmm1, dword ptr [rbx+ME_NVERTS]
    mulss   xmm0, xmm1
    maxss   xmm0, [rip+x_four]
    movss   [rsp], xmm0                 # target vertex count
    # first guess: h = diagonal / sqrt(target)
    xorps   xmm2, xmm2
    xor     ecx, ecx
1:  movss   xmm1, [rbx+ME_BMAX+rcx*4]
    subss   xmm1, [rbx+ME_BMIN+rcx*4]
    mulss   xmm1, xmm1
    addss   xmm2, xmm1
    inc     ecx
    cmp     ecx, 3
    jb      1b
    sqrtss  xmm2, xmm2
    sqrtss  xmm1, [rsp]
    divss   xmm2, xmm1
    maxss   xmm2, [rip+x_tiny]
    movss   [rip+dc_h], xmm2
    mov     dword ptr [rsp+8], 0        # iterations
2:  call    dc_count                    # eax = occupied cells
    cvtsi2ss xmm0, eax
    movss   [rsp+4], xmm0
    divss   xmm0, [rsp]                 # count / target
    movss   xmm1, xmm0                  # close enough?
    subss   xmm1, [rip+x_one]
    andps   xmm1, [rip+x_absm]
    comiss  xmm1, [rip+x_tol]
    jb      3f
    inc     dword ptr [rsp+8]
    cmp     dword ptr [rsp+8], 10
    jae     3f
    sqrtss  xmm0, xmm0                  # surface: count ~ 1 / h^2
    mulss   xmm0, [rip+dc_h]
    movss   [rip+dc_h], xmm0
    jmp     2b
3:  # cluster: representative per cell, averaged positions
    call    dc_table
    test    rax, rax
    jz      .Ldc_none
    mov     edi, [rbx+ME_NVERTS]        # rep[v]
    shl     edi, 2
    call    fa
    test    rax, rax
    jz      .Ldc_none
    mov     r12, rax
    mov     edi, [rbx+ME_NVERTS]        # sums + count per vertex (reps use them)
    shl     edi, 4
    call    fa
    test    rax, rax
    jz      .Ldc_none
    mov     r13, rax
    xor     r14d, r14d
4:  cmp     r14d, [rbx+ME_NVERTS]
    jae     5f
    mov     edi, r14d
    call    dc_key
    mov     rsi, rax
    mov     rdi, [rip+dc_tab]
    call    eh_slot
    test    edx, edx
    jnz     41f
    mov     [rax], r14d                 # first vertex in the cell: the rep
41: mov     ecx, [rax]
    mov     [r12+r14*4], ecx
    mov     rax, [rbx+ME_POS]
    lea     rdx, [r14+r14*2]
    shl     rcx, 4
    movss   xmm0, [r13+rcx]
    addss   xmm0, [rax+rdx*4]
    movss   [r13+rcx], xmm0
    movss   xmm0, [r13+rcx+4]
    addss   xmm0, [rax+rdx*4+4]
    movss   [r13+rcx+4], xmm0
    movss   xmm0, [r13+rcx+8]
    addss   xmm0, [rax+rdx*4+8]
    movss   [r13+rcx+8], xmm0
    inc     dword ptr [r13+rcx+12]
    inc     r14d
    jmp     4b
5:  mov     edi, [rbx+ME_NVERTS]        # the new mesh
    mov     esi, [rbx+ME_NLOOPS]
    mov     edx, [rbx+ME_NPOLYS]
    call    mesh_new
    test    rax, rax
    jz      .Ldc_none
    mov     r15, rax
    xor     r14d, r14d                  # every vertex (only reps get used)
6:  cmp     r14d, [rbx+ME_NVERTS]
    jae     7f
    mov     rcx, r14
    shl     rcx, 4
    mov     eax, [r13+rcx+12]
    test    eax, eax
    jz      61f
    cvtsi2ss xmm3, eax
    movss   xmm0, [r13+rcx]
    divss   xmm0, xmm3
    movss   xmm1, [r13+rcx+4]
    divss   xmm1, xmm3
    movss   xmm2, [r13+rcx+8]
    divss   xmm2, xmm3
    jmp     62f
61: xorps   xmm0, xmm0
    xorps   xmm1, xmm1
    xorps   xmm2, xmm2
62: mov     rdi, r15
    call    mesh_add_vert
    inc     r14d
    jmp     6b
7:  xor     r14d, r14d                  # polygons through the reps
71: cmp     r14d, [rbx+ME_NPOLYS]
    jae     8f
    mov     rsi, [rbx+ME_POFF]
    mov     ecx, [rsi+r14*4]
    mov     edx, [rsi+r14*4+4]
    mov     rsi, [rbx+ME_LOOPS]
    lea     rdi, [rip+scr]
    xor     r8d, r8d
72: cmp     ecx, edx
    jae     73f
    mov     eax, [rsi+rcx*4]
    mov     eax, [r12+rax*4]
    test    r8d, r8d
    jz      721f
    cmp     [rdi+r8*4-4], eax
    je      722f
721:mov     [rdi+r8*4], eax
    inc     r8d
722:inc     ecx
    jmp     72b
73: cmp     r8d, 2
    jb      74f
    mov     eax, [rdi]
    cmp     [rdi+r8*4-4], eax
    jne     74f
    dec     r8d
74: cmp     r8d, 3
    jb      75f
    mov     rsi, rdi
    mov     rdi, r15
    mov     edx, r8d
    call    mesh_add_poly
75: inc     r14d
    jmp     71b
8:  mov     rdi, r15
    call    mesh_finish
    mov     rdi, r15
    call    mesh_compact
    jmp     9f
.Ldc_none:
    xor     eax, eax
9:  add     rsp, 56
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# dc_key(edi=vertex of rbx) -> rax = its cell key at size dc_h
dc_key:
    mov     rax, [rbx+ME_POS]
    lea     rcx, [rdi+rdi*2]
    lea     rax, [rax+rcx*4]
    movss   xmm3, [rip+x_one]
    divss   xmm3, [rip+dc_h]
    xor     ecx, ecx
    xor     r8d, r8d
1:  movss   xmm0, [rax+rcx*4]
    mulss   xmm0, xmm3
    roundss xmm0, xmm0, 1
    cvttss2si edx, xmm0
    and     edx, 0x1fffff
    shl     r8, 21
    or      r8, rdx
    inc     ecx
    cmp     ecx, 3
    jb      1b
    mov     rax, r8
    ret

# dc_table -> rax = an empty cell table (frame arena)
dc_table:
    sub     rsp, 8
    mov     edi, [rbx+ME_NVERTS]
    call    eh_new
    mov     [rip+dc_tab], rax
    add     rsp, 8
    ret

# dc_count -> eax = cells occupied at size dc_h
dc_count:
    push    r12
    push    r13
    sub     rsp, 8
    call    fa_mark
    mov     [rsp], rax
    call    dc_table
    test    rax, rax
    jz      8f
    xor     r12d, r12d
    xor     r13d, r13d
1:  cmp     r12d, [rbx+ME_NVERTS]
    jae     2f
    mov     edi, r12d
    call    dc_key
    mov     rsi, rax
    mov     rdi, [rip+dc_tab]
    call    eh_slot
    test    edx, edx
    jnz     11f
    mov     dword ptr [rax], 0
    inc     r13d
11: inc     r12d
    jmp     1b
2:  mov     rdi, [rsp]
    call    fa_release
    mov     eax, r13d
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 8
    pop     r13
    pop     r12
    ret

# =============================================================================
#  Remesh: inside / outside on a voxel grid (ray parity along x), then a
#  surface-nets quad mesh - one vertex per cell the surface crosses
# =============================================================================
mod_remesh:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 88
    mov     rbx, rdi
    movss   xmm0, [rsi+MD_P]            # voxel size
    maxss   xmm0, [rip+x_tiny]
    movss   [rip+rm_v], xmm0
    cmp     dword ptr [rbx+ME_NTRIS], 0
    je      .Lrm_none
.Lrm_size:                              # samples: bbox padded by 1.5 voxels
    movss   xmm4, [rip+rm_v]
    mulss   xmm4, [rip+x_twelfth]
    mov     eax, 1
    xor     ecx, ecx
1:  movss   xmm0, [rbx+ME_BMIN+rcx*4]
    subss   xmm0, xmm4
    lea     rdx, [rip+rm_min]
    movss   [rdx+rcx*4], xmm0
    movss   xmm1, [rbx+ME_BMAX+rcx*4]
    addss   xmm1, xmm4
    subss   xmm1, xmm0
    divss   xmm1, [rip+rm_v]
    cvttss2si edx, xmm1
    add     edx, 2
    lea     r8, [rip+rm_n]
    mov     [r8+rcx*4], edx
    imul    rax, rdx
    inc     ecx
    cmp     ecx, 3
    jb      1b
    cmp     rax, RM_MAX                 # too fine: coarser voxels
    jbe     2f
    movss   xmm0, [rip+rm_v]
    mulss   xmm0, [rip+x_grow]
    movss   [rip+rm_v], xmm0
    jmp     .Lrm_size
2:  mov     [rsp], rax                  # samples
    mov     edi, eax                    # inside flags
    call    fa
    test    rax, rax
    jz      .Lrm_none
    mov     [rip+rm_in], rax
    mov     eax, [rip+rm_n+4]           # x-lines: ny * nz
    imul    eax, [rip+rm_n+8]
    mov     [rip+rm_lines], eax
    lea     edi, [rax*4+8]
    call    fa
    test    rax, rax
    jz      .Lrm_none
    mov     [rip+rm_cnt], rax
    # pass 1 counts, pass 2 stores the crossings of every line
    xor     ebp, ebp
.Lrm_pass:
    xor     r12d, r12d                  # triangle
.Lrm_tri:
    cmp     r12d, [rbx+ME_NTRIS]
    jae     .Lrm_pass_end
    mov     rax, [rbx+ME_TRIS]
    lea     rcx, [r12+r12*2]
    mov     r8, [rbx+ME_POS]
    mov     edx, [rax+rcx*4]
    lea     rdx, [rdx+rdx*2]
    lea     r13, [r8+rdx*4]             # p0
    mov     edx, [rax+rcx*4+4]
    lea     rdx, [rdx+rdx*2]
    lea     r14, [r8+rdx*4]             # p1
    mov     edx, [rax+rcx*4+8]
    lea     rdx, [rdx+rdx*2]
    lea     r15, [r8+rdx*4]             # p2
    # YZ determinant
    movss   xmm0, [r14+4]
    subss   xmm0, [r13+4]               # y1 - y0
    movss   xmm1, [r15+8]
    subss   xmm1, [r13+8]               # z2 - z0
    mulss   xmm0, xmm1
    movss   xmm2, [r15+4]
    subss   xmm2, [r13+4]               # y2 - y0
    movss   xmm3, [r14+8]
    subss   xmm3, [r13+8]               # z1 - z0
    mulss   xmm2, xmm3
    subss   xmm0, xmm2
    movss   [rsp+8], xmm0               # d
    andps   xmm0, [rip+x_absm]
    comiss  xmm0, [rip+x_eps]
    jbe     .Lrm_tnext
    # the lines j, k inside the triangle's YZ box
    movss   xmm0, [r13+4]
    minss   xmm0, [r14+4]
    minss   xmm0, [r15+4]
    movss   xmm1, [r13+4]
    maxss   xmm1, [r14+4]
    maxss   xmm1, [r15+4]
    movss   xmm2, [r13+8]
    minss   xmm2, [r14+8]
    minss   xmm2, [r15+8]
    movss   xmm3, [r13+8]
    maxss   xmm3, [r14+8]
    maxss   xmm3, [r15+8]
    subss   xmm0, [rip+rm_min+4]
    divss   xmm0, [rip+rm_v]
    roundss xmm0, xmm0, 2               # ceil
    cvttss2si eax, xmm0
    mov     [rsp+16], eax               # j0
    subss   xmm1, [rip+rm_min+4]
    divss   xmm1, [rip+rm_v]
    roundss xmm1, xmm1, 1               # floor
    cvttss2si eax, xmm1
    mov     [rsp+20], eax               # j1
    subss   xmm2, [rip+rm_min+8]
    divss   xmm2, [rip+rm_v]
    roundss xmm2, xmm2, 2
    cvttss2si eax, xmm2
    mov     [rsp+24], eax               # k0
    subss   xmm3, [rip+rm_min+8]
    divss   xmm3, [rip+rm_v]
    roundss xmm3, xmm3, 1
    cvttss2si eax, xmm3
    mov     [rsp+28], eax               # k1
    mov     eax, [rsp+16]               # clamp to the grid
    test    eax, eax
    jns     21f
    mov     dword ptr [rsp+16], 0
21: mov     eax, [rsp+24]
    test    eax, eax
    jns     22f
    mov     dword ptr [rsp+24], 0
22: mov     eax, [rip+rm_n+4]
    dec     eax
    cmp     [rsp+20], eax
    jle     23f
    mov     [rsp+20], eax
23: mov     eax, [rip+rm_n+8]
    dec     eax
    cmp     [rsp+28], eax
    jle     24f
    mov     [rsp+28], eax
24: mov     eax, [rsp+24]               # k
    mov     [rsp+32], eax
.Lrm_k:
    mov     eax, [rsp+32]
    cmp     eax, [rsp+28]
    jg      .Lrm_tnext
    mov     eax, [rsp+16]
    mov     [rsp+36], eax               # j
.Lrm_j:
    mov     eax, [rsp+36]
    cmp     eax, [rsp+20]
    jg      .Lrm_knext
    # line point (y, z), slightly jittered against exact edge hits
    cvtsi2ss xmm4, dword ptr [rsp+36]
    addss   xmm4, [rip+x_jy]
    mulss   xmm4, [rip+rm_v]
    addss   xmm4, [rip+rm_min+4]        # y
    cvtsi2ss xmm5, dword ptr [rsp+32]
    addss   xmm5, [rip+x_jz]
    mulss   xmm5, [rip+rm_v]
    addss   xmm5, [rip+rm_min+8]        # z
    # u = ((y - y0)(z2 - z0) - (y2 - y0)(z - z0)) / d
    movss   xmm6, xmm4
    subss   xmm6, [r13+4]               # y - y0
    movss   xmm7, xmm5
    subss   xmm7, [r13+8]               # z - z0
    movss   xmm0, xmm6
    movss   xmm1, [r15+8]
    subss   xmm1, [r13+8]
    mulss   xmm0, xmm1
    movss   xmm1, [r15+4]
    subss   xmm1, [r13+4]
    mulss   xmm1, xmm7
    subss   xmm0, xmm1
    divss   xmm0, [rsp+8]               # u
    # w = ((y1 - y0)(z - z0) - (y - y0)(z1 - z0)) / d
    movss   xmm1, [r14+4]
    subss   xmm1, [r13+4]
    mulss   xmm1, xmm7
    movss   xmm2, [r14+8]
    subss   xmm2, [r13+8]
    mulss   xmm2, xmm6
    subss   xmm1, xmm2
    divss   xmm1, [rsp+8]               # w
    xorps   xmm2, xmm2
    comiss  xmm0, xmm2
    jb      .Lrm_jnext
    comiss  xmm1, xmm2
    jb      .Lrm_jnext
    movss   xmm2, xmm0
    addss   xmm2, xmm1
    comiss  xmm2, [rip+x_one]
    ja      .Lrm_jnext
    mov     eax, [rsp+32]               # line index k * ny + j
    imul    eax, [rip+rm_n+4]
    add     eax, [rsp+36]
    mov     r8, [rip+rm_cnt]
    test    ebp, ebp
    jnz     3f
    inc     dword ptr [r8+rax*4]        # pass 1: count
    jmp     .Lrm_jnext
3:  movss   xmm2, [r14]                 # pass 2: x = x0 + u dx1 + w dx2
    subss   xmm2, [r13]
    mulss   xmm2, xmm0
    movss   xmm3, [r15]
    subss   xmm3, [r13]
    mulss   xmm3, xmm1
    addss   xmm2, xmm3
    addss   xmm2, [r13]
    mov     ecx, [r8+rax*4]             # cursor
    inc     dword ptr [r8+rax*4]
    mov     rdx, [rip+rm_x]
    movss   [rdx+rcx*4], xmm2
.Lrm_jnext:
    inc     dword ptr [rsp+36]
    jmp     .Lrm_j
.Lrm_knext:
    inc     dword ptr [rsp+32]
    jmp     .Lrm_k
.Lrm_tnext:
    inc     r12d
    jmp     .Lrm_tri
.Lrm_pass_end:
    test    ebp, ebp
    jnz     .Lrm_fill
    mov     r8, [rip+rm_cnt]            # counts -> offsets; room for crossings
    xor     ecx, ecx
    xor     eax, eax
4:  cmp     ecx, [rip+rm_lines]
    jae     41f
    mov     edx, [r8+rcx*4]
    mov     [r8+rcx*4], eax
    add     eax, edx
    inc     ecx
    jmp     4b
41: mov     [r8+rcx*4], eax             # total at the end
    lea     edi, [rax*4+16]
    call    fa
    test    rax, rax
    jz      .Lrm_none
    mov     [rip+rm_x], rax
    mov     ebp, 1
    jmp     .Lrm_pass
.Lrm_fill:
    # offsets were advanced to the ends: line l spans [end(l-1), end(l))
    # sort each line's crossings and mark samples with odd crossings before
    xor     r12d, r12d                  # line
5:  cmp     r12d, [rip+rm_lines]
    jae     .Lrm_nets
    mov     r8, [rip+rm_cnt]
    xor     r13d, r13d
    test    r12d, r12d
    jz      51f
    mov     r13d, [r8+r12*4-4]          # begin
51: mov     r14d, [r8+r12*4]            # end
    mov     r9, [rip+rm_x]
    lea     ecx, [r13+1]                # insertion sort
52: cmp     ecx, r14d
    jae     53f
    movss   xmm0, [r9+rcx*4]
    mov     edx, ecx
521:cmp     edx, r13d
    jbe     522f
    comiss  xmm0, [r9+rdx*4-4]
    jae     522f
    mov     eax, [r9+rdx*4-4]
    mov     [r9+rdx*4], eax
    dec     edx
    jmp     521b
522:movss   [r9+rdx*4], xmm0
    inc     ecx
    jmp     52b
53: mov     eax, r12d                   # samples along the line
    xor     edx, edx
    div     dword ptr [rip+rm_n+4]
    mov     [rsp+40], edx               # j
    mov     [rsp+44], eax               # k
    mov     ecx, r13d                   # next crossing
    xor     r15d, r15d                  # inside?
    xor     ebx, ebx                    # (rbx is reloaded below)
    xor     r10d, r10d                  # i
54: cmp     r10d, [rip+rm_n]
    jae     55f
    cvtsi2ss xmm0, r10d
    mulss   xmm0, [rip+rm_v]
    addss   xmm0, [rip+rm_min]          # sample x
541:cmp     ecx, r14d
    jae     542f
    comiss  xmm0, [r9+rcx*4]
    jb      542f
    xor     r15d, 1
    inc     ecx
    jmp     541b
542:mov     eax, [rsp+44]               # index (k ny + j) nx + i
    imul    eax, [rip+rm_n+4]
    add     eax, [rsp+40]
    imul    eax, [rip+rm_n]
    add     eax, r10d
    mov     rdx, [rip+rm_in]
    mov     [rdx+rax], r15b
    inc     r10d
    jmp     54b
55: inc     r12d
    jmp     5b
.Lrm_nets:
    # cells: (nx-1)(ny-1)(nz-1); vertex per mixed cell
    mov     eax, [rip+rm_n]
    dec     eax
    mov     [rsp+48], eax               # cx
    mov     eax, [rip+rm_n+4]
    dec     eax
    mov     [rsp+52], eax               # cy
    mov     eax, [rip+rm_n+8]
    dec     eax
    mov     [rsp+56], eax               # cz
    mov     eax, [rsp+48]
    imul    eax, [rsp+52]
    imul    eax, [rsp+56]
    mov     [rsp+60], eax               # cells
    lea     edi, [rax*4+8]
    call    fa
    test    rax, rax
    jz      .Lrm_none
    mov     [rip+rm_cell], rax
    xor     r13d, r13d                  # vertices
    xor     r12d, r12d                  # cell
6:  cmp     r12d, [rsp+60]
    jae     7f
    mov     edi, r12d
    call    cell_mixed                  # eax = 1 if the surface crosses it
    mov     rdx, [rip+rm_cell]
    mov     dword ptr [rdx+r12*4], -1
    test    eax, eax
    jz      61f
    mov     [rdx+r12*4], r13d
    inc     r13d
61: inc     r12d
    jmp     6b
7:  test    r13d, r13d
    jz      .Lrm_none
    mov     edi, r13d                   # the mesh: quads <= 3 per sample
    mov     esi, r13d
    shl     esi, 4
    mov     edx, r13d
    shl     edx, 2
    call    mesh_new
    test    rax, rax
    jz      .Lrm_none
    mov     r14, rax
    mov     [rip+rm_mesh], rax
    xor     r12d, r12d                  # vertex positions: cell centres
8:  cmp     r12d, [rsp+60]
    jae     9f
    mov     rdx, [rip+rm_cell]
    cmp     dword ptr [rdx+r12*4], 0
    jl      81f
    mov     eax, r12d                   # (i, j, k) of the cell
    xor     edx, edx
    div     dword ptr [rsp+48]
    mov     r8d, edx                    # i
    xor     edx, edx
    div     dword ptr [rsp+52]
    mov     r9d, edx                    # j
    mov     r10d, eax                   # k
    cvtsi2ss xmm0, r8d
    addss   xmm0, [rip+x_half]
    mulss   xmm0, [rip+rm_v]
    addss   xmm0, [rip+rm_min]
    cvtsi2ss xmm1, r9d
    addss   xmm1, [rip+x_half]
    mulss   xmm1, [rip+rm_v]
    addss   xmm1, [rip+rm_min+4]
    cvtsi2ss xmm2, r10d
    addss   xmm2, [rip+x_half]
    mulss   xmm2, [rip+rm_v]
    addss   xmm2, [rip+rm_min+8]
    mov     rdi, r14
    call    mesh_add_vert
81: inc     r12d
    jmp     8b
9:  # faces: every sample edge with a sign change, 3 axes
    xor     r12d, r12d                  # sample
91: cmp     r12d, [rsp]
    jae     .Lrm_done
    xor     r15d, r15d                  # axis
92: cmp     r15d, 3
    jae     93f
    mov     edi, r12d
    mov     esi, r15d
    call    edge_quad                   # adds a quad when the edge crosses
    inc     r15d
    jmp     92b
93: inc     r12d
    jmp     91b
.Lrm_done:
    mov     rdi, r14
    call    mesh_finish
    mov     rdi, r14                    # relax the staircase a little
    call    smooth2
    mov     rdi, r14
    call    mesh_bbox
    mov     rax, r14
    jmp     .Lrm_out
.Lrm_none:
    xor     eax, eax
.Lrm_out:
    add     rsp, 88
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# smooth2(rdi=mesh) - two rounds of p = (p + mean(neighbours)) / 2
smooth2:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     rbx, rdi
    mov     edi, [rbx+ME_NVERTS]        # sums (xyz) + counts
    shl     edi, 4
    call    fa
    test    rax, rax
    jz      9f
    mov     r12, rax
    xor     r14d, r14d                  # round
1:  cmp     r14d, 2
    jae     9f
    mov     rdi, r12
    mov     ecx, [rbx+ME_NVERTS]
    shl     ecx, 4
    xor     eax, eax
    rep     stosb
    mov     r8, [rbx+ME_EDGES]
    mov     r9, [rbx+ME_POS]
    xor     ecx, ecx
2:  cmp     ecx, [rbx+ME_NEDGES]
    jae     3f
    mov     eax, [r8+rcx*8]
    mov     edx, [r8+rcx*8+4]
    lea     r10, [rax+rax*2]
    lea     r11, [rdx+rdx*2]
    shl     rax, 4
    shl     rdx, 4
    xor     r13d, r13d
21: movss   xmm0, [r12+rax]             # a += b, b += a
    addss   xmm0, [r9+r11*4]
    movss   [r12+rax], xmm0
    movss   xmm0, [r12+rdx]
    addss   xmm0, [r9+r10*4]
    movss   [r12+rdx], xmm0
    add     rax, 4
    add     rdx, 4
    inc     r10
    inc     r11
    inc     r13d
    cmp     r13d, 3
    jb      21b
    inc     dword ptr [r12+rax]         # (rax / rdx now at the counts)
    inc     dword ptr [r12+rdx]
    inc     ecx
    jmp     2b
3:  xor     ecx, ecx
4:  cmp     ecx, [rbx+ME_NVERTS]
    jae     5f
    mov     rax, rcx
    shl     rax, 4
    mov     edx, [r12+rax+12]
    test    edx, edx
    jz      41f
    cvtsi2ss xmm3, edx
    lea     rdx, [rcx+rcx*2]
    xor     r13d, r13d
42: movss   xmm0, [r12+rax]
    divss   xmm0, xmm3
    addss   xmm0, [r9+rdx*4]
    mulss   xmm0, [rip+x_half]
    movss   [r9+rdx*4], xmm0
    add     rax, 4
    inc     rdx
    inc     r13d
    cmp     r13d, 3
    jb      42b
41: inc     ecx
    jmp     4b
5:  inc     r14d
    jmp     1b
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# sample(edi=i, esi=j, edx=k) -> eax = inside flag (0 outside the grid)
sample:
    xor     eax, eax
    test    edi, edi
    js      9f
    test    esi, esi
    js      9f
    test    edx, edx
    js      9f
    cmp     edi, [rip+rm_n]
    jge     9f
    cmp     esi, [rip+rm_n+4]
    jge     9f
    cmp     edx, [rip+rm_n+8]
    jge     9f
    mov     eax, edx
    imul    eax, [rip+rm_n+4]
    add     eax, esi
    imul    eax, [rip+rm_n]
    add     eax, edi
    mov     rcx, [rip+rm_in]
    movzx   eax, byte ptr [rcx+rax]
9:  ret

# cell_mixed(edi=cell) -> eax = 1 if its 8 samples disagree
cell_mixed:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     eax, edi
    mov     ecx, [rip+rm_n]
    dec     ecx
    xor     edx, edx
    div     ecx
    mov     r12d, edx                   # i
    mov     ecx, [rip+rm_n+4]
    dec     ecx
    xor     edx, edx
    div     ecx
    mov     r13d, edx                   # j
    mov     r14d, eax                   # k
    xor     ebx, ebx                    # or
    mov     r15d, 1                     # and
    xor     ecx, ecx
1:  cmp     ecx, 8
    jae     2f
    push    rcx
    mov     edi, ecx
    and     edi, 1
    add     edi, r12d
    mov     esi, ecx
    shr     esi, 1
    and     esi, 1
    add     esi, r13d
    mov     edx, ecx
    shr     edx, 2
    add     edx, r14d
    call    sample
    pop     rcx
    or      ebx, eax
    and     r15d, eax
    inc     ecx
    jmp     1b
2:  xor     eax, eax
    cmp     ebx, r15d
    setne   al
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# cell_vert(edi=i, esi=j, edx=k) -> eax = the cell's vertex or -1
cell_vert:
    mov     eax, -1
    test    edi, edi
    js      9f
    test    esi, esi
    js      9f
    test    edx, edx
    js      9f
    mov     ecx, [rip+rm_n]
    dec     ecx
    cmp     edi, ecx
    jge     9f
    mov     ecx, [rip+rm_n+4]
    dec     ecx
    cmp     esi, ecx
    jge     9f
    mov     ecx, [rip+rm_n+8]
    dec     ecx
    cmp     edx, ecx
    jge     9f
    mov     eax, edx
    mov     ecx, [rip+rm_n+4]
    dec     ecx
    imul    eax, ecx
    add     eax, esi
    mov     ecx, [rip+rm_n]
    dec     ecx
    imul    eax, ecx
    add     eax, edi
    mov     rcx, [rip+rm_cell]
    mov     eax, [rcx+rax*4]
9:  ret

# edge_quad(edi=sample, esi=axis) - r14 = mesh. The edge from the sample to
#   its +axis neighbour: on a sign change, the 4 cells around it form a quad
#   (in the plane of the other two axes, cyclic: x -> (y, z), y -> (z, x),
#   z -> (x, y)), wound so its normal leaves the inside.
edge_quad:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 56
    mov     ebp, esi
    mov     eax, edi                    # (i, j, k)
    xor     edx, edx
    div     dword ptr [rip+rm_n]
    mov     [rsp], edx                  # i
    xor     edx, edx
    div     dword ptr [rip+rm_n+4]
    mov     [rsp+4], edx                # j
    mov     [rsp+8], eax                # k
    mov     edi, [rsp]
    mov     esi, [rsp+4]
    mov     edx, [rsp+8]
    call    sample
    mov     r12d, eax                   # s0
    mov     eax, [rsp+rbp*4]            # the neighbour along the axis
    mov     [rsp+12], eax
    inc     dword ptr [rsp+rbp*4]
    mov     edi, [rsp]
    mov     esi, [rsp+4]
    mov     edx, [rsp+8]
    call    sample
    mov     ecx, [rsp+12]
    mov     [rsp+rbp*4], ecx
    cmp     eax, r12d
    je      9f
    # a, b: the other two axes in cyclic order
    lea     r13d, [rbp+1]
    cmp     r13d, 3
    jb      1f
    xor     r13d, r13d
1:  lea     r14d, [r13+1]
    cmp     r14d, 3
    jb      2f
    xor     r14d, r14d
2:  # cells (a-1,b-1), (a,b-1), (a,b), (a-1,b) around the edge
    lea     rbx, [rip+eq_da]
    xor     r15d, r15d
3:  cmp     r15d, 4
    jae     4f
    mov     eax, [rsp]                  # cell = sample + offsets
    mov     [rsp+16], eax
    mov     eax, [rsp+4]
    mov     [rsp+20], eax
    mov     eax, [rsp+8]
    mov     [rsp+24], eax
    mov     eax, [rbx+r15*8]            # da
    add     [rsp+16+r13*4], eax
    mov     eax, [rbx+r15*8+4]          # db
    add     [rsp+16+r14*4], eax
    mov     edi, [rsp+16]
    mov     esi, [rsp+20]
    mov     edx, [rsp+24]
    call    cell_vert
    test    eax, eax
    js      9f
    mov     [rsp+32+r15*4], eax
    inc     r15d
    jmp     3b
4:  test    r12d, r12d                  # inside at the far side: reverse
    jnz     5f
    mov     eax, [rsp+32]
    mov     ecx, [rsp+44]
    mov     [rsp+32], ecx
    mov     [rsp+44], eax
    mov     eax, [rsp+36]
    mov     ecx, [rsp+40]
    mov     [rsp+36], ecx
    mov     [rsp+40], eax
5:  mov     rdi, [rip+rm_mesh]
    lea     rsi, [rsp+32]
    mov     edx, 4
    call    mesh_add_poly
9:  add     rsp, 56
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.section .rodata
.align 4
eq_da:          .long -1, -1, 0, -1, 0, 0, -1, 0
x_four:         .float 4.0
x_tiny:         .float 1.0e-6
x_grow:         .float 1.2
.align 16
x_absm:         .long 0x7fffffff, 0, 0, 0

.section .note.GNU-stack,"",@progbits
