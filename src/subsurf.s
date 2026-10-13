# =============================================================================
#  BeeModel - subdivision surfaces (Catmull-Clark), fast.
#
#  Corner-based topology: a corner c is a (face, vertex) pair; twin[c] is the
#  corner of the neighbouring face that runs the same edge backwards (-1 on
#  a boundary), eid[c] its edge. Level 0 comes from the input mesh (one hash
#  build); every further level is derived arithmetically - new corner 4c+k of
#  old corner c - so no level after the first needs hashing, and every pass
#  runs in parallel over faces, corners or vertices.
#
#  The topology of all levels and the output mesh are cached per (base mesh,
#  levels): moving vertices of the base mesh (edit mode) only recomputes the
#  positions, written into the cached output in place.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"

# exports
.globl subsurf_eval
.globl subsurf_mr
.globl subsurf_fit
.globl ss_off
.globl ss_total
.globl subsurf_flush
.globl subsurf_forget

.equ LV_V,      0
.equ LV_E,      4
.equ LV_F,      8
.equ LV_L,      12
.equ LV_QUAD,   16
.equ LV_LOOPS,  24
.equ LV_POFF,   32
.equ LV_CFACE,  40
.equ LV_TWIN,   48
.equ LV_EID,    56
.equ LV_VC,     64
.equ LV_SZ,     72
.equ MAXLV,     7

.equ SE_BASE,   0               # cache entry
.equ SE_LEVELS, 8
.equ SE_OUT,    16
.equ SE_NAL,    24
.equ SE_AL,     32              # 48 (ptr, size) pairs
.equ SE_LV,     32+48*16
.equ SE_POS,    SE_LV+MAXLV*LV_SZ
.equ SE_MR,     SE_POS+(MAXLV+1)*8   # 1: multires (displaced) positions
.equ SE_SZ,     SE_MR+8
.equ SS_N,      4
.equ GRAIN,     4096
.equ ME_VER,    108

.section .bss
.align 16
ss_cache:       .skip SS_N*SE_SZ
ss_next:        .skip 4             # round robin victim
.align 8
jlv:            .skip 8             # job context: level, next level, positions
jnx:            .skip 8
jpin:           .skip 8
jpout:          .skip 8
jout:           .skip 8             # output mesh (last level)
jbox:           .skip 8             # per chunk bounding boxes
ss_entry:       .skip 8
ss_mr:          .skip 8             # the evaluation asked for: multires,
ss_disp:        .skip 8             #  displacements (level 1, 2, ... one
ss_dispn:       .skip 4             #  after the other) or 0, how many,
ss_fit:         .skip 8             #  fit targets (the finest positions)
ss_off:         .skip 4             # after: the last level's displacements'
ss_total:       .skip 4             #  offset, and the end of them
ss_mark:        .skip 8

.section .rodata
.align 4
sf_quarter:     .float 0.25
sf_half:        .float 0.5
sf_eighth:      .float 0.125
sf_six:         .float 6.0
sf_three:       .float 3.0
sf_two:         .float 2.0
sf_one:         .float 1.0
sf_big:         .float 1.0e30
sf_nbig:        .float -1.0e30

.text

# =============================================================================
#  Cache
# =============================================================================
# subsurf_flush - drop every cached topology (scene replaced)
subsurf_flush:
    push    rbx
    push    r12
    sub     rsp, 8
    lea     rbx, [rip+ss_cache]
    xor     r12d, r12d
1:  cmp     r12d, SS_N
    jae     9f
    mov     rdi, rbx
    call    se_clear
    add     rbx, SE_SZ
    inc     r12d
    jmp     1b
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# subsurf_forget(rdi=mesh) - it is being freed: entries built on it go
subsurf_forget:
    push    rbx
    push    r12
    push    r13
    mov     r12, rdi
    lea     rbx, [rip+ss_cache]
    xor     r13d, r13d
1:  cmp     r13d, SS_N
    jae     9f
    cmp     [rbx+SE_BASE], r12
    jne     2f
    mov     rdi, rbx
    call    se_clear
2:  add     rbx, SE_SZ
    inc     r13d
    jmp     1b
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# se_clear(rdi=entry) - release its memory and references
se_clear:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    xor     r12d, r12d
1:  cmp     r12d, [rbx+SE_NAL]
    jae     2f
    mov     eax, r12d
    shl     eax, 4
    mov     rdi, [rbx+SE_AL+rax]
    mov     rsi, [rbx+SE_AL+rax+8]
    mov     eax, SYS_MUNMAP
    syscall
    inc     r12d
    jmp     1b
2:  mov     dword ptr [rbx+SE_NAL], 0
    mov     rdi, [rbx+SE_OUT]
    mov     qword ptr [rbx+SE_OUT], 0
    mov     qword ptr [rbx+SE_BASE], 0  # (weak: not a counted user)
    call    mesh_unref
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# se_alloc(rbx=entry, rdi=bytes) -> rax (mmap'd, zero) or 0
se_alloc:
    push    r12
    mov     r12, rdi
    add     r12, 4095
    and     r12, -4096
    cmp     dword ptr [rbx+SE_NAL], 48
    jae     8f
    xor     edi, edi
    mov     rsi, r12
    mov     edx, PROT_RW
    mov     r10d, 0x22
    mov     r8d, -1
    xor     r9d, r9d
    mov     eax, SYS_MMAP
    syscall
    cmp     rax, -4096
    ja      8f
    mov     ecx, [rbx+SE_NAL]
    shl     ecx, 4
    mov     [rbx+SE_AL+rcx], rax
    mov     [rbx+SE_AL+rcx+8], r12
    inc     dword ptr [rbx+SE_NAL]
    pop     r12
    ret
8:  xor     eax, eax
    pop     r12
    ret

# subsurf_eval(rdi=mesh, esi=levels 1..6) -> rax = subdivided mesh (a new
#   reference) or 0
subsurf_eval:
    mov     qword ptr [rip+ss_mr], 0
    mov     qword ptr [rip+ss_disp], 0
    mov     qword ptr [rip+ss_fit], 0
    jmp     ss_eval

# subsurf_mr(rdi=mesh, esi=levels, rdx=displacements (float[3] each, levels
#   1.. in order) or 0, ecx=how many) -> rax = the displaced subdivision (a
#   new reference; its own cache entries) or 0. Levels the displacements do
#   not cover get none.
subsurf_mr:
    mov     qword ptr [rip+ss_mr], 1
    mov     [rip+ss_disp], rdx
    mov     [rip+ss_dispn], ecx
    mov     qword ptr [rip+ss_fit], 0
    jmp     ss_eval

# subsurf_fit(rdi=mesh, esi=levels, rdx=displacements out (ss_total of
#   them), rcx=targets: the finest level's positions) -> rax = as
#   subsurf_mr: each level j becomes the targets' first vertices, D_j what
#   it takes over S(level j-1); the finest level is the targets exactly
subsurf_fit:
    mov     qword ptr [rip+ss_mr], 1
    mov     [rip+ss_disp], rdx
    mov     dword ptr [rip+ss_dispn], 0x7fffffff
    mov     [rip+ss_fit], rcx
    jmp     ss_eval

ss_eval:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     r12, rdi
    mov     r13d, esi
    lea     rbx, [rip+ss_cache]         # a matching entry?
    xor     r14d, r14d
1:  cmp     r14d, SS_N
    jae     2f
    cmp     [rbx+SE_BASE], r12
    jne     11f
    cmp     [rbx+SE_LEVELS], r13d
    jne     11f
    mov     rax, [rip+ss_mr]
    cmp     [rbx+SE_MR], rax
    jne     11f
    cmp     qword ptr [rbx+SE_OUT], 0
    jne     .Lse_hit
11: add     rbx, SE_SZ
    inc     r14d
    jmp     1b
2:  mov     eax, [rip+ss_next]          # build into the next victim
    inc     dword ptr [rip+ss_next]
    and     eax, SS_N-1
    imul    eax, eax, SE_SZ
    lea     rbx, [rip+ss_cache]
    add     rbx, rax
    mov     rdi, rbx
    call    se_clear
    mov     [rbx+SE_BASE], r12
    mov     [rbx+SE_LEVELS], r13d
    mov     rax, [rip+ss_mr]
    mov     [rbx+SE_MR], rax
    call    build
    test    eax, eax
    jnz     .Lse_hit
    mov     rdi, rbx
    call    se_clear
    xor     eax, eax
    jmp     9f
.Lse_hit:
    mov     [rip+ss_entry], rbx
    call    positions                   # (cheap when only positions changed)
    mov     rdi, [rbx+SE_OUT]
    call    mesh_ref
    mov     rax, [rbx+SE_OUT]
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Topology
# =============================================================================
# build(rbx=entry) -> eax = 1: level 0 from the base mesh, the derived
#   levels, the output mesh with its loops / edges / triangles
build:
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    call    fa_mark
    mov     [rip+ss_mark], rax
    mov     r12, [rbx+SE_BASE]
    lea     r13, [rbx+SE_LV]            # level 0
    mov     eax, [r12+ME_NVERTS]
    mov     [r13+LV_V], eax
    mov     eax, [r12+ME_NPOLYS]
    mov     [r13+LV_F], eax
    mov     eax, [r12+ME_NLOOPS]
    mov     [r13+LV_L], eax
    mov     dword ptr [r13+LV_QUAD], 0
    mov     rax, [r12+ME_LOOPS]
    mov     [r13+LV_LOOPS], rax
    mov     rax, [r12+ME_POFF]
    mov     [r13+LV_POFF], rax
    mov     rax, [r12+ME_POS]
    mov     [rbx+SE_POS], rax
    mov     edi, [r13+LV_L]             # per-corner arrays
    shl     rdi, 2
    call    se_alloc
    test    rax, rax
    jz      .Lb_fail
    mov     [r13+LV_CFACE], rax
    mov     edi, [r13+LV_L]
    shl     rdi, 2
    call    se_alloc
    test    rax, rax
    jz      .Lb_fail
    mov     [r13+LV_TWIN], rax
    mov     edi, [r13+LV_L]
    shl     rdi, 2
    call    se_alloc
    test    rax, rax
    jz      .Lb_fail
    mov     [r13+LV_EID], rax
    mov     edi, [r13+LV_V]
    shl     rdi, 2
    add     rdi, 4
    call    se_alloc
    test    rax, rax
    jz      .Lb_fail
    mov     [r13+LV_VC], rax
    mov     rdi, r13
    call    level0                      # cface, twin, eid, vcorner, E
    test    eax, eax
    jz      .Lb_fail
    # derived levels 1 .. levels-1
    xor     r14d, r14d                  # k
1:  mov     eax, [rbx+SE_LEVELS]
    dec     eax
    cmp     r14d, eax
    jae     2f
    imul    eax, r14d, LV_SZ
    lea     r13, [rbx+SE_LV+rax]        # level k
    lea     r15, [r13+LV_SZ]            # level k+1
    mov     eax, [r13+LV_V]             # V' = V + E + F
    add     eax, [r13+LV_E]
    add     eax, [r13+LV_F]
    mov     [r15+LV_V], eax
    mov     eax, [r13+LV_E]             # E' = 2E + L
    add     eax, eax
    add     eax, [r13+LV_L]
    mov     [r15+LV_E], eax
    mov     eax, [r13+LV_L]             # F' = L, L' = 4L
    mov     [r15+LV_F], eax
    shl     eax, 2
    mov     [r15+LV_L], eax
    mov     dword ptr [r15+LV_QUAD], 1
    mov     edi, [r15+LV_L]
    shl     rdi, 2
    call    se_alloc
    test    rax, rax
    jz      .Lb_fail
    mov     [r15+LV_LOOPS], rax
    mov     edi, [r15+LV_L]
    shl     rdi, 2
    call    se_alloc
    test    rax, rax
    jz      .Lb_fail
    mov     [r15+LV_TWIN], rax
    mov     edi, [r15+LV_L]
    shl     rdi, 2
    call    se_alloc
    test    rax, rax
    jz      .Lb_fail
    mov     [r15+LV_EID], rax
    mov     edi, [r15+LV_V]
    shl     rdi, 2
    add     rdi, 4
    call    se_alloc
    test    rax, rax
    jz      .Lb_fail
    mov     [r15+LV_VC], rax
    mov     edi, [r15+LV_V]             # positions of level k+1
    imul    rdi, rdi, 12
    call    se_alloc
    test    rax, rax
    jz      .Lb_fail
    lea     ecx, [r14+1]
    mov     [rbx+SE_POS+rcx*8], rax
    mov     [rip+jlv], r13
    mov     [rip+jnx], r15
    lea     rdi, [rip+j_topo]
    xor     esi, esi
    mov     edx, [r13+LV_L]
    mov     ecx, GRAIN
    call    parallel_for
    lea     rdi, [rip+j_vc]
    xor     esi, esi
    mov     edx, [r13+LV_V]
    mov     ecx, GRAIN
    call    parallel_for
    inc     r14d
    jmp     1b
2:  # the output mesh: last level's corners become quads
    mov     eax, [rbx+SE_LEVELS]
    dec     eax
    imul    eax, eax, LV_SZ
    lea     r13, [rbx+SE_LV+rax]
    mov     edi, [r13+LV_V]
    add     edi, [r13+LV_E]
    add     edi, [r13+LV_F]
    mov     esi, [r13+LV_L]
    shl     esi, 2
    mov     edx, [r13+LV_L]
    call    mesh_new
    test    rax, rax
    jz      .Lb_fail
    mov     [rbx+SE_OUT], rax
    mov     r15, rax
    mov     eax, [r13+LV_V]
    add     eax, [r13+LV_E]
    add     eax, [r13+LV_F]
    mov     [r15+ME_NVERTS], eax
    mov     eax, [r13+LV_L]
    mov     [r15+ME_NPOLYS], eax
    lea     ecx, [rax*2]
    mov     [r15+ME_NTRIS], ecx
    shl     eax, 2
    mov     [r15+ME_NLOOPS], eax
    mov     eax, [r13+LV_E]
    add     eax, eax
    add     eax, [r13+LV_L]
    mov     [r15+ME_NEDGES], eax
    mov     ecx, [rbx+SE_LEVELS]
    mov     rax, [r15+ME_POS]
    mov     [rbx+SE_POS+rcx*8], rax
    mov     [rip+jlv], r13
    mov     [rip+jout], r15
    lea     rdi, [rip+j_out]
    xor     esi, esi
    mov     edx, [r13+LV_L]
    mov     ecx, GRAIN
    call    parallel_for
    mov     rax, [r15+ME_POFF]          # sentinel
    mov     ecx, [r15+ME_NPOLYS]
    mov     edx, [r15+ME_NLOOPS]
    mov     [rax+rcx*4], edx
    mov     eax, 1
    jmp     9f
.Lb_fail:
    xor     eax, eax
9:  push    rax
    mov     rdi, [rip+ss_mark]
    call    fa_release
    pop     rax
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    ret

# level0(rdi=level) -> eax = 1: cface, twin (through a hash of directed
#   edges), edge ids (owners numbered first), one corner per vertex
level0:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r12, rdi
    mov     r13, [r12+LV_POFF]          # cface
    mov     r14, [r12+LV_CFACE]
    xor     ecx, ecx
1:  cmp     ecx, [r12+LV_F]
    jae     2f
    mov     eax, [r13+rcx*4]
    mov     edx, [r13+rcx*4+4]
11: cmp     eax, edx
    jae     12f
    mov     [r14+rax*4], ecx
    inc     eax
    jmp     11b
12: inc     ecx
    jmp     1b
2:  mov     edi, [r12+LV_L]             # hash: directed (a, b) -> corner
    call    eh_new
    test    rax, rax
    jz      .Ll0_fail
    mov     r15, rax
    xor     ebx, ebx
3:  cmp     ebx, [r12+LV_L]
    jae     4f
    mov     edi, ebx
    mov     rsi, r12
    call    g_next
    mov     rcx, [r12+LV_LOOPS]
    mov     esi, [rcx+rax*4]            # b
    mov     edi, [rcx+rbx*4]            # a
    call    dkey
    mov     rsi, rax
    mov     rdi, r15
    call    eh_slot
    mov     [rax], ebx
    inc     ebx
    jmp     3b
4:  xor     ebx, ebx                    # twin = the corner running b -> a
5:  cmp     ebx, [r12+LV_L]
    jae     6f
    mov     edi, ebx
    mov     rsi, r12
    call    g_next
    mov     rcx, [r12+LV_LOOPS]
    mov     edi, [rcx+rax*4]            # b
    mov     esi, [rcx+rbx*4]            # a
    call    dkey
    lea     rsi, [rax+1]
    mov     rdi, r15
    call    eh_get2
    mov     rcx, [r12+LV_TWIN]
    mov     [rcx+rbx*4], eax
    inc     ebx
    jmp     5b
6:  mov     r8, [r12+LV_TWIN]           # edge ids: owners first
    mov     r9, [r12+LV_EID]
    xor     ecx, ecx
    xor     edx, edx
7:  cmp     ecx, [r12+LV_L]
    jae     8f
    mov     eax, [r8+rcx*4]
    test    eax, eax
    js      71f
    cmp     ecx, eax
    ja      72f
71: mov     [r9+rcx*4], edx
    inc     edx
72: inc     ecx
    jmp     7b
8:  mov     [r12+LV_E], edx
    xor     ecx, ecx
81: cmp     ecx, [r12+LV_L]
    jae     82f
    mov     eax, [r8+rcx*4]
    test    eax, eax
    js      83f
    cmp     ecx, eax
    jbe     83f
    mov     eax, [r9+rax*4]
    mov     [r9+rcx*4], eax
83: inc     ecx
    jmp     81b
82: mov     rdi, [r12+LV_VC]            # vertex -> a corner (-1 if unused)
    mov     ecx, [r12+LV_V]
    mov     eax, -1
    rep     stosd
    mov     rdi, [r12+LV_VC]
    mov     rsi, [r12+LV_LOOPS]
    xor     ecx, ecx
84: cmp     ecx, [r12+LV_L]
    jae     85f
    mov     eax, [rsi+rcx*4]
    mov     [rdi+rax*4], ecx
    inc     ecx
    jmp     84b
85: mov     eax, 1
    jmp     9f
.Ll0_fail:
    xor     eax, eax
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# eh_get2(rdi=table, rsi=key+1) -> eax = value or -1
eh_get2:
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

# ---- corner navigation (rsi = level) ----------------------------------------
# g_next(edi=c) -> eax ; g_prev(edi=c) -> eax ; g_face(edi=c) -> eax
g_next:
    cmp     dword ptr [rsi+LV_QUAD], 0
    je      1f
    lea     eax, [rdi+1]
    and     eax, 3
    mov     ecx, edi
    and     ecx, -4
    or      eax, ecx
    ret
1:  mov     rax, [rsi+LV_CFACE]
    mov     eax, [rax+rdi*4]
    mov     rcx, [rsi+LV_POFF]
    lea     edx, [rdi+1]
    cmp     edx, [rcx+rax*4+4]
    jb      2f
    mov     edx, [rcx+rax*4]
2:  mov     eax, edx
    ret
g_prev:
    cmp     dword ptr [rsi+LV_QUAD], 0
    je      1f
    lea     eax, [rdi+3]
    and     eax, 3
    mov     ecx, edi
    and     ecx, -4
    or      eax, ecx
    ret
1:  mov     rax, [rsi+LV_CFACE]
    mov     eax, [rax+rdi*4]
    mov     rcx, [rsi+LV_POFF]
    lea     edx, [rdi-1]
    cmp     edi, [rcx+rax*4]
    ja      2f
    mov     edx, [rcx+rax*4+4]
    dec     edx
2:  mov     eax, edx
    ret
g_face:
    cmp     dword ptr [rsi+LV_QUAD], 0
    je      1f
    mov     eax, edi
    shr     eax, 2
    ret
1:  mov     rax, [rsi+LV_CFACE]
    mov     eax, [rax+rdi*4]
    ret
# g_first(edi=face) -> eax = its first corner
g_first:
    cmp     dword ptr [rsi+LV_QUAD], 0
    je      1f
    lea     eax, [rdi*4]
    ret
1:  mov     rax, [rsi+LV_POFF]
    mov     eax, [rax+rdi*4]
    ret

# owner(edi=c, rsi=level) -> eax = 1 if c owns its edge
owner:
    mov     rax, [rsi+LV_TWIN]
    mov     eax, [rax+rdi*4]
    test    eax, eax
    js      1f
    cmp     edi, eax
    jb      1f
    xor     eax, eax
    ret
1:  mov     eax, 1
    ret

# j_topo(ctx, esi=first corner, edx=end) - corners of level k -> k+1
j_topo:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 24
    mov     ebx, esi
    mov     [rsp], edx
    mov     r12, [rip+jlv]
    mov     r13, [rip+jnx]
.Ljt_c:
    cmp     ebx, [rsp]
    jae     .Ljt_out
    mov     rsi, r12
    mov     edi, ebx
    call    g_prev
    mov     r14d, eax                   # p
    mov     rsi, r12
    mov     edi, ebx
    call    g_face
    mov     r15d, eax                   # f
    mov     rax, [r12+LV_LOOPS]
    mov     ebp, [rax+rbx*4]            # v
    mov     rax, [r12+LV_EID]
    mov     ecx, [rax+rbx*4]            # e
    mov     edx, [rax+r14*4]            # ep
    mov     [rsp+8], ecx
    mov     [rsp+12], edx
    lea     r8d, [rbx*4]                # q = 4c
    mov     r9, [r13+LV_LOOPS]          # loops'
    mov     [r9+r8*4], ebp
    mov     eax, [r12+LV_V]
    add     eax, ecx
    mov     [r9+r8*4+4], eax            # V + e
    mov     eax, [r12+LV_V]
    add     eax, [r12+LV_E]
    add     eax, r15d
    mov     [r9+r8*4+8], eax            # V + E + f
    mov     eax, [r12+LV_V]
    add     eax, edx
    mov     [r9+r8*4+12], eax           # V + ep
    mov     r9, [r13+LV_EID]            # eid'
    mov     rsi, r12
    mov     edi, ebx
    call    owner
    xor     eax, 1                      # 2e + (own ? 0 : 1)
    mov     ecx, [rsp+8]
    lea     eax, [rax+rcx*2]
    lea     r8d, [rbx*4]
    mov     [r9+r8*4], eax
    mov     eax, [r12+LV_E]             # 2E + c
    add     eax, eax
    lea     ecx, [rax+rbx]
    mov     [r9+r8*4+4], ecx
    lea     ecx, [rax+r14]              # 2E + p
    mov     [r9+r8*4+8], ecx
    mov     rsi, r12
    mov     edi, r14d
    call    owner                       # 2ep + (own(p) ? 1 : 0)
    mov     ecx, [rsp+12]
    lea     eax, [rax+rcx*2]
    lea     r8d, [rbx*4]
    mov     [r9+r8*4+12], eax
    mov     r9, [r13+LV_TWIN]           # twin'
    mov     rax, [r12+LV_TWIN]
    mov     eax, [rax+rbx*4]            # t = twin(c)
    test    eax, eax
    js      1f
    mov     rsi, r12
    mov     edi, eax
    call    g_next
    lea     eax, [rax*4+3]
1:  lea     r8d, [rbx*4]
    mov     [r9+r8*4], eax
    mov     rsi, r12
    mov     edi, ebx
    call    g_next
    lea     eax, [rax*4+2]
    lea     r8d, [rbx*4]
    mov     [r9+r8*4+4], eax
    lea     eax, [r14*4+1]
    mov     [r9+r8*4+8], eax
    mov     rax, [r12+LV_TWIN]
    mov     eax, [rax+r14*4]            # t2 = twin(p)
    test    eax, eax
    js      2f
    shl     eax, 2
2:  mov     [r9+r8*4+12], eax
    mov     rsi, r12                    # vcorner' of the edge / face points
    mov     edi, ebx
    call    owner
    test    eax, eax
    jz      3f
    mov     rax, [r13+LV_VC]
    mov     ecx, [r12+LV_V]
    add     ecx, [rsp+8]
    lea     edx, [rbx*4+1]
    mov     [rax+rcx*4], edx
3:  mov     rsi, r12
    mov     edi, r15d
    call    g_first
    cmp     eax, ebx
    jne     4f
    mov     rax, [r13+LV_VC]
    mov     ecx, [r12+LV_V]
    add     ecx, [r12+LV_E]
    add     ecx, r15d
    lea     edx, [rbx*4+2]
    mov     [rax+rcx*4], edx
4:  inc     ebx
    jmp     .Ljt_c
.Ljt_out:
    add     rsp, 24
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# j_vc(ctx, esi, edx) - old vertices keep their corner (times 4)
j_vc:
    mov     r8, [rip+jlv]
    mov     r9, [rip+jnx]
    mov     r8, [r8+LV_VC]
    mov     r9, [r9+LV_VC]
1:  cmp     esi, edx
    jae     2f
    mov     eax, [r8+rsi*4]
    test    eax, eax
    js      11f
    shl     eax, 2
11: mov     [r9+rsi*4], eax
    inc     esi
    jmp     1b
2:  ret

# j_out(ctx, esi, edx) - last level corners -> output quads, triangles,
#   polygons of the triangles, edges
j_out:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 40
    mov     ebx, esi
    mov     [rsp], edx
    mov     r12, [rip+jlv]
    mov     r13, [rip+jout]
.Ljo_c:
    cmp     ebx, [rsp]
    jae     .Ljo_out
    mov     rsi, r12
    mov     edi, ebx
    call    g_prev
    mov     r14d, eax                   # p
    mov     rsi, r12
    mov     edi, ebx
    call    g_face
    mov     r15d, eax                   # f
    mov     rax, [r12+LV_LOOPS]
    mov     ebp, [rax+rbx*4]            # v
    mov     rax, [r12+LV_EID]
    mov     ecx, [rax+rbx*4]            # e
    mov     [rsp+8], ecx
    mov     edx, [rax+r14*4]            # ep
    mov     eax, [r12+LV_V]
    lea     r8d, [rax+rcx]              # E_c
    lea     r9d, [rax+rdx]              # E_p
    add     eax, [r12+LV_E]
    lea     r10d, [rax+r15]             # F
    mov     rax, [r13+ME_LOOPS]         # the quad c
    lea     r11d, [rbx*4]
    mov     [rax+r11*4], ebp
    mov     [rax+r11*4+4], r8d
    mov     [rax+r11*4+8], r10d
    mov     [rax+r11*4+12], r9d
    mov     rax, [r13+ME_POFF]
    mov     [rax+rbx*4], r11d
    mov     rax, [r13+ME_TRIS]          # (v, Ec, F), (v, F, Ep)
    lea     r11, [rbx+rbx*2]
    shl     r11, 3                      # 24 bytes per quad
    mov     [rax+r11], ebp
    mov     [rax+r11+4], r8d
    mov     [rax+r11+8], r10d
    mov     [rax+r11+12], ebp
    mov     [rax+r11+16], r10d
    mov     [rax+r11+20], r9d
    mov     rax, [r13+ME_TPOLY]
    mov     [rax+rbx*8], ebx
    mov     [rax+rbx*8+4], ebx
    mov     rax, [r13+ME_EDGES]         # edge 2E + c = (Ec, F)
    mov     ecx, [r12+LV_E]
    add     ecx, ecx
    add     ecx, ebx
    mov     [rax+rcx*8], r8d
    mov     [rax+rcx*8+4], r10d
    mov     [rsp+16], r8d
    mov     rsi, r12
    mov     edi, ebx
    call    owner
    test    eax, eax
    jz      1f
    mov     rsi, r12                    # halves 2e (v, Ec), 2e+1 (Ec, next v)
    mov     edi, ebx
    call    g_next
    mov     rcx, [r12+LV_LOOPS]
    mov     edx, [rcx+rax*4]
    mov     rax, [r13+ME_EDGES]
    mov     ecx, [rsp+8]
    add     ecx, ecx
    mov     r8d, [rsp+16]
    mov     [rax+rcx*8], ebp
    mov     [rax+rcx*8+4], r8d
    mov     [rax+rcx*8+8], r8d
    mov     [rax+rcx*8+12], edx
1:  inc     ebx
    jmp     .Ljo_c
.Ljo_out:
    add     rsp, 40
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Positions (every evaluation)
# =============================================================================
# positions(rbx=entry) - level by level: face, edge and vertex points; then
#   the output's bounding box
positions:
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    xor     r14d, r14d                  # displacements so far
    mov     dword ptr [rip+ss_off], 0
    mov     dword ptr [rip+ss_total], 0
    xor     r12d, r12d                  # k
1:  cmp     r12d, [rbx+SE_LEVELS]
    jae     2f
    imul    eax, r12d, LV_SZ
    lea     r13, [rbx+SE_LV+rax]
    mov     [rip+jlv], r13
    mov     rax, [rbx+SE_POS+r12*8]
    mov     [rip+jpin], rax
    mov     rax, [rbx+SE_POS+r12*8+8]
    mov     [rip+jpout], rax
    lea     rdi, [rip+j_fp]
    xor     esi, esi
    mov     edx, [r13+LV_F]
    mov     ecx, GRAIN
    call    parallel_for
    lea     rdi, [rip+j_ep]
    xor     esi, esi
    mov     edx, [r13+LV_L]
    mov     ecx, GRAIN
    call    parallel_for
    lea     rdi, [rip+j_vp]
    xor     esi, esi
    mov     edx, [r13+LV_V]
    mov     ecx, GRAIN
    call    parallel_for
    mov     eax, [r13+LV_V]             # level k+1's vertices: V + E + F
    add     eax, [r13+LV_E]
    add     eax, [r13+LV_F]
    mov     [rip+ss_off], r14d
    add     r14d, eax
    mov     [rip+ss_total], r14d
    cmp     qword ptr [rip+ss_mr], 0
    je      11f
    mov     edi, eax
    mov     rsi, [rbx+SE_POS+r12*8+8]
    call    displace
11: inc     r12d
    jmp     1b
2:  mov     rdi, [rbx+SE_OUT]           # bounding box, versions
    call    out_bbox
    mov     rax, [rbx+SE_OUT]
    inc     dword ptr [rax+ME_VER]
    add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    ret

# displace(edi=vertices, rsi=their positions; ss_off: where their
#   displacements start) - multires: + D (when they are all there), or fit:
#   D = target - position, position = target
displace:
    mov     ecx, [rip+ss_off]
    mov     rdx, [rip+ss_disp]
    test    rdx, rdx
    jz      9f
    lea     eax, [rcx+rdi]
    cmp     eax, [rip+ss_dispn]
    ja      9f
    lea     rcx, [rcx+rcx*2]
    lea     rdx, [rdx+rcx*4]            # this level's D
    lea     ecx, [rdi+rdi*2]            # floats
    mov     r8, [rip+ss_fit]
    test    r8, r8
    jnz     2f
1:  test    ecx, ecx
    jz      9f
    dec     ecx
    movss   xmm0, [rsi+rcx*4]
    addss   xmm0, [rdx+rcx*4]
    movss   [rsi+rcx*4], xmm0
    jmp     1b
2:  test    ecx, ecx
    jz      9f
    dec     ecx
    movss   xmm0, [r8+rcx*4]
    movss   xmm1, xmm0
    subss   xmm1, [rsi+rcx*4]
    movss   [rdx+rcx*4], xmm1
    movss   [rsi+rcx*4], xmm0
    jmp     2b
9:  ret

# j_fp - face points at V + E + f (average of the face's vertices)
j_fp:
    push    rbx
    push    r12
    push    r13
    mov     ebx, esi
    mov     r12d, edx
    mov     r13, [rip+jlv]
1:  cmp     ebx, r12d
    jae     9f
    mov     rsi, r13
    mov     edi, ebx
    call    g_first
    mov     ecx, eax                    # first corner
    mov     edx, 4                      # count
    cmp     dword ptr [r13+LV_QUAD], 0
    jne     2f
    mov     rax, [r13+LV_POFF]
    mov     edx, [rax+rbx*4+4]
    sub     edx, ecx
2:  xorps   xmm0, xmm0
    xorps   xmm1, xmm1
    xorps   xmm2, xmm2
    mov     r8, [r13+LV_LOOPS]
    mov     r9, [rip+jpin]
    mov     r10d, edx
3:  test    r10d, r10d
    jz      4f
    mov     eax, [r8+rcx*4]
    lea     rax, [rax+rax*2]
    addss   xmm0, [r9+rax*4]
    addss   xmm1, [r9+rax*4+4]
    addss   xmm2, [r9+rax*4+8]
    inc     ecx
    dec     r10d
    jmp     3b
4:  cvtsi2ss xmm3, edx
    divss   xmm0, xmm3
    divss   xmm1, xmm3
    divss   xmm2, xmm3
    mov     eax, [r13+LV_V]
    add     eax, [r13+LV_E]
    add     eax, ebx
    lea     rax, [rax+rax*2]
    mov     r9, [rip+jpout]
    movss   [r9+rax*4], xmm0
    movss   [r9+rax*4+4], xmm1
    movss   [r9+rax*4+8], xmm2
    inc     ebx
    jmp     1b
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# j_ep - edge points at V + e (owner corners): (a + b + F1 + F2) / 4, or the
#   midpoint on boundaries
j_ep:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     ebx, esi
    mov     r12d, edx
    mov     r13, [rip+jlv]
1:  cmp     ebx, r12d
    jae     9f
    mov     rax, [r13+LV_TWIN]
    mov     r14d, [rax+rbx*4]           # t
    test    r14d, r14d
    js      2f
    cmp     ebx, r14d
    ja      8f                          # not the owner
2:  mov     rsi, r13
    mov     edi, ebx
    call    g_next
    mov     rcx, [r13+LV_LOOPS]
    mov     edx, [rcx+rax*4]            # b
    mov     eax, [rcx+rbx*4]            # a
    mov     r9, [rip+jpin]
    lea     rax, [rax+rax*2]
    lea     rdx, [rdx+rdx*2]
    movss   xmm0, [r9+rax*4]
    addss   xmm0, [r9+rdx*4]
    movss   xmm1, [r9+rax*4+4]
    addss   xmm1, [r9+rdx*4+4]
    movss   xmm2, [r9+rax*4+8]
    addss   xmm2, [r9+rdx*4+8]
    test    r14d, r14d
    js      3f
    mov     rsi, r13                    # + both face points, / 4
    mov     edi, ebx
    call    g_face
    mov     ecx, eax
    mov     rsi, r13
    mov     edi, r14d
    call    g_face
    mov     edx, [r13+LV_V]
    add     edx, [r13+LV_E]
    mov     r9, [rip+jpout]
    lea     ecx, [rcx+rdx]
    lea     eax, [rax+rdx]
    lea     rcx, [rcx+rcx*2]
    lea     rax, [rax+rax*2]
    addss   xmm0, [r9+rcx*4]
    addss   xmm1, [r9+rcx*4+4]
    addss   xmm2, [r9+rcx*4+8]
    addss   xmm0, [r9+rax*4]
    addss   xmm1, [r9+rax*4+4]
    addss   xmm2, [r9+rax*4+8]
    mulss   xmm0, [rip+sf_quarter]
    mulss   xmm1, [rip+sf_quarter]
    mulss   xmm2, [rip+sf_quarter]
    jmp     4f
3:  mulss   xmm0, [rip+sf_half]
    mulss   xmm1, [rip+sf_half]
    mulss   xmm2, [rip+sf_half]
4:  mov     rax, [r13+LV_EID]
    mov     eax, [rax+rbx*4]
    add     eax, [r13+LV_V]
    lea     rax, [rax+rax*2]
    mov     r9, [rip+jpout]
    movss   [r9+rax*4], xmm0
    movss   [r9+rax*4+4], xmm1
    movss   [r9+rax*4+8], xmm2
8:  inc     ebx
    jmp     1b
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# j_vp - vertex points: walk the corners around v (twin of prev)
j_vp:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 56
    mov     ebx, esi
    mov     [rsp+48], edx
    mov     r13, [rip+jlv]
.Lvp_v:
    cmp     ebx, [rsp+48]
    jae     .Lvp_out
    mov     r9, [rip+jpin]
    lea     rax, [rbx+rbx*2]
    lea     r10, [r9+rax*4]             # S
    mov     r9, [rip+jpout]
    lea     r11, [r9+rax*4]             # out
    mov     [rsp+40], r11
    mov     [rsp+32], r10
    mov     rax, [r13+LV_VC]
    mov     r12d, [rax+rbx*4]           # c0
    test    r12d, r12d
    js      .Lvp_copy
    # find a boundary corner going the other way: c -> next(twin(c))
    mov     r14d, r12d
    xor     ebp, ebp
1:  mov     rax, [r13+LV_TWIN]
    mov     eax, [rax+r14*4]
    test    eax, eax
    js      .Lvp_boundary               # r14 starts at a boundary edge
    mov     rsi, r13
    mov     edi, eax
    call    g_next
    mov     r14d, eax
    cmp     r14d, r12d
    je      .Lvp_inner
    inc     ebp
    cmp     ebp, 256
    jb      1b
    jmp     .Lvp_copy
.Lvp_inner:                             # closed fan: (Q + 2R + (n-3) S) / n
    xorps   xmm3, xmm3                  # Q
    xorps   xmm4, xmm4
    xorps   xmm5, xmm5
    xorps   xmm6, xmm6                  # R (sum of the far ends; mids below)
    xorps   xmm7, xmm7
    xorps   xmm8, xmm8
    xor     r15d, r15d                  # n
    mov     r14d, r12d
2:  mov     rsi, r13                    # face point
    mov     edi, r14d
    call    g_face
    mov     ecx, [r13+LV_V]
    add     ecx, [r13+LV_E]
    add     ecx, eax
    lea     rcx, [rcx+rcx*2]
    mov     r9, [rip+jpout]
    addss   xmm3, [r9+rcx*4]
    addss   xmm4, [r9+rcx*4+4]
    addss   xmm5, [r9+rcx*4+8]
    mov     rsi, r13                    # the far end of the outgoing edge
    mov     edi, r14d
    call    g_next
    mov     rcx, [r13+LV_LOOPS]
    mov     eax, [rcx+rax*4]
    lea     rax, [rax+rax*2]
    mov     r9, [rip+jpin]
    addss   xmm6, [r9+rax*4]
    addss   xmm7, [r9+rax*4+4]
    addss   xmm8, [r9+rax*4+8]
    inc     r15d
    cmp     r15d, 256
    jae     .Lvp_copy
    mov     rsi, r13                    # next corner: twin(prev(c))
    mov     edi, r14d
    call    g_prev
    mov     rcx, [r13+LV_TWIN]
    mov     r14d, [rcx+rax*4]
    test    r14d, r14d
    js      .Lvp_copy
    cmp     r14d, r12d
    jne     2b
    # V' = (Q + 2R + (n - 3) S) / n with Q = sumF / n and
    # 2R = 2 * mean((S + far) / 2) = (n S + sumFar) / n   (per component)
    movss   [rsp], xmm3                 # sums on this thread's stack
    movss   [rsp+4], xmm4
    movss   [rsp+8], xmm5
    movss   [rsp+12], xmm6
    movss   [rsp+16], xmm7
    movss   [rsp+20], xmm8
    cvtsi2ss xmm9, r15d                 # n
    movss   xmm10, xmm9
    subss   xmm10, [rip+sf_three]       # n - 3
    mov     r10, [rsp+32]
    mov     r11, [rsp+40]
    xor     ecx, ecx
3:  movss   xmm0, [r10+rcx*4]           # S
    movss   xmm1, [rsp+rcx*4]
    divss   xmm1, xmm9                  # Q
    movss   xmm2, xmm0
    mulss   xmm2, xmm9
    addss   xmm2, [rsp+12+rcx*4]
    divss   xmm2, xmm9                  # 2R
    addss   xmm1, xmm2
    movss   xmm2, xmm0
    mulss   xmm2, xmm10
    addss   xmm1, xmm2
    divss   xmm1, xmm9
    movss   [r11+rcx*4], xmm1
    inc     ecx
    cmp     ecx, 3
    jb      3b
    jmp     .Lvp_next
.Lvp_boundary:                          # (6 S + a + b) / 8
    mov     rsi, r13                    # a: far end of r14's outgoing edge
    mov     edi, r14d
    call    g_next
    mov     rcx, [r13+LV_LOOPS]
    mov     eax, [rcx+rax*4]
    mov     [rsp], eax
    xor     ebp, ebp                    # walk to the other boundary
4:  mov     rsi, r13
    mov     edi, r14d
    call    g_prev
    mov     r15d, eax                   # p
    mov     rcx, [r13+LV_TWIN]
    mov     eax, [rcx+r15*4]
    test    eax, eax
    js      5f
    mov     r14d, eax
    inc     ebp
    cmp     ebp, 256
    jb      4b
    jmp     .Lvp_copy
5:  mov     rcx, [r13+LV_LOOPS]         # b: the start of the incoming edge
    mov     eax, [rcx+r15*4]
    mov     edx, [rsp]
    mov     r9, [rip+jpin]
    lea     rax, [rax+rax*2]
    lea     rdx, [rdx+rdx*2]
    mov     r10, [rsp+32]
    mov     r11, [rsp+40]
    xor     ecx, ecx
6:  movss   xmm0, [r10+rcx*4]
    mulss   xmm0, [rip+sf_six]
    addss   xmm0, [r9+rax*4]
    addss   xmm0, [r9+rdx*4]
    mulss   xmm0, [rip+sf_eighth]
    movss   [r11+rcx*4], xmm0
    inc     rax
    inc     rdx
    inc     ecx
    cmp     ecx, 3
    jb      6b
    jmp     .Lvp_next
.Lvp_copy:
    mov     r10, [rsp+32]
    mov     r11, [rsp+40]
    mov     rax, [r10]
    mov     [r11], rax
    mov     eax, [r10+8]
    mov     [r11+8], eax
.Lvp_next:
    inc     ebx
    jmp     .Lvp_v
.Lvp_out:
    add     rsp, 56
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# out_bbox(rdi=mesh) - bounding box (parallel chunks, then reduced)
out_bbox:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    mov     [rip+jout], rdi
    mov     eax, [rbx+ME_NVERTS]
    add     eax, GRAIN-1
    xor     edx, edx
    mov     ecx, GRAIN
    div     ecx
    mov     r12d, eax                   # chunks
    lea     rdi, [rip+frame_arena]
    imul    esi, eax, 32
    add     esi, 32
    call    arena_alloc
    test    rax, rax
    jz      8f
    mov     [rip+jbox], rax
    lea     rdi, [rip+j_box]
    xor     esi, esi
    mov     edx, r12d
    mov     ecx, 1
    call    parallel_for
    movss   xmm0, [rip+sf_big]          # reduce
    movss   xmm1, xmm0
    movss   xmm2, xmm0
    movss   xmm3, [rip+sf_nbig]
    movss   xmm4, xmm3
    movss   xmm5, xmm3
    mov     rax, [rip+jbox]
    xor     ecx, ecx
1:  cmp     ecx, r12d
    jae     2f
    minss   xmm0, [rax]
    minss   xmm1, [rax+4]
    minss   xmm2, [rax+8]
    maxss   xmm3, [rax+12]
    maxss   xmm4, [rax+16]
    maxss   xmm5, [rax+20]
    add     rax, 32
    inc     ecx
    jmp     1b
2:  movss   [rbx+ME_BMIN], xmm0
    movss   [rbx+ME_BMIN+4], xmm1
    movss   [rbx+ME_BMIN+8], xmm2
    movss   [rbx+ME_BMAX], xmm3
    movss   [rbx+ME_BMAX+4], xmm4
    movss   [rbx+ME_BMAX+8], xmm5
    jmp     9f
8:  mov     rdi, rbx
    call    mesh_bbox
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# j_box(ctx, esi=first chunk, edx=end)
j_box:
    push    rbx
    mov     r8, [rip+jout]
    mov     r9, [r8+ME_POS]
    mov     r10d, [r8+ME_NVERTS]
1:  cmp     esi, edx
    jae     9f
    movss   xmm0, [rip+sf_big]
    movss   xmm1, xmm0
    movss   xmm2, xmm0
    movss   xmm3, [rip+sf_nbig]
    movss   xmm4, xmm3
    movss   xmm5, xmm3
    mov     eax, esi
    imul    eax, eax, GRAIN
    lea     ebx, [rax+GRAIN]
    cmp     ebx, r10d
    cmova   ebx, r10d
2:  cmp     eax, ebx
    jae     3f
    lea     rcx, [rax+rax*2]
    minss   xmm0, [r9+rcx*4]
    minss   xmm1, [r9+rcx*4+4]
    minss   xmm2, [r9+rcx*4+8]
    maxss   xmm3, [r9+rcx*4]
    maxss   xmm4, [r9+rcx*4+4]
    maxss   xmm5, [r9+rcx*4+8]
    inc     eax
    jmp     2b
3:  mov     rax, [rip+jbox]
    mov     ecx, esi
    shl     ecx, 5
    movss   [rax+rcx], xmm0
    movss   [rax+rcx+4], xmm1
    movss   [rax+rcx+8], xmm2
    movss   [rax+rcx+12], xmm3
    movss   [rax+rcx+16], xmm4
    movss   [rax+rcx+20], xmm5
    inc     esi
    jmp     1b
9:  pop     rbx
    ret


.section .note.GNU-stack,"",@progbits
