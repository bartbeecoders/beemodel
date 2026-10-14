# =============================================================================
#  BeeModel - virtualized geometry, part 1: the cluster LOD DAG.
#
#  vgeo.build turns a mesh into meshlets (clusters of <= 128 triangles and
#  <= 64 vertices grown over their neighbours, seeded in Morton order), then,
#  level by level, groups neighbouring clusters (up to 8, by shared edges),
#  simplifies each group to half its triangles (quadric error, half-edge
#  collapses, the group's border locked) and splits it into new clusters -
#  until one cluster is left or a level no longer shrinks.
#
#  Every cluster keeps its bounds, the error and LOD sphere of the group that
#  made it and those of the group it was simplified in: errors only grow up
#  the DAG and the spheres nest, so any cut "error <= t < parent error"
#  (projected from a camera or not) is crack-free. Positions are welded on a
#  2^20 grid over the mesh's extent; a collapse keeps one of its vertices, so
#  every level uses the original vertices and borders match exactly.
#
#  The DAG is one block: a header, the clusters (64 B), groups (48 B) and
#  their member lists, then the page-aligned cluster data - per cluster its
#  vertices (i32 grid x y z + an octahedral normal) and triangles (u8 x 3).
#  A mesh's copies share it (ME_VGEO, reference counted); it is saved in a
#  VGEO chunk whose block starts on a page of the .bee file. In the window it
#  is built on a background thread.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

.globl vg_build_mesh
.globl vg_get
.globl vg_ref
.globl vg_unref
.globl vg_attach
.globl vg_select
.globl vg_edges
.globl vg_check
.globl vg_info
.globl vg_tick
.globl vg_state
.globl vg_async
.globl vgeo_read
.globl vg_zero
.globl vg_selftest

# the block
.equ VG_MAGIC,  0x4F454756              # "VGEO"
.equ VG_VERSION, 1
.equ VH_MAGIC,  0
.equ VH_VER,    4
.equ VH_REFS,   8
.equ VH_NCL,    12
.equ VH_NGR,    16
.equ VH_NLV,    20
.equ VH_STRI,   24                      # source triangles (welded, no degenerate)
.equ VH_SVERT,  28                      # welded vertices
.equ VH_BMIN,   32                      # f32 x 3: the grid's origin
.equ VH_STEP,   44                      # f32: its spacing
.equ VH_HASH,   48                      # the mesh it was built from
.equ VH_MS,     56                      # build time
.equ VH_TTRI,   60                      # triangles in all clusters
.equ VH_NMEM,   64
.equ VH_ROOTS,  68
.equ VH_OCL,    72                      # u64 offsets in the block
.equ VH_OGR,    80
.equ VH_OMEM,   88
.equ VH_ODATA,  96
.equ VH_DBYTES, 104
.equ VH_BYTES,  112
.equ VH_RERR,   120                     # f32: the largest error
.equ VH_LV,     128                     # per level: first cluster, clusters,
.equ VH_SZ,     512                     #   triangles, largest error
.equ VG_MAXLV,  24

.equ CR_C,      0                       # bounds: centre, radius
.equ CR_LOD,    16                      # LOD sphere (of the group that made it)
.equ CR_PLOD,   32                      # parent LOD sphere (the group it is in)
.equ CR_ERR,    48
.equ CR_PERR,   52                      # FLT_MAX for roots
.equ CR_DATA,   56                      # data offset / 16
.equ CR_NV,     60                      # u8
.equ CR_NT,     61                      # u8
.equ CR_LEVEL,  62                      # u8
.equ CR_SZ,     64

.equ GR_MEM,    0                       # first member (index into members)
.equ GR_NMEM,   4
.equ GR_PAR,    8                       # first cluster it made
.equ GR_NPAR,   12
.equ GR_ERR,    16
.equ GR_LOD,    20                      # sphere
.equ GR_LEVEL,  36
.equ GR_SZ,     48

# build-time cluster info
.equ CB_TOFF,   0                       # first triangle in bt
.equ CB_NT,     4
.equ CB_NV,     8
.equ CB_GRP,    12                      # group it is a member of + 1
.equ CB_SZ,     16

.equ CL_TRIS,   128
.equ CL_VERTS,  128
.equ BLK,       4096                    # level 0 is partitioned in blocks
.equ NCAND,     1024
.equ VM_MAX,    256
.equ MAP_NORES, 0x4022
.equ MAP_ANON_PRIV, 0x22
.equ SYS_CLOCK_GETTIME, 228

.section .bss
.align 16
vm_list:        .skip 16*VM_MAX         # the builder's mappings (pointer, bytes)
vm_n:           .skip 4
vg_state:       .skip 4                 # 0 idle, 1 building, 2 built (to attach)
vg_async:       .skip 4                 # the window: build in the background
vg_fail:        .skip 4
vg_mesh:        .skip 8                 # the mesh being built (referenced)
vg_out:         .skip 8                 # the block made
vg_t0:          .skip 8
vg_ts:          .skip 16
# snapshot
s_nv:           .skip 4
s_nt:           .skip 4
s_pos:          .skip 8
s_tri:          .skip 8
s_hash:         .skip 8
# welded
w_n:            .skip 4
w_q:            .skip 8                 # i32 x 3 per vertex
w_nrm:          .skip 8                 # f32 x 3
.align 16
bmin:           .skip 16
step:           .skip 4
inv:            .skip 4
# levels
bt:             .skip 8                 # u32 x 3 per triangle (welded ids)
bt_n:           .skip 4
nt0:            .skip 4
cr:             .skip 8
cb:             .skip 8
nc:             .skip 4
gr:             .skip 8
ng:             .skip 4
mem:            .skip 8
nm:             .skip 4
csrc:           .skip 8                 # per cluster: the group that made it + 1
nlv:            .skip 4
lv:             .skip 16*VG_MAXLV
# per level (temporary)
lo:             .skip 4                 # the level's clusters [lo, hi)
hi:             .skip 4
glo:            .skip 4                 # its groups [glo, ghi)
ghi:            .skip 4
be_mode:        .skip 4
ebn:            .skip 8                 # boundary edges per cluster
eoff:           .skip 8
eb:             .skip 8
gin:            .skip 8                 # per group: offset of its triangles
gonc:           .skip 8                 #   clusters made
gont:           .skip 8                 #   triangles kept
goerr:          .skip 8                 #   simplification error
ot:             .skip 8                 # the triangles the groups made
os:             .skip 8                 # their clusters' sizes
blk_nc:         .skip 8
morton:         .skip 8
bnd_first:      .skip 4
pk_block:       .skip 8
bg_g:           .skip 4
bg_n:           .skip 4
bg_mem:         .skip 4*64
count:          .skip 4*1024
cid:            .skip 4*512             # grouping candidates
csc:            .skip 4*512
.align 4096
vg_zero:        .skip 4096

.section .rodata
.align 16
f_big4:         .float 1.0e30, 1.0e30, 1.0e30, 1.0e30
f_nbig4:        .float -1.0e30, -1.0e30, -1.0e30, -1.0e30
f_half4:        .float 0.5, 0.5, 0.5, 0.5
f_absm:         .long 0x7fffffff, 0x7fffffff, 0x7fffffff, 0x7fffffff
f_qscale:       .float 1048576.0
f_one:          .float 1.0
f_grow:         .float 1.00001
f_maxf:         .long 0x7f7fffff
f_tiny:         .float 1.0e-6
f_32767:        .float 32767.0
f_shrink:       .float 0.95
f_thousand:     .float 1000.0
.align 16
f_minus1i:      .long -1, -1, -1, -1
f_sign:         .long 0x80000000, 0x80000000, 0x80000000, 0x80000000
d_zero:         .double 0.0
d_half:         .double 0.5

.text

# =============================================================================
#  Helpers
# =============================================================================
# vmap(rdi=bytes) -> rax = zeroed pages (reserved, remembered; 0: none)
vmap:
    push    rbx
    lea     rsi, [rdi+4095]
    and     rsi, -4096
    jnz     1f
    mov     esi, 4096
1:  mov     rbx, rsi
    cmp     dword ptr [rip+vm_n], VM_MAX
    jae     8f
    xor     edi, edi
    mov     edx, PROT_RW
    mov     r10d, MAP_NORES
    mov     r8, -1
    xor     r9d, r9d
    mov     eax, SYS_MMAP
    syscall
    cmp     rax, -4096
    jae     8f
    mov     ecx, [rip+vm_n]
    shl     ecx, 4
    lea     rdx, [rip+vm_list]
    mov     [rdx+rcx], rax
    mov     [rdx+rcx+8], rbx
    inc     dword ptr [rip+vm_n]
    pop     rbx
    ret
8:  mov     dword ptr [rip+vg_fail], 1
    xor     eax, eax
    pop     rbx
    ret

# vfree_to(edi=count) - unmap the mappings made after the first count
vfree_to:
    push    rbx
    mov     ebx, edi
1:  mov     ecx, [rip+vm_n]
    cmp     ecx, ebx
    jbe     9f
    dec     ecx
    mov     [rip+vm_n], ecx
    shl     ecx, 4
    lea     rdx, [rip+vm_list]
    mov     rdi, [rdx+rcx]
    mov     rsi, [rdx+rcx+8]
    mov     eax, SYS_MUNMAP
    syscall
    jmp     1b
9:  pop     rbx
    ret

# zalloc(rdi=arena, rsi=bytes) -> rax = zeroed block from a scratch arena
#   (rdi kept)
zalloc:
    push    rdi
    push    rsi
    add     rsi, 15
    and     rsi, -16
    call    arena_alloc
    pop     rcx
    pop     rdi
    test    rax, rax
    jz      9f
    push    rdi
    mov     rdi, rax
    mov     rdx, rax
    add     rcx, 7
    shr     rcx, 3
    xor     eax, eax
    rep     stosq
    mov     rax, rdx
    pop     rdi
9:  ret

# mix(rax) -> rax: a 64-bit finaliser (rcx clobbered)
mix:
    mov     rcx, rax
    shr     rcx, 30
    xor     rax, rcx
    mov     rcx, 0xbf58476d1ce4e5b9
    imul    rax, rcx
    mov     rcx, rax
    shr     rcx, 27
    xor     rax, rcx
    mov     rcx, 0x94d049bb133111eb
    imul    rax, rcx
    mov     rcx, rax
    shr     rcx, 31
    xor     rax, rcx
    ret

# now_ms -> rax = monotonic milliseconds
now_ms:
    mov     edi, 1
    lea     rsi, [rip+vg_ts]
    mov     eax, SYS_CLOCK_GETTIME
    syscall
    mov     rax, [rip+vg_ts]
    imul    rax, rax, 1000
    mov     rcx, rax
    mov     rax, [rip+vg_ts+8]
    xor     edx, edx
    mov     r8d, 1000000
    div     r8
    add     rax, rcx
    ret

# pfor(rdi=fn, esi=count, edx=batch, ecx=grain) - parallel_for in batches
#   (the window draws between them); fn gets rdi = the batch's first index
pfor:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rbx, rdi
    mov     r12d, esi
    mov     r13d, edx
    mov     r15d, ecx
    xor     r14d, r14d
1:  cmp     r14d, r12d
    jae     9f
    mov     edx, r12d
    sub     edx, r14d
    cmp     edx, r13d
    cmova   edx, r13d
    mov     rdi, rbx
    mov     esi, r14d
    mov     ecx, r15d
    add     r14d, edx
    call    parallel_for_at
    jmp     1b
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# parallel_for_at(rdi=fn, esi=first, edx=count, ecx=grain)
parallel_for_at:
    mov     r8d, esi
    mov     rsi, r8                     # ctx = the first index
    jmp     parallel_for

# =============================================================================
#  Snapshot and weld
# =============================================================================
# vg_snap(rdi=mesh) -> eax = 1: its positions and triangles copied (on the
#   thread that owns the scene)
vg_snap:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    mov     dword ptr [rip+vg_fail], 0
    mov     eax, [rbx+ME_NVERTS]
    mov     [rip+s_nv], eax
    cmp     eax, 3
    jb      8f
    mov     eax, [rbx+ME_NTRIS]
    mov     [rip+s_nt], eax
    test    eax, eax
    jz      8f
    mov     edi, [rip+s_nv]
    imul    rdi, rdi, 12
    add     rdi, 64
    call    vmap
    test    rax, rax
    jz      8f
    mov     [rip+s_pos], rax
    mov     rdi, rax
    mov     rsi, [rbx+ME_POS]
    mov     ecx, [rip+s_nv]
    imul    rcx, rcx, 12
    rep     movsb
    mov     edi, [rip+s_nt]
    imul    rdi, rdi, 12
    add     rdi, 64
    call    vmap
    test    rax, rax
    jz      8f
    mov     [rip+s_tri], rax
    mov     rdi, rax
    mov     rsi, [rbx+ME_TRIS]
    mov     ecx, [rip+s_nt]
    imul    rcx, rcx, 12
    rep     movsb
    mov     rax, 0xcbf29ce484222325
    mov     rdi, rbx
    call    sc_meshhash
    mov     [rip+s_hash], rax
    mov     eax, 1
    jmp     9f
8:  xor     edi, edi
    call    vfree_to
    xor     eax, eax
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# bd_weld -> eax = 1: the grid, welded vertices (w_q), their normals, the
#   level 0 triangles (bt, nt0: no degenerate ones) - 0: nothing left
bd_weld:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 56
    mov     r12, [rip+s_pos]
    mov     r13d, [rip+s_nv]
    movaps  xmm6, [rip+f_big4]          # bounds
    movaps  xmm7, [rip+f_nbig4]
    xor     ecx, ecx
1:  lea     rax, [rcx+rcx*2]
    movups  xmm0, [r12+rax*4]
    minps   xmm6, xmm0
    maxps   xmm7, xmm0
    inc     ecx
    cmp     ecx, r13d
    jb      1b
    movaps  [rip+bmin], xmm6
    subps   xmm7, xmm6
    movaps  xmm0, xmm7
    movaps  xmm1, xmm7
    shufps  xmm1, xmm1, 0x55
    maxss   xmm0, xmm1
    movaps  xmm1, xmm7
    shufps  xmm1, xmm1, 0xaa
    maxss   xmm0, xmm1
    divss   xmm0, [rip+f_qscale]        # 2^20 steps over the largest side
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    ja      2f
    movss   xmm0, [rip+f_one]
2:  movss   [rip+step], xmm0
    movss   xmm1, [rip+f_one]
    divss   xmm1, xmm0
    movss   [rip+inv], xmm1
    mov     ebx, 1024                   # weld table: >= 2 slots a vertex
3:  mov     eax, r13d
    add     eax, eax
    cmp     ebx, eax
    jae     4f
    add     ebx, ebx
    jmp     3b
4:  lea     eax, [rbx-1]
    mov     [rsp+24], rax               # mask
    mov     edi, ebx
    shl     rdi, 2
    call    vmap
    mov     [rsp], rax                  # table: id + 1
    mov     edi, r13d
    shl     rdi, 3
    call    vmap
    mov     [rsp+8], rax                # keys of the welded vertices
    mov     edi, r13d
    shl     rdi, 2
    call    vmap
    mov     [rsp+16], rax               # remap
    mov     edi, r13d
    imul    rdi, rdi, 12
    add     rdi, 64
    call    vmap
    mov     [rip+w_q], rax
    cmp     dword ptr [rip+vg_fail], 0
    jne     .Lw_fail
    mov     dword ptr [rip+w_n], 0
    movaps  xmm6, [rip+bmin]
    movss   xmm5, [rip+inv]
    shufps  xmm5, xmm5, 0
    xor     r14d, r14d                  # vertex
5:  cmp     r14d, r13d
    jae     .Lw_tris
    lea     rax, [r14+r14*2]
    movups  xmm0, [r12+rax*4]
    subps   xmm0, xmm6
    mulps   xmm0, xmm5
    cvtps2dq xmm0, xmm0
    pxor    xmm1, xmm1                  # (never below the grid)
    pmaxsd  xmm0, xmm1
    movd    eax, xmm0
    pextrd  edx, xmm0, 1
    pextrd  r8d, xmm0, 2
    shl     rdx, 21
    shl     r8, 42
    or      rax, rdx
    or      rax, r8
    mov     r15, rax                    # key
    call    mix
    and     rax, [rsp+24]
    mov     rdi, [rsp]
    mov     rsi, [rsp+8]
6:  mov     r10d, [rdi+rax*4]
    test    r10d, r10d
    jz      7f
    dec     r10d
    cmp     [rsi+r10*8], r15
    je      8f
    inc     rax
    and     rax, [rsp+24]
    jmp     6b
7:  mov     r10d, [rip+w_n]             # a new vertex
    lea     ecx, [r10+1]
    mov     [rdi+rax*4], ecx
    mov     [rip+w_n], ecx
    mov     [rsi+r10*8], r15
    mov     rcx, [rip+w_q]
    lea     rdx, [r10+r10*2]
    movq    [rcx+rdx*4], xmm0
    pextrd  [rcx+rdx*4+8], xmm0, 2
8:  mov     rcx, [rsp+16]
    mov     [rcx+r14*4], r10d
    inc     r14d
    jmp     5b
.Lw_tris:                               # the triangles on welded vertices
    mov     edi, [rip+s_nt]
    imul    rdi, rdi, 12
    add     rdi, 64
    call    vmap
    mov     [rip+bt], rax
    mov     edi, [rip+w_n]
    imul    rdi, rdi, 12
    add     rdi, 64
    call    vmap
    mov     [rip+w_nrm], rax
    cmp     dword ptr [rip+vg_fail], 0
    jne     .Lw_fail
    mov     rsi, [rip+s_tri]
    mov     rdi, [rip+bt]
    mov     r8, [rsp+16]
    xor     ecx, ecx
    xor     edx, edx                    # kept
1:  cmp     ecx, [rip+s_nt]
    jae     2f
    lea     rax, [rcx+rcx*2]
    mov     r9d, [rsi+rax*4]
    mov     r10d, [rsi+rax*4+4]
    mov     r11d, [rsi+rax*4+8]
    inc     ecx
    cmp     r9d, r13d                   # (out of range: skipped)
    jae     1b
    cmp     r10d, r13d
    jae     1b
    cmp     r11d, r13d
    jae     1b
    mov     r9d, [r8+r9*4]
    mov     r10d, [r8+r10*4]
    mov     r11d, [r8+r11*4]
    cmp     r9d, r10d
    je      1b
    cmp     r10d, r11d
    je      1b
    cmp     r9d, r11d
    je      1b
    lea     rax, [rdx+rdx*2]
    mov     [rdi+rax*4], r9d
    mov     [rdi+rax*4+4], r10d
    mov     [rdi+rax*4+8], r11d
    inc     edx
    jmp     1b
2:  mov     [rip+nt0], edx
    test    edx, edx
    jz      .Lw_fail
    mov     rsi, [rip+bt]               # normals: the faces' (area weighted)
    mov     rdi, [rip+w_q]
    mov     r8, [rip+w_nrm]
    xor     ecx, ecx
3:  cmp     ecx, [rip+nt0]
    jae     4f
    lea     rax, [rcx+rcx*2]
    mov     r9d, [rsi+rax*4]
    mov     r10d, [rsi+rax*4+4]
    mov     r11d, [rsi+rax*4+8]
    lea     r9, [r9+r9*2]
    lea     r10, [r10+r10*2]
    lea     r11, [r11+r11*2]
    movdqu  xmm2, [rdi+r9*4]
    movdqu  xmm0, [rdi+r10*4]
    movdqu  xmm1, [rdi+r11*4]
    psubd   xmm0, xmm2
    psubd   xmm1, xmm2
    cvtdq2ps xmm0, xmm0
    cvtdq2ps xmm1, xmm1
    call    cross
    movups  xmm0, [r8+r9*4]
    addps   xmm0, xmm2
    movq    [r8+r9*4], xmm0
    extractps [r8+r9*4+8], xmm0, 2
    movups  xmm0, [r8+r10*4]
    addps   xmm0, xmm2
    movq    [r8+r10*4], xmm0
    extractps [r8+r10*4+8], xmm0, 2
    movups  xmm0, [r8+r11*4]
    addps   xmm0, xmm2
    movq    [r8+r11*4], xmm0
    extractps [r8+r11*4+8], xmm0, 2
    inc     ecx
    jmp     3b
4:  mov     eax, 1
    jmp     9f
.Lw_fail:
    xor     eax, eax
9:  add     rsp, 56
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# cross(xmm0=a, xmm1=b) -> xmm2 = a x b (xmm0, xmm1, xmm3 clobbered)
cross:
    movaps  xmm2, xmm0
    shufps  xmm2, xmm2, 0xc9            # a.yzx
    movaps  xmm3, xmm1
    shufps  xmm3, xmm3, 0xd2            # b.zxy
    mulps   xmm2, xmm3
    shufps  xmm0, xmm0, 0xd2            # a.zxy
    shufps  xmm1, xmm1, 0xc9            # b.yzx
    mulps   xmm0, xmm1
    subps   xmm2, xmm0
    ret

# bd_alloc -> eax = 1: the level arrays, reserved for the worst case (only
#   what is used is ever touched)
bd_alloc:
    push    rbx
    mov     ebx, [rip+nt0]
    imul    rbx, rbx, 21
    add     rbx, 64                     # triangles / clusters over all levels
    mov     rax, [rip+bt]               # level 0 stays where it is
    mov     rdi, rbx
    imul    rdi, rdi, 12
    call    vmap
    test    rax, rax
    jz      8f
    mov     rsi, [rip+bt]               # (copied: the weld's block is small)
    mov     rdi, rax
    mov     [rip+bt], rax
    mov     ecx, [rip+nt0]
    imul    rcx, rcx, 12
    rep     movsb
    mov     rdi, rbx
    shl     rdi, 6
    call    vmap
    mov     [rip+cr], rax
    mov     rdi, rbx
    shl     rdi, 4
    call    vmap
    mov     [rip+cb], rax
    mov     rdi, rbx
    imul    rdi, rdi, GR_SZ
    call    vmap
    mov     [rip+gr], rax
    lea     rdi, [rbx*4]
    call    vmap
    mov     [rip+mem], rax
    lea     rdi, [rbx*4]
    call    vmap
    mov     [rip+csrc], rax
    xor     eax, eax
    mov     [rip+nc], eax
    mov     [rip+ng], eax
    mov     [rip+nm], eax
    mov     [rip+nlv], eax
    cmp     [rip+vg_fail], eax
    sete    al
8:  pop     rbx
    ret

# =============================================================================
#  Level 0: triangles in Morton order, partitioned in blocks
# =============================================================================
# spread10(eax) -> eax: bits 0..9 to every third bit
spread10:
    and     eax, 0x3ff
    mov     ecx, eax
    shl     ecx, 16
    or      eax, ecx
    and     eax, 0x030000ff
    mov     ecx, eax
    shl     ecx, 8
    or      eax, ecx
    and     eax, 0x0300f00f
    mov     ecx, eax
    shl     ecx, 4
    or      eax, ecx
    and     eax, 0x030c30c3
    mov     ecx, eax
    shl     ecx, 2
    or      eax, ecx
    and     eax, 0x09249249
    ret

# radix10(rdi=src u64, rsi=dst, edx=n, ecx=shift, r8=1024 counters) -
#   stable, by 10 bits
radix10:
    push    rbx
    push    r12
    push    r13
    mov     r12, rdi
    mov     r13, rsi
    mov     r10, r8
    mov     r8d, edx
    mov     rdi, r10
    mov     r9, rcx
    mov     ecx, 1024
    xor     eax, eax
    rep     stosd
    mov     rcx, r9
    xor     r11d, r11d
1:  cmp     r11d, r8d
    jae     2f
    mov     rax, [r12+r11*8]
    shr     rax, cl
    and     eax, 1023
    inc     dword ptr [r10+rax*4]
    inc     r11d
    jmp     1b
2:  xor     eax, eax                    # exclusive prefix
    xor     edx, edx
3:  mov     ebx, [r10+rdx*4]
    mov     [r10+rdx*4], eax
    add     eax, ebx
    inc     edx
    cmp     edx, 1024
    jb      3b
    xor     r11d, r11d
4:  cmp     r11d, r8d
    jae     9f
    mov     rbx, [r12+r11*8]
    mov     rax, rbx
    shr     rax, cl
    and     eax, 1023
    mov     edx, [r10+rax*4]
    inc     dword ptr [r10+rax*4]
    mov     [r13+rdx*8], rbx
    inc     r11d
    jmp     4b
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# bd_level0 -> eax = 1: level 0's clusters
bd_level0:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    mov     edi, [rip+nt0]
    shl     rdi, 3
    call    vmap
    mov     r12, rax                    # keys
    mov     edi, [rip+nt0]
    shl     rdi, 3
    call    vmap
    mov     r13, rax
    mov     edi, [rip+nt0]
    imul    rdi, rdi, 12
    call    vmap
    mov     r14, rax                    # (the triangles, reordered)
    cmp     dword ptr [rip+vg_fail], 0
    jne     .Ll0_fail
    mov     rsi, [rip+bt]
    mov     rdi, [rip+w_q]
    xor     ebx, ebx
1:  cmp     ebx, [rip+nt0]              # key: Morton code of the centroid
    jae     2f
    lea     rax, [rbx+rbx*2]
    mov     r8d, [rsi+rax*4]
    mov     r9d, [rsi+rax*4+4]
    mov     r10d, [rsi+rax*4+8]
    lea     r8, [r8+r8*2]
    lea     r9, [r9+r9*2]
    lea     r10, [r10+r10*2]
    movdqu  xmm0, [rdi+r8*4]
    movdqu  xmm1, [rdi+r9*4]
    paddd   xmm0, xmm1
    movdqu  xmm1, [rdi+r10*4]
    paddd   xmm0, xmm1
    psrld   xmm0, 12                    # 3 * 2^20 -> 10 bits
    pextrd  eax, xmm0, 2
    call    spread10
    mov     r15d, eax
    shl     r15d, 2
    pextrd  eax, xmm0, 1
    call    spread10
    add     eax, eax
    or      r15d, eax
    movd    eax, xmm0
    call    spread10
    or      r15d, eax
    shl     r15, 32
    or      r15, rbx
    mov     [r12+rbx*8], r15
    inc     ebx
    jmp     1b
2:  mov     rdi, r12
    mov     rsi, r13
    mov     edx, [rip+nt0]
    mov     ecx, 32
    lea     r8, [rip+count]
    call    radix10
    mov     rdi, r13
    mov     rsi, r12
    mov     edx, [rip+nt0]
    mov     ecx, 42
    lea     r8, [rip+count]
    call    radix10
    mov     rdi, r12
    mov     rsi, r13
    mov     edx, [rip+nt0]
    mov     ecx, 52
    lea     r8, [rip+count]
    call    radix10
    mov     rsi, [rip+bt]               # reorder
    xor     ebx, ebx
3:  cmp     ebx, [rip+nt0]
    jae     4f
    mov     eax, [r13+rbx*8]
    lea     rax, [rax+rax*2]
    lea     rdx, [rbx+rbx*2]
    mov     ecx, [rsi+rax*4]
    mov     [r14+rdx*4], ecx
    mov     ecx, [rsi+rax*4+4]
    mov     [r14+rdx*4+4], ecx
    mov     ecx, [rsi+rax*4+8]
    mov     [r14+rdx*4+8], ecx
    inc     ebx
    jmp     3b
4:  mov     rdi, [rip+bt]
    mov     rsi, r14
    mov     ecx, [rip+nt0]
    imul    rcx, rcx, 12
    rep     movsb
    mov     eax, [rip+nt0]              # blocks
    add     eax, BLK-1
    shr     eax, 12
    mov     r15d, eax
    lea     rdi, [rax*4]
    call    vmap
    mov     [rip+blk_nc], rax
    mov     edi, [rip+nt0]
    shl     rdi, 2
    call    vmap
    mov     [rip+os], rax
    cmp     dword ptr [rip+vg_fail], 0
    jne     .Ll0_fail
    lea     rdi, [rip+job_block]
    mov     esi, r15d
    mov     edx, 64
    mov     ecx, 1
    call    pfor
    xor     r12d, r12d                  # the clusters, block by block
    xor     r13d, r13d                  # triangle offset
5:  cmp     r12d, r15d
    jae     8f
    mov     rax, [rip+blk_nc]
    mov     r14d, [rax+r12*4]
    mov     ebx, r12d
    shl     ebx, 12                     # the block's first size slot
6:  test    r14d, r14d
    jz      7f
    mov     rax, [rip+os]
    mov     eax, [rax+rbx*4]
    mov     edi, r13d
    mov     esi, eax
    call    new_cluster
    movzx   eax, word ptr [rax+CB_NT]
    add     r13d, eax
    inc     ebx
    dec     r14d
    jmp     6b
7:  inc     r12d
    jmp     5b
8:  mov     [rip+bt_n], r13d
    xor     edi, edi                    # their bounds; level 0 error 0
    mov     esi, [rip+nc]
    call    bounds
    mov     rcx, [rip+cr]
    xor     edx, edx
    xorps   xmm1, xmm1
    movss   xmm2, [rip+f_maxf]
81: cmp     edx, [rip+nc]
    jae     82f
    movaps  xmm0, [rcx+CR_C]
    movaps  [rcx+CR_LOD], xmm0
    movaps  [rcx+CR_PLOD], xmm0
    movss   [rcx+CR_ERR], xmm1
    movss   [rcx+CR_PERR], xmm2
    mov     byte ptr [rcx+CR_LEVEL], 0
    add     rcx, CR_SZ
    inc     edx
    jmp     81b
82: lea     rax, [rip+lv]
    mov     dword ptr [rax], 0
    mov     ecx, [rip+nc]
    mov     [rax+4], ecx
    mov     ecx, [rip+nt0]
    mov     [rax+8], ecx
    mov     dword ptr [rax+12], 0
    mov     dword ptr [rip+nlv], 1
    mov     eax, 1
    jmp     9f
.Ll0_fail:
    xor     eax, eax
9:  add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# new_cluster(edi=first triangle, esi=size: triangles | vertices << 16)
#   -> rax = its build record (cb), the cluster numbered nc - 1
new_cluster:
    mov     ecx, [rip+nc]
    inc     dword ptr [rip+nc]
    mov     rax, rcx
    shl     rax, 4
    add     rax, [rip+cb]
    mov     [rax+CB_TOFF], edi
    movzx   edx, si
    mov     [rax+CB_NT], edx
    shr     esi, 16
    mov     [rax+CB_NV], esi
    mov     dword ptr [rax+CB_GRP], 0
    ret

# job_block(rdi=first block, esi..edx) - partition level 0 blocks
job_block:
    push    rbx
    push    r12
    push    r13
    mov     r12, r8
    lea     ebx, [rdi+rsi]
    lea     r13d, [rdi+rdx]
1:  cmp     ebx, r13d
    jae     9f
    test    r12, r12
    jz      9f
    mov     rdi, r12
    call    arena_reset
    mov     esi, [rip+nt0]
    mov     eax, ebx
    shl     eax, 12
    sub     esi, eax
    cmp     esi, BLK
    jbe     2f
    mov     esi, BLK
2:  mov     rdi, rax
    imul    rdi, rdi, 12
    add     rdi, [rip+bt]
    mov     rcx, [rip+os]
    lea     rcx, [rcx+rax*4]
    mov     rdx, r12
    call    part_set
    mov     rcx, [rip+blk_nc]
    mov     [rcx+rbx*4], eax
    inc     ebx
    jmp     1b
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# bounds(edi=first cluster, esi=end) - their bounding spheres (CR_C)
bounds:
    mov     [rip+bnd_first], edi
    sub     esi, edi
    jbe     9f
    sub     rsp, 8
    lea     rdi, [rip+job_bounds]
    mov     edx, 1<<16
    mov     ecx, 256
    call    pfor
    add     rsp, 8
9:  ret

# job_bounds(rdi=batch, esi..edx) - CR_C of clusters bnd_first + ...
job_bounds:
    push    rbx
    push    r12
    push    r13
    lea     ebx, [rdi+rsi]
    add     ebx, [rip+bnd_first]
    lea     r12d, [rdi+rdx]
    add     r12d, [rip+bnd_first]
    mov     r8, [rip+bt]
    mov     r9, [rip+w_q]
    movss   xmm6, [rip+step]
    shufps  xmm6, xmm6, 0
1:  cmp     ebx, r12d
    jae     9f
    mov     rax, rbx
    shl     rax, 4
    add     rax, [rip+cb]
    mov     ecx, [rax+CB_TOFF]
    lea     rcx, [rcx+rcx*2]
    lea     r10, [r8+rcx*4]             # its triangles
    mov     r11d, [rax+CB_NT]
    lea     r11d, [r11+r11*2]
    pcmpeqd xmm4, xmm4                  # min = max int, max = min int
    psrld   xmm4, 1
    movdqa  xmm5, xmm4
    pxor    xmm5, [rip+f_minus1i]
    xor     ecx, ecx
2:  mov     eax, [r10+rcx*4]
    lea     rax, [rax+rax*2]
    movdqu  xmm0, [r9+rax*4]
    pminsd  xmm4, xmm0
    pmaxsd  xmm5, xmm0
    inc     ecx
    cmp     ecx, r11d
    jb      2b
    paddd   xmm4, xmm5
    cvtdq2ps xmm4, xmm4
    mulps   xmm4, [rip+f_half4]         # centre (grid)
    xorps   xmm7, xmm7                  # the largest squared distance
    xor     ecx, ecx
3:  mov     eax, [r10+rcx*4]
    lea     rax, [rax+rax*2]
    movdqu  xmm0, [r9+rax*4]
    cvtdq2ps xmm0, xmm0
    subps   xmm0, xmm4
    mulps   xmm0, xmm0
    movaps  xmm1, xmm0
    shufps  xmm1, xmm1, 0x55
    addss   xmm0, xmm1
    movhlps xmm1, xmm1
    addss   xmm0, xmm1
    maxss   xmm7, xmm0
    inc     ecx
    cmp     ecx, r11d
    jb      3b
    sqrtss  xmm7, xmm7
    addss   xmm7, [rip+f_one]           # (a step of slack)
    mulss   xmm7, xmm6
    mulps   xmm4, xmm6
    addps   xmm4, [rip+bmin]
    insertps xmm4, xmm7, 0x30           # w = radius
    mov     rax, rbx
    shl     rax, 6
    add     rax, [rip+cr]
    movaps  [rax+CR_C], xmm4
    inc     ebx
    jmp     1b
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Partitioning: triangles into clusters
# =============================================================================
# localize(rdi=triangles (welded ids), esi=n, rdx=arena) -> rax = the same
#   triangles on local ids 0..nv-1, rdx = local -> welded id, ecx = nv
localize:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 24
    mov     rbx, rdi
    mov     r12d, esi
    mov     r13, rdx
    lea     r14d, [r12+r12*2]           # 3n
    mov     ebp, 64                     # table: >= 2 slots an id
1:  lea     eax, [r14+r14]
    cmp     ebp, eax
    jae     2f
    add     ebp, ebp
    jmp     1b
2:  mov     rdi, r13
    lea     rsi, [rbp*4]
    call    zalloc
    mov     [rsp], rax                  # welded id + 1
    mov     rdi, r13
    lea     rsi, [rbp*4]
    call    arena_alloc
    mov     [rsp+8], rax                # its local id
    mov     rdi, r13
    lea     rsi, [r14*4+16]
    call    arena_alloc
    mov     r15, rax                    # local triangles
    mov     rdi, r13
    lea     rsi, [r14*4+16]
    call    arena_alloc
    mov     [rsp+16], rax               # local -> welded
    dec     ebp                         # mask
    mov     r8, [rsp]
    mov     r9, [rsp+8]
    mov     r10, [rsp+16]
    xor     ecx, ecx                    # entry
    xor     edx, edx                    # nv
3:  cmp     ecx, r14d
    jae     6f
    mov     esi, [rbx+rcx*4]
    lea     r11d, [rsi+1]
    imul    eax, r11d, 0x9e3779b1
    mov     edi, eax
    shr     edi, 15
    xor     eax, edi
    and     eax, ebp
4:  mov     edi, [r8+rax*4]
    test    edi, edi
    jz      5f
    cmp     edi, r11d
    je      41f
    inc     eax
    and     eax, ebp
    jmp     4b
41: mov     edi, [r9+rax*4]
    mov     [r15+rcx*4], edi
    inc     ecx
    jmp     3b
5:  mov     [r8+rax*4], r11d
    mov     [r9+rax*4], edx
    mov     [r10+rdx*4], esi
    mov     [r15+rcx*4], edx
    inc     edx
    inc     ecx
    jmp     3b
6:  mov     rax, r15
    mov     ecx, edx
    mov     rdx, r10
    add     rsp, 24
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# part_set(rdi=triangles (welded ids), esi=n, rdx=arena, rcx=sizes out)
#   -> eax = clusters: the triangles reordered cluster by cluster in place,
#   sizes[k] = triangles | vertices << 16
part_set:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 24
    mov     rbx, rdi
    mov     r12d, esi
    mov     r13, rdx
    mov     r14, rcx
    call    localize
    mov     r15, rax                    # local triangles
    mov     rbp, rdx                    # local -> welded
    mov     rdi, rax
    mov     esi, r12d
    mov     edx, ecx
    mov     rcx, r13
    mov     r8, r14
    call    part_local
    mov     [rsp], eax
    mov     [rsp+8], rdx                # order
    mov     rdi, r13
    lea     esi, [r12+r12*2]
    shl     rsi, 2
    call    arena_alloc
    mov     r8, rax
    mov     r9, [rsp+8]
    xor     ecx, ecx
    xor     edx, edx
1:  cmp     ecx, r12d
    jae     2f
    mov     eax, [r9+rcx*4]
    lea     rax, [rax+rax*2]
    mov     esi, [r15+rax*4]
    mov     esi, [rbp+rsi*4]
    mov     [r8+rdx*4], esi
    mov     esi, [r15+rax*4+4]
    mov     esi, [rbp+rsi*4]
    mov     [r8+rdx*4+4], esi
    mov     esi, [r15+rax*4+8]
    mov     esi, [rbp+rsi*4]
    mov     [r8+rdx*4+8], esi
    add     edx, 3
    inc     ecx
    jmp     1b
2:  mov     rdi, rbx
    mov     rsi, r8
    mov     ecx, edx
    rep     movsd
    mov     eax, [rsp]
    add     rsp, 24
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# part_local(rdi=triangles (local ids), esi=n, edx=nv, rcx=arena, r8=sizes)
#   -> eax = clusters, rdx = the triangles' order (cluster by cluster).
#   Each cluster grows from the first triangle left (the input is in
#   spatial order) over its neighbours, taking the one that adds the fewest
#   vertices (the oldest on a tie), up to 128 triangles / 64 vertices.
.equ PL_LT,     0
.equ PL_N,      8
.equ PL_NV,     12
.equ PL_AR,     16
.equ PL_SIZES,  24
.equ PL_VOFF,   32
.equ PL_VLIST,  40
.equ PL_ADJ,    48
.equ PL_USED,   56
.equ PL_VST,    64
.equ PL_CST,    72
.equ PL_CAND,   80
.equ PL_ORDER,  88
.equ PL_OUT,    96
.equ PL_K,      100
.equ PL_NTRI,   104
.equ PL_NVERT,  108
.equ PL_NCAND,  112
.equ PL_SEED,   116
.equ PL_LIVE,   120                     # per vertex: triangles not yet used
.equ PL_FSEED,  128                     # the next seed, from the frontier
.equ PL_COMP,   136                     # per triangle: its connected piece
.equ PL_CSIZE,  144                     # per piece: triangles, then left
part_local:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 152
    mov     [rsp+PL_LT], rdi
    mov     [rsp+PL_N], esi
    mov     [rsp+PL_NV], edx
    mov     [rsp+PL_AR], rcx
    mov     [rsp+PL_SIZES], r8
    mov     rdi, rcx                    # vertex -> triangles
    mov     esi, edx
    lea     rsi, [rsi*4+8]
    call    zalloc
    mov     [rsp+PL_VOFF], rax
    mov     r12d, [rsp+PL_N]
    lea     r12d, [r12+r12*2]           # 3n
    mov     rdi, [rsp+PL_AR]
    lea     rsi, [r12*4+16]
    call    arena_alloc
    mov     [rsp+PL_VLIST], rax
    mov     rdi, [rsp+PL_AR]
    lea     rsi, [r12*4+16]
    call    arena_alloc
    mov     [rsp+PL_ADJ], rax
    mov     rdi, [rsp+PL_AR]
    mov     esi, [rsp+PL_N]
    add     esi, 16
    call    zalloc
    mov     [rsp+PL_USED], rax
    mov     rdi, [rsp+PL_AR]
    mov     esi, [rsp+PL_NV]
    lea     rsi, [rsi*4+16]
    call    zalloc
    mov     [rsp+PL_VST], rax
    mov     rdi, [rsp+PL_AR]
    mov     esi, [rsp+PL_N]
    lea     rsi, [rsi*4+16]
    call    zalloc
    mov     [rsp+PL_CST], rax
    mov     rdi, [rsp+PL_AR]
    mov     esi, NCAND*4
    call    arena_alloc
    mov     [rsp+PL_CAND], rax
    mov     rdi, [rsp+PL_AR]
    mov     esi, [rsp+PL_N]
    lea     rsi, [rsi*4+16]
    call    arena_alloc
    mov     [rsp+PL_ORDER], rax
    mov     rdi, [rsp+PL_AR]            # (a cursor per vertex)
    mov     esi, [rsp+PL_NV]
    lea     rsi, [rsi*4+16]
    call    arena_alloc
    mov     r13, rax
    mov     rbx, [rsp+PL_LT]
    mov     r8, [rsp+PL_VOFF]
    xor     ecx, ecx
1:  cmp     ecx, r12d
    jae     2f
    mov     eax, [rbx+rcx*4]
    inc     dword ptr [r8+rax*4+4]
    inc     ecx
    jmp     1b
2:  mov     edx, [rsp+PL_NV]
    xor     ecx, ecx
    xor     eax, eax
3:  cmp     ecx, edx
    jae     4f
    add     eax, [r8+rcx*4+4]
    mov     [r8+rcx*4+4], eax
    mov     esi, [r8+rcx*4]
    mov     [r13+rcx*4], esi
    inc     ecx
    jmp     3b
4:  mov     rdi, [rsp+PL_AR]            # live triangles per vertex
    mov     esi, [rsp+PL_NV]
    lea     rsi, [rsi*4+16]
    call    arena_alloc
    mov     [rsp+PL_LIVE], rax
    mov     r8, [rsp+PL_VOFF]
    xor     ecx, ecx
41: cmp     ecx, [rsp+PL_NV]
    jae     42f
    mov     edx, [r8+rcx*4+4]
    sub     edx, [r8+rcx*4]
    mov     [rax+rcx*4], edx
    inc     ecx
    jmp     41b
42: mov     r9, [rsp+PL_VLIST]
    xor     ecx, ecx
5:  cmp     ecx, r12d
    jae     6f
    mov     eax, [rbx+rcx*4]
    mov     edx, [r13+rax*4]
    inc     dword ptr [r13+rax*4]
    mov     eax, ecx                    # the triangle: entry / 3
    imul    rax, rax, 0x55555556
    shr     rax, 32
    mov     [r9+rdx*4], eax
    inc     ecx
    jmp     5b
6:  mov     r10, [rsp+PL_ADJ]           # neighbours across each edge
    xor     ecx, ecx                    # entry 3t + e
7:  cmp     ecx, r12d
    jae     .Lpl_pieces
    mov     eax, ecx
    imul    rax, rax, 0x55555556
    shr     rax, 32
    mov     r11d, eax                   # t
    lea     edx, [rax+rax*2]
    mov     esi, ecx                    # the next corner
    inc     esi
    lea     edi, [rdx+3]
    cmp     esi, edi
    jb      71f
    mov     esi, edx
71: mov     r14d, [rbx+rcx*4]           # a
    mov     r15d, [rbx+rsi*4]           # b
    mov     dword ptr [r10+rcx*4], -1
    mov     edx, [r8+r14*4]
    mov     edi, [r8+r14*4+4]
72: cmp     edx, edi
    jae     75f
    mov     eax, [r9+rdx*4]
    inc     edx
    cmp     eax, r11d
    je      72b
    lea     rsi, [rax+rax*2]
    cmp     [rbx+rsi*4], r15d
    je      74f
    cmp     [rbx+rsi*4+4], r15d
    je      74f
    cmp     [rbx+rsi*4+8], r15d
    jne     72b
74: mov     [r10+rcx*4], eax
75: inc     ecx
    jmp     7b
.Lpl_pieces:
    # connected pieces (flood fill over the edges): a cluster may go on to
    # the next triangle when its piece is used up (islands), not in a pocket
    mov     rdi, [rsp+PL_AR]
    mov     esi, [rsp+PL_N]
    lea     rsi, [rsi*4+16]
    call    arena_alloc
    mov     [rsp+PL_COMP], rax
    mov     rdi, rax
    mov     ecx, [rsp+PL_N]
    mov     eax, -1
    rep     stosd
    mov     rdi, [rsp+PL_AR]
    mov     esi, [rsp+PL_N]
    lea     rsi, [rsi*4+16]
    call    zalloc
    mov     [rsp+PL_CSIZE], rax
    mov     rdi, [rsp+PL_AR]            # (a stack)
    mov     esi, [rsp+PL_N]
    lea     rsi, [rsi*4+16]
    call    arena_alloc
    mov     r14, rax
    mov     r8, [rsp+PL_COMP]
    mov     r9, [rsp+PL_CSIZE]
    mov     r10, [rsp+PL_ADJ]
    xor     r11d, r11d                  # pieces
    xor     ebx, ebx                    # triangle
81: cmp     ebx, [rsp+PL_N]
    jae     .Lpl_grow
    cmp     dword ptr [r8+rbx*4], 0
    jge     85f
    mov     [r8+rbx*4], r11d
    mov     [r14], ebx
    mov     r15d, 1                     # stack depth
82: test    r15d, r15d
    jz      84f
    dec     r15d
    mov     eax, [r14+r15*4]
    inc     dword ptr [r9+r11*4]
    lea     rsi, [rax+rax*2]
    xor     ecx, ecx
83: mov     edx, [r10+rsi*4]
    inc     rsi
    test    edx, edx
    js      831f
    cmp     dword ptr [r8+rdx*4], 0
    jge     831f
    mov     [r8+rdx*4], r11d
    mov     [r14+r15*4], edx
    inc     r15d
831:inc     ecx
    cmp     ecx, 3
    jb      83b
    jmp     82b
84: inc     r11d
85: inc     ebx
    jmp     81b
.Lpl_grow:
    xor     eax, eax
    mov     [rsp+PL_OUT], eax
    mov     [rsp+PL_K], eax
    mov     [rsp+PL_SEED], eax
    mov     dword ptr [rsp+PL_FSEED], -1
.Lpl_cluster:
    mov     r8, [rsp+PL_USED]
    mov     eax, [rsp+PL_FSEED]         # a frontier triangle, else the next
    test    eax, eax
    jns     21f
    mov     eax, [rsp+PL_SEED]
1:  cmp     eax, [rsp+PL_N]
    jae     .Lpl_done
    cmp     byte ptr [r8+rax], 0
    je      2f
    inc     eax
    jmp     1b
2:  mov     [rsp+PL_SEED], eax
21: xor     ecx, ecx
    mov     [rsp+PL_NTRI], ecx
    mov     [rsp+PL_NVERT], ecx
    mov     [rsp+PL_NCAND], ecx
    mov     edi, eax
    call    pl_add
3:  cmp     dword ptr [rsp+PL_NTRI], CL_TRIS
    jae     .Lpl_close
    mov     r8, [rsp+PL_USED]
    mov     r9, [rsp+PL_CAND]
    mov     r10, [rsp+PL_VST]
    mov     rbx, [rsp+PL_LT]
    mov     r11d, [rsp+PL_K]
    inc     r11d                        # stamp
    mov     r12d, -1                    # best
    mov     r13d, 0x7fffffff            # its score
    xor     ecx, ecx                    # read
    xor     edx, edx                    # write (kept in order)
4:  cmp     ecx, [rsp+PL_NCAND]
    jae     6f
    mov     eax, [r9+rcx*4]
    inc     ecx
    cmp     byte ptr [r8+rax], 0
    jne     4b
    mov     [r9+rdx*4], eax
    inc     edx
    lea     rsi, [rax+rax*2]            # the vertices it adds, and how many
    xor     edi, edi                    #   triangles its vertices have left
    mov     r15, [rsp+PL_LIVE]
    xor     ebp, ebp
    mov     r14d, [rbx+rsi*4]
    add     ebp, [r15+r14*4]
    cmp     [r10+r14*4], r11d
    je      41f
    inc     edi
41: mov     r14d, [rbx+rsi*4+4]
    add     ebp, [r15+r14*4]
    cmp     [r10+r14*4], r11d
    je      42f
    inc     edi
42: mov     r14d, [rbx+rsi*4+8]
    add     ebp, [r15+r14*4]
    cmp     [r10+r14*4], r11d
    je      43f
    inc     edi
43: mov     r14d, [rsp+PL_NVERT]
    add     r14d, edi
    cmp     r14d, CL_VERTS
    ja      4b
    shl     edi, 16                     # fewest new vertices, then the
    cmp     ebp, 0xffff                 #   fewest triangles left around
    jbe     44f
    mov     ebp, 0xffff
44: or      edi, ebp
    cmp     edi, r13d
    jae     4b
    mov     r13d, edi
    mov     r12d, eax
    jmp     4b
6:  mov     [rsp+PL_NCAND], edx
    test    r12d, r12d
    jns     7f
    mov     eax, [rsp+PL_OUT]           # its piece used up (an island)?
    mov     rcx, [rsp+PL_ORDER]
    mov     eax, [rcx+rax*4-4]
    mov     rcx, [rsp+PL_COMP]
    mov     eax, [rcx+rax*4]
    mov     rcx, [rsp+PL_CSIZE]
    cmp     dword ptr [rcx+rax*4], 0
    jne     .Lpl_close
    cmp     dword ptr [rsp+PL_NTRI], CL_TRIS/2  # nothing next to it, still
    jae     .Lpl_close                  #   small (an island): the next
    cmp     dword ptr [rsp+PL_NVERT], CL_VERTS-3  # triangle left, in order
    ja      .Lpl_close
    mov     eax, [rsp+PL_SEED]
61: cmp     eax, [rsp+PL_N]
    jae     .Lpl_close
    cmp     byte ptr [r8+rax], 0
    je      62f
    inc     eax
    jmp     61b
62: mov     [rsp+PL_SEED], eax
    mov     r12d, eax
7:  mov     edi, r12d
    call    pl_add
    jmp     3b
.Lpl_close:
    mov     eax, [rsp+PL_NVERT]
    shl     eax, 16
    or      eax, [rsp+PL_NTRI]
    mov     ecx, [rsp+PL_K]
    mov     rdx, [rsp+PL_SIZES]
    mov     [rdx+rcx*4], eax
    inc     dword ptr [rsp+PL_K]
    mov     r8, [rsp+PL_USED]           # the next seed: the frontier triangle
    mov     r9, [rsp+PL_CAND]           #   with the fewest triangles left
    mov     r15, [rsp+PL_LIVE]          #   around it (a corner, a pocket)
    mov     rbx, [rsp+PL_LT]
    mov     r12d, -1
    mov     r13d, 0x7fffffff
    xor     ecx, ecx
1:  cmp     ecx, [rsp+PL_NCAND]
    jae     2f
    mov     eax, [r9+rcx*4]
    inc     ecx
    cmp     byte ptr [r8+rax], 0
    jne     1b
    lea     rsi, [rax+rax*2]
    mov     r14d, [rbx+rsi*4]
    mov     ebp, [r15+r14*4]
    mov     r14d, [rbx+rsi*4+4]
    add     ebp, [r15+r14*4]
    mov     r14d, [rbx+rsi*4+8]
    add     ebp, [r15+r14*4]
    cmp     ebp, r13d
    jae     1b
    mov     r13d, ebp
    mov     r12d, eax
    jmp     1b
2:  mov     [rsp+PL_FSEED], r12d
    jmp     .Lpl_cluster
.Lpl_done:
    mov     eax, [rsp+PL_K]
    mov     rdx, [rsp+PL_ORDER]
    add     rsp, 152
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# pl_add(edi=triangle) - into the cluster (part_local's frame at rsp+8)
pl_add:
    lea     r8, [rsp+8]
    mov     rax, [r8+PL_USED]
    mov     byte ptr [rax+rdi], 1
    mov     rax, [r8+PL_COMP]
    mov     eax, [rax+rdi*4]
    mov     rcx, [r8+PL_CSIZE]
    dec     dword ptr [rcx+rax*4]
    mov     rax, [r8+PL_ORDER]
    mov     ecx, [r8+PL_OUT]
    mov     [rax+rcx*4], edi
    inc     dword ptr [r8+PL_OUT]
    inc     dword ptr [r8+PL_NTRI]
    mov     r9, [r8+PL_LT]
    mov     r10, [r8+PL_VST]
    mov     r11d, [r8+PL_K]
    inc     r11d
    lea     rsi, [rdi+rdi*2]
    xor     ecx, ecx
1:  mov     eax, [r9+rsi*4]
    mov     rdx, [r8+PL_LIVE]
    dec     dword ptr [rdx+rax*4]
    cmp     [r10+rax*4], r11d
    je      2f
    mov     [r10+rax*4], r11d
    inc     dword ptr [r8+PL_NVERT]
2:  mov     rax, [r8+PL_ADJ]            # its neighbours become candidates
    mov     edx, [rax+rsi*4]
    test    edx, edx
    js      3f
    mov     rax, [r8+PL_USED]
    cmp     byte ptr [rax+rdx], 0
    jne     3f
    mov     rax, [r8+PL_CST]
    cmp     [rax+rdx*4], r11d
    je      3f
    cmp     dword ptr [r8+PL_NCAND], NCAND
    jae     3f
    mov     [rax+rdx*4], r11d
    mov     rax, [r8+PL_CAND]
    mov     r9d, [r8+PL_NCAND]
    mov     [rax+r9*4], edx
    inc     dword ptr [r8+PL_NCAND]
    mov     r9, [r8+PL_LT]
3:  inc     rsi
    inc     ecx
    cmp     ecx, 3
    jb      1b
    ret

# =============================================================================
#  Levels: group, simplify, split
# =============================================================================
# bd_level -> eax = 1: one more level made from the last (0: the DAG is done)
.equ BL_MARK,   0
.equ BL_NCL,    4
.equ BL_TOT,    8
.equ BL_CAP,    12
.equ BL_KEYS,   16
.equ BL_VALS,   24
.equ BL_PAIRS,  32
.equ BL_NP,     40
.equ BL_DEG,    48
.equ BL_NB,     56
.equ BL_GRP,    64
.equ BL_NEWLO,  72
.equ BL_NEWT,   76
.equ BL_MAXE,   80
.equ BL_NG0,    84
.equ BL_NM0,    88
bd_level:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 104
    mov     eax, [rip+vm_n]
    mov     [rsp+BL_MARK], eax
    mov     eax, [rip+ng]
    mov     [rsp+BL_NG0], eax
    mov     eax, [rip+nm]
    mov     [rsp+BL_NM0], eax
    mov     eax, [rip+nlv]
    cmp     eax, VG_MAXLV
    jae     .Lbl_stop
    dec     eax
    shl     eax, 4
    lea     rcx, [rip+lv]
    mov     edx, [rcx+rax]
    mov     [rip+lo], edx
    mov     esi, [rcx+rax+4]
    mov     [rsp+BL_NCL], esi
    add     edx, esi
    mov     [rip+hi], edx
    cmp     esi, 1
    jbe     .Lbl_stop
    # boundary edges of every cluster (counted, then written)
    mov     edi, [rsp+BL_NCL]
    lea     rdi, [rdi*4+8]
    call    vmap
    mov     [rip+ebn], rax
    mov     edi, [rsp+BL_NCL]
    lea     rdi, [rdi*4+8]
    call    vmap
    mov     [rip+eoff], rax
    cmp     dword ptr [rip+vg_fail], 0
    jne     .Lbl_stop
    mov     dword ptr [rip+be_mode], 0
    lea     rdi, [rip+job_bedge]
    mov     esi, [rsp+BL_NCL]
    mov     edx, 1<<14
    mov     ecx, 64
    call    pfor
    mov     rcx, [rip+ebn]
    mov     rdx, [rip+eoff]
    xor     eax, eax
    xor     esi, esi
1:  cmp     esi, [rsp+BL_NCL]
    jae     2f
    mov     [rdx+rsi*4], eax
    add     eax, [rcx+rsi*4]
    inc     esi
    jmp     1b
2:  mov     [rdx+rsi*4], eax
    mov     [rsp+BL_TOT], eax
    lea     rdi, [rax*8+64]
    call    vmap
    mov     [rip+eb], rax
    cmp     dword ptr [rip+vg_fail], 0
    jne     .Lbl_stop
    mov     dword ptr [rip+be_mode], 1
    lea     rdi, [rip+job_bedge]
    mov     esi, [rsp+BL_NCL]
    mov     edx, 1<<14
    mov     ecx, 64
    call    pfor
    # shared edges -> pairs of neighbouring clusters
    mov     ebx, 1024
3:  mov     eax, [rsp+BL_TOT]
    add     eax, eax
    cmp     ebx, eax
    jae     4f
    add     ebx, ebx
    jmp     3b
4:  mov     [rsp+BL_CAP], ebx
    lea     rdi, [rbx*8]
    call    vmap
    mov     [rsp+BL_KEYS], rax
    lea     rdi, [rbx*4]
    call    vmap
    mov     [rsp+BL_VALS], rax
    mov     edi, [rsp+BL_TOT]
    lea     rdi, [rdi*8+64]
    call    vmap
    mov     [rsp+BL_PAIRS], rax
    cmp     dword ptr [rip+vg_fail], 0
    jne     .Lbl_stop
    mov     r12, [rsp+BL_KEYS]
    mov     r13, [rsp+BL_VALS]
    mov     r14, [rsp+BL_PAIRS]
    mov     r15d, [rsp+BL_CAP]
    dec     r15d
    xor     ebp, ebp                    # pairs
    xor     ebx, ebx                    # cluster (local)
5:  cmp     ebx, [rsp+BL_NCL]
    jae     8f
    mov     rax, [rip+eoff]
    mov     r8d, [rax+rbx*4]
    mov     r9d, [rax+rbx*4+4]
6:  cmp     r8d, r9d
    jae     7f
    mov     rax, [rip+eb]
    mov     r10, [rax+r8*8]             # key
    inc     r8d
    mov     rax, r10
    mov     rcx, 0x9e3779b97f4a7c15
    imul    rax, rcx
    shr     rax, 32
    and     eax, r15d
61: mov     rcx, [r12+rax*8]
    test    rcx, rcx
    jz      62f
    cmp     rcx, r10
    je      63f
    inc     eax
    and     eax, r15d
    jmp     61b
62: mov     [r12+rax*8], r10
    mov     [r13+rax*4], ebx
    jmp     6b
63: mov     ecx, [r13+rax*4]
    cmp     ecx, ebx
    je      6b
    mov     [r14+rbp*8], ecx
    mov     [r14+rbp*8+4], ebx
    inc     ebp
    jmp     6b
7:  inc     ebx
    jmp     5b
8:  mov     [rsp+BL_NP], ebp
    # neighbour lists (a neighbour once per shared edge: the weight)
    mov     edi, [rsp+BL_NCL]
    lea     rdi, [rdi*4+8]
    call    vmap
    mov     [rsp+BL_DEG], rax
    mov     edi, [rsp+BL_NP]
    lea     rdi, [rdi*8+16]
    call    vmap
    mov     [rsp+BL_NB], rax
    mov     edi, [rsp+BL_NCL]
    lea     rdi, [rdi*4+8]
    call    vmap
    mov     [rsp+BL_GRP], rax           # (first a cursor, then group + 1)
    cmp     dword ptr [rip+vg_fail], 0
    jne     .Lbl_stop
    mov     r8, [rsp+BL_DEG]
    xor     ecx, ecx
1:  cmp     ecx, [rsp+BL_NP]
    jae     2f
    mov     eax, [r14+rcx*8]
    inc     dword ptr [r8+rax*4+4]
    mov     eax, [r14+rcx*8+4]
    inc     dword ptr [r8+rax*4+4]
    inc     ecx
    jmp     1b
2:  mov     r9, [rsp+BL_GRP]
    xor     ecx, ecx
    xor     eax, eax
3:  cmp     ecx, [rsp+BL_NCL]
    jae     4f
    mov     edx, [r8+rcx*4]
    mov     [r9+rcx*4], edx
    add     eax, [r8+rcx*4+4]
    add     [r8+rcx*4+4], edx
    inc     ecx
    jmp     3b
4:  mov     r10, [rsp+BL_NB]
    xor     ecx, ecx
5:  cmp     ecx, [rsp+BL_NP]
    jae     6f
    mov     eax, [r14+rcx*8]
    mov     edx, [r14+rcx*8+4]
    mov     esi, [r9+rax*4]
    inc     dword ptr [r9+rax*4]
    mov     [r10+rsi*4], edx
    mov     esi, [r9+rdx*4]
    inc     dword ptr [r9+rdx*4]
    mov     [r10+rsi*4], eax
    inc     ecx
    jmp     5b
6:  mov     rdi, r9                     # the cursors become the groups
    mov     ecx, [rsp+BL_NCL]
    xor     eax, eax
    rep     stosd
    mov     eax, [rip+ng]
    mov     [rip+glo], eax
    mov     rdi, [rsp+BL_DEG]
    mov     rsi, [rsp+BL_NB]
    mov     rdx, [rsp+BL_GRP]
    mov     ecx, [rsp+BL_NCL]
    call    bd_group
    mov     eax, [rip+ng]
    mov     [rip+ghi], eax
    # simplify the groups (in parallel)
    mov     ebx, [rip+ghi]
    sub     ebx, [rip+glo]
    lea     rdi, [rbx*4+8]
    call    vmap
    mov     [rip+gin], rax
    lea     rdi, [rbx*4+8]
    call    vmap
    mov     [rip+gonc], rax
    lea     rdi, [rbx*4+8]
    call    vmap
    mov     [rip+gont], rax
    lea     rdi, [rbx*4+8]
    call    vmap
    mov     [rip+goerr], rax
    cmp     dword ptr [rip+vg_fail], 0
    jne     .Lbl_stop
    mov     r8, [rip+gin]
    xor     ecx, ecx
    xor     eax, eax
7:  cmp     ecx, ebx
    jae     8f
    mov     [r8+rcx*4], eax
    mov     edx, [rip+glo]
    add     edx, ecx
    imul    edx, edx, GR_SZ
    add     rdx, [rip+gr]
    mov     esi, [rdx+GR_MEM]
    mov     edi, [rdx+GR_NMEM]
71: test    edi, edi
    jz      72f
    mov     r9, [rip+mem]
    mov     r9d, [r9+rsi*4]
    shl     r9, 4
    add     r9, [rip+cb]
    add     eax, [r9+CB_NT]
    inc     esi
    dec     edi
    jmp     71b
72: inc     ecx
    jmp     7b
8:  mov     [r8+rcx*4], eax
    mov     r12d, eax                   # the level's triangles
    lea     rdi, [rax+rax*2]
    lea     rdi, [rdi*4+64]
    call    vmap
    mov     [rip+ot], rax
    lea     rdi, [r12*4+64]
    call    vmap
    mov     [rip+os], rax
    cmp     dword ptr [rip+vg_fail], 0
    jne     .Lbl_stop
    lea     rdi, [rip+job_group]
    mov     esi, ebx
    mov     edx, 256
    mov     ecx, 1
    call    pfor
    # the new clusters, group by group
    mov     eax, [rip+nc]
    mov     [rsp+BL_NEWLO], eax
    mov     dword ptr [rsp+BL_NEWT], 0
    mov     dword ptr [rsp+BL_MAXE], 0
    xor     ebx, ebx                    # group (local)
1:  mov     eax, [rip+ghi]
    sub     eax, [rip+glo]
    cmp     ebx, eax
    jae     5f
    mov     edi, ebx
    call    finish_group
    maxss   xmm0, [rsp+BL_MAXE]
    movss   [rsp+BL_MAXE], xmm0
    mov     rax, [rip+gont]
    mov     eax, [rax+rbx*4]
    add     [rsp+BL_NEWT], eax
    inc     ebx
    jmp     1b
5:  mov     edi, [rsp+BL_NEWLO]
    mov     esi, [rip+nc]
    call    bounds
    mov     eax, [rip+nlv]
    shl     eax, 4
    lea     rcx, [rip+lv]
    add     rcx, rax
    mov     edx, [rsp+BL_NEWLO]
    mov     [rcx], edx
    mov     esi, [rip+nc]
    sub     esi, edx
    mov     [rcx+4], esi
    mov     edx, [rsp+BL_NEWT]
    mov     [rcx+8], edx
    mov     edx, [rsp+BL_MAXE]
    mov     [rcx+12], edx
    inc     dword ptr [rip+nlv]
    mov     edi, [rsp+BL_MARK]
    call    vfree_to
    mov     eax, [rip+nlv]
    shl     eax, 4
    lea     rcx, [rip+lv-16]
    add     rcx, rax                    # the new level
    cmp     dword ptr [rcx+4], 1        # one cluster: the root
    jbe     .Lbl_done
    cvtsi2ss xmm0, dword ptr [rcx-16+8] # a level that hardly shrinks: done
    mulss   xmm0, [rip+f_shrink]
    cvtsi2ss xmm1, dword ptr [rcx+8]
    comiss  xmm1, xmm0
    ja      .Lbl_done
    mov     eax, 1
    jmp     9f
.Lbl_stop:                              # (groups made for nothing: gone)
    mov     eax, [rsp+BL_NG0]
    mov     [rip+ng], eax
    mov     eax, [rsp+BL_NM0]
    mov     [rip+nm], eax
    mov     edi, [rsp+BL_MARK]
    call    vfree_to
.Lbl_done:
    xor     eax, eax
9:  add     rsp, 104
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# job_bedge(rdi=batch, esi..edx) - a cluster's boundary edges (directed
#   edges whose twin is not in it): counted (be_mode 0) or written as
#   min << 32 | max (1). A table of 1024 directed edges on the stack.
job_bedge:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 8192+8
    lea     ebx, [rdi+rsi]
    lea     r12d, [rdi+rdx]
.Lbe_next:
    cmp     ebx, r12d
    jae     .Lbe_out
    lea     rdi, [rsp+8]
    mov     ecx, 1024
    xor     eax, eax
    rep     stosq
    mov     eax, [rip+lo]
    add     eax, ebx
    shl     rax, 4
    add     rax, [rip+cb]
    mov     ecx, [rax+CB_TOFF]
    lea     rcx, [rcx+rcx*2]
    shl     rcx, 2
    add     rcx, [rip+bt]
    mov     r13, rcx                    # triangles
    mov     r14d, [rax+CB_NT]
    lea     r14d, [r14+r14*2]           # entries
    mov     r15, 0x9e3779b97f4a7c15
    xor     ecx, ecx                    # insert every directed edge
1:  cmp     ecx, r14d
    jae     3f
    call    be_key                      # rax = key of entry ecx
    mov     r8, rax
    imul    rax, r15
    shr     rax, 54
11: mov     rdx, [rsp+rax*8+8]
    test    rdx, rdx
    jz      12f
    cmp     rdx, r8
    je      2f
    inc     eax
    and     eax, 1023
    jmp     11b
12: mov     [rsp+rax*8+8], r8
2:  inc     ecx
    jmp     1b
3:  xor     ecx, ecx
    xor     ebp, ebp                    # boundary edges
4:  cmp     ecx, r14d
    jae     7f
    call    be_key
    ror     rax, 32                     # its twin
    mov     r8, rax
    imul    rax, r15
    shr     rax, 54
41: mov     rdx, [rsp+rax*8+8]
    test    rdx, rdx
    jz      5f
    cmp     rdx, r8
    je      6f
    inc     eax
    and     eax, 1023
    jmp     41b
5:  cmp     dword ptr [rip+be_mode], 0
    je      51f
    mov     rax, r8                     # min << 32 | max, ids from 0
    mov     rdx, r8
    shr     rdx, 32
    mov     eax, eax
    dec     eax
    dec     edx
    cmp     eax, edx
    jbe     52f
    xchg    eax, edx
52: shl     rax, 32
    or      rax, rdx
    mov     rdx, [rip+eoff]
    mov     edx, [rdx+rbx*4]
    add     edx, ebp
    mov     rsi, [rip+eb]
    mov     [rsi+rdx*8], rax
51: inc     ebp
6:  inc     ecx
    jmp     4b
7:  cmp     dword ptr [rip+be_mode], 0
    jne     8f
    mov     rax, [rip+ebn]
    mov     [rax+rbx*4], ebp
8:  inc     ebx
    jmp     .Lbe_next
.Lbe_out:
    add     rsp, 8192+8
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# be_key(ecx=entry 3t + e; r13 = triangles) -> rax = (a + 1) << 32 | (b + 1)
#   for the edge from corner e to the next (rdx, rsi clobbered)
be_key:
    mov     eax, ecx
    imul    rax, rax, 0x55555556
    shr     rax, 32
    lea     edx, [rax+rax*2]
    lea     esi, [rcx+1]
    add     edx, 3
    cmp     esi, edx
    jb      1f
    sub     esi, 3
1:  mov     eax, [r13+rcx*4]
    inc     eax
    shl     rax, 32
    mov     edx, [r13+rsi*4]
    inc     edx
    or      rax, rdx
    ret

# bd_group(rdi=offsets (ncl + 1), rsi=neighbours, rdx=group + 1 per cluster
#   (zeroed), ecx=ncl) - groups of the level's clusters: from the first
#   cluster left, add the neighbour sharing the most edges with the group,
#   up to GMAXN clusters / GTRIS triangles; a group still small joins the
#   neighbouring group it shares the most edges with (up to GTMAX). Then the
#   group records and member lists.
.equ GMAXN,     32
.equ GTRIS,     1024
.equ GTSMALL,   256
.equ GTMAX,     1536
.equ BG_NCL,    0
.equ BG_GTR,    8                       # triangles per (local) group
.equ BG_GN,     16
bd_group:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 40
    mov     r12, rdi
    mov     r13, rsi
    mov     r14, rdx
    mov     [rsp+BG_NCL], ecx
    mov     dword ptr [rsp+BG_GN], 0
    lea     rdi, [rcx*4+8]
    call    vmap
    mov     [rsp+BG_GTR], rax
    test    rax, rax
    jz      .Lbg_out
    xor     ebx, ebx                    # cluster (local)
.Lbg_next:
    cmp     ebx, [rsp+BG_NCL]
    jae     .Lbg_lists
    cmp     dword ptr [r14+rbx*4], 0
    jne     .Lbg_skip
    mov     eax, [rsp+BG_GN]            # a new group
    inc     dword ptr [rsp+BG_GN]
    mov     [rip+bg_g], eax
    mov     dword ptr [rip+bg_n], 0
    mov     rcx, [rsp+BG_GTR]
    mov     dword ptr [rcx+rax*4], 0
    xor     ebp, ebp                    # candidates
    mov     edi, ebx
    call    bg_add
.Lbg_more:
    cmp     dword ptr [rip+bg_n], GMAXN
    jae     .Lbg_close
    mov     r15, [rsp+BG_GTR]
    mov     eax, [rip+bg_g]
    mov     r8d, [r15+rax*4]            # its triangles
    mov     edx, -1                     # the best candidate
    xor     esi, esi                    # its score
    xor     ecx, ecx
1:  cmp     ecx, ebp
    jae     2f
    lea     rax, [rip+cid]
    mov     eax, [rax+rcx*4]
    cmp     dword ptr [r14+rax*4], 0
    jne     11f
    lea     rdi, [rip+csc]
    cmp     [rdi+rcx*4], esi
    jbe     11f
    mov     edi, [rip+lo]               # (room for its triangles?)
    add     edi, eax
    shl     rdi, 4
    add     rdi, [rip+cb]
    mov     edi, [rdi+CB_NT]
    add     edi, r8d
    cmp     edi, GTRIS
    ja      11f
    lea     rdi, [rip+csc]
    mov     esi, [rdi+rcx*4]
    mov     edx, eax
11: inc     ecx
    jmp     1b
2:  test    edx, edx
    js      .Lbg_close
    mov     edi, edx
    call    bg_add
    jmp     .Lbg_more
.Lbg_close:                             # small: into a neighbouring group
    mov     r15, [rsp+BG_GTR]
    mov     eax, [rip+bg_g]
    cmp     dword ptr [r15+rax*4], GTSMALL
    jae     .Lbg_skip
    xor     ebp, ebp                    # (neighbouring groups, edges shared)
    xor     r9d, r9d                    # member
1:  cmp     r9d, [rip+bg_n]
    jae     4f
    lea     rax, [rip+bg_mem]
    mov     eax, [rax+r9*4]
    inc     r9d
    mov     r10d, [r12+rax*4]
    mov     r11d, [r12+rax*4+4]
2:  cmp     r10d, r11d
    jae     1b
    mov     eax, [r13+r10*4]
    inc     r10d
    mov     eax, [r14+rax*4]
    test    eax, eax
    jz      2b
    dec     eax
    cmp     eax, [rip+bg_g]
    je      2b
    lea     rsi, [rip+cid]
    lea     rdx, [rip+csc]
    xor     ecx, ecx
3:  cmp     ecx, ebp
    jae     31f
    cmp     [rsi+rcx*4], eax
    je      32f
    inc     ecx
    jmp     3b
31: cmp     ebp, 512
    jae     2b
    mov     [rsi+rbp*4], eax
    mov     dword ptr [rdx+rbp*4], 1
    inc     ebp
    jmp     2b
32: inc     dword ptr [rdx+rcx*4]
    jmp     2b
4:  mov     eax, [rip+bg_g]             # the one sharing most, with room
    mov     r8d, [r15+rax*4]
    mov     edx, -1
    xor     esi, esi
    xor     ecx, ecx
5:  cmp     ecx, ebp
    jae     6f
    lea     rax, [rip+cid]
    mov     eax, [rax+rcx*4]
    lea     rdi, [rip+csc]
    cmp     [rdi+rcx*4], esi
    jbe     51f
    mov     edi, [r15+rax*4]
    add     edi, r8d
    cmp     edi, GTMAX
    ja      51f
    lea     rdi, [rip+csc]
    mov     esi, [rdi+rcx*4]
    mov     edx, eax
51: inc     ecx
    jmp     5b
6:  test    edx, edx
    jns     61f
    test    ebp, ebp                    # no group next to it (islands): the
    jnz     .Lbg_skip                   #   one made before, if it has room
    mov     edx, [rip+bg_g]
    dec     edx
    js      .Lbg_skip
    mov     eax, [r15+rdx*4]
    add     eax, r8d
    cmp     eax, GTMAX
    ja      .Lbg_skip
61: add     [r15+rdx*4], r8d            # merged: the group was the last made
    lea     eax, [rdx+1]
    xor     ecx, ecx
7:  cmp     ecx, [rip+bg_n]
    jae     8f
    lea     rsi, [rip+bg_mem]
    mov     esi, [rsi+rcx*4]
    mov     [r14+rsi*4], eax
    inc     ecx
    jmp     7b
8:  dec     dword ptr [rsp+BG_GN]
.Lbg_skip:
    inc     ebx
    jmp     .Lbg_next
.Lbg_lists:                             # the records and member lists
    mov     ebx, [rsp+BG_GN]
    mov     r15d, [rip+ng]
    xor     ecx, ecx
1:  cmp     ecx, ebx
    jae     2f
    lea     eax, [r15+rcx]
    imul    rax, rax, GR_SZ
    add     rax, [rip+gr]
    mov     dword ptr [rax+GR_NMEM], 0
    mov     dword ptr [rax+GR_NPAR], 0
    mov     edx, [rip+nlv]
    dec     edx
    mov     [rax+GR_LEVEL], edx
    inc     ecx
    jmp     1b
2:  xor     ecx, ecx                    # count
3:  cmp     ecx, [rsp+BG_NCL]
    jae     4f
    mov     eax, [r14+rcx*4]
    dec     eax
    add     eax, r15d
    imul    rax, rax, GR_SZ
    add     rax, [rip+gr]
    inc     dword ptr [rax+GR_NMEM]
    inc     ecx
    jmp     3b
4:  mov     edx, [rip+nm]               # first member of each
    xor     ecx, ecx
5:  cmp     ecx, ebx
    jae     6f
    lea     eax, [r15+rcx]
    imul    rax, rax, GR_SZ
    add     rax, [rip+gr]
    mov     [rax+GR_MEM], edx
    add     edx, [rax+GR_NMEM]
    inc     ecx
    jmp     5b
6:  mov     [rip+nm], edx
    xor     ecx, ecx                    # fill (GR_NPAR counts, for now)
7:  cmp     ecx, [rsp+BG_NCL]
    jae     8f
    mov     eax, [r14+rcx*4]
    dec     eax
    add     eax, r15d
    mov     r8d, eax
    imul    rax, rax, GR_SZ
    add     rax, [rip+gr]
    mov     edx, [rax+GR_MEM]
    add     edx, [rax+GR_NPAR]
    inc     dword ptr [rax+GR_NPAR]
    mov     esi, [rip+lo]
    add     esi, ecx
    mov     rdi, [rip+mem]
    mov     [rdi+rdx*4], esi
    shl     rsi, 4
    add     rsi, [rip+cb]
    lea     eax, [r8+1]
    mov     [rsi+CB_GRP], eax
    inc     ecx
    jmp     7b
8:  add     [rip+ng], ebx
.Lbg_out:
    add     rsp, 40
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# bg_add(edi=cluster) - into group bg_g (bd_group's registers: r12/r13
#   neighbours, r14 groups, ebp candidates; its triangles at [rsp+8+BG_GTR])
bg_add:
    mov     eax, [rip+bg_g]
    inc     eax
    mov     [r14+rdi*4], eax
    mov     eax, [rip+bg_n]
    cmp     eax, 64
    jae     1f
    lea     rcx, [rip+bg_mem]
    mov     [rcx+rax*4], edi
1:  inc     dword ptr [rip+bg_n]
    mov     eax, [rip+lo]
    add     eax, edi
    shl     rax, 4
    add     rax, [rip+cb]
    mov     eax, [rax+CB_NT]
    mov     rcx, [rsp+8+BG_GTR]
    mov     edx, [rip+bg_g]
    add     [rcx+rdx*4], eax
    mov     r10, [rip+csrc]             # (who made it: edges to clusters
    mov     r11d, [rip+lo]              #   another group made count more, so
    add     r11d, edi                   #   groups straddle the old borders
    mov     r11d, [r10+r11*4]           #   and those get simplified)
    mov     r8d, [r12+rdi*4]            # its neighbours: candidates
    mov     r9d, [r12+rdi*4+4]
1:  cmp     r8d, r9d
    jae     9f
    mov     eax, [r13+r8*4]
    inc     r8d
    cmp     dword ptr [r14+rax*4], 0
    jne     1b
    mov     edi, 1
    mov     esi, [rip+lo]
    add     esi, eax
    cmp     [r10+rsi*4], r11d
    je      11f
    mov     edi, 4
11: lea     rsi, [rip+cid]
    lea     rdx, [rip+csc]
    xor     ecx, ecx
2:  cmp     ecx, ebp
    jae     3f
    cmp     [rsi+rcx*4], eax
    je      4f
    inc     ecx
    jmp     2b
3:  cmp     ebp, 512
    jae     1b
    mov     [rsi+rbp*4], eax
    mov     [rdx+rbp*4], edi
    inc     ebp
    jmp     1b
4:  add     [rdx+rcx*4], edi
    jmp     1b
9:  ret

# job_group(rdi=batch, esi..edx, r8=arena) - simplify and split groups
job_group:
    push    rbx
    push    r12
    push    r13
    mov     r12, r8
    lea     ebx, [rdi+rsi]
    lea     r13d, [rdi+rdx]
1:  cmp     ebx, r13d
    jae     9f
    test    r12, r12
    jz      9f
    mov     rdi, r12
    call    arena_reset
    mov     edi, ebx
    mov     rsi, r12
    call    grp_work
    inc     ebx
    jmp     1b
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# grp_work(edi=group (local), rsi=arena) - its members' triangles, their
#   border locked, simplified to half and split into clusters: ot / os at
#   gin, gonc, gont, goerr
.equ GW_GI,     0
.equ GW_AR,     8
.equ GW_N,      16
.equ GW_NV,     20
.equ GW_GL,     24
.equ GW_LT,     32
.equ GW_GID,    40
.equ GW_POS,    48
.equ GW_LOCK,   56
.equ GW_NN,     64
.equ GW_ERR,    72                      # double
.equ GW_NCL,    80
.equ GW_ORDER,  88
grp_work:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 104
    mov     [rsp+GW_GI], edi
    mov     [rsp+GW_AR], rsi
    mov     eax, [rip+glo]
    add     eax, edi
    imul    rax, rax, GR_SZ
    add     rax, [rip+gr]
    mov     r12d, [rax+GR_MEM]
    mov     r13d, [rax+GR_NMEM]
    mov     rcx, [rip+gin]              # triangles: from the prefix
    mov     edx, [rcx+rdi*4+4]
    sub     edx, [rcx+rdi*4]
    mov     [rsp+GW_N], edx
    test    edx, edx
    jz      .Lgw_empty
    mov     rdi, rsi
    lea     esi, [rdx+rdx*2]
    lea     rsi, [rsi*4+16]
    call    arena_alloc
    test    rax, rax
    jz      .Lgw_empty
    mov     [rsp+GW_GL], rax
    mov     rdi, rax                    # gather
1:  test    r13d, r13d
    jz      2f
    mov     rax, [rip+mem]
    mov     eax, [rax+r12*4]
    shl     rax, 4
    add     rax, [rip+cb]
    mov     ecx, [rax+CB_TOFF]
    lea     rcx, [rcx+rcx*2]
    mov     rsi, [rip+bt]
    lea     rsi, [rsi+rcx*4]
    mov     ecx, [rax+CB_NT]
    lea     ecx, [rcx+rcx*2]
    rep     movsd
    inc     r12d
    dec     r13d
    jmp     1b
2:  mov     rdi, [rsp+GW_GL]
    mov     esi, [rsp+GW_N]
    mov     rdx, [rsp+GW_AR]
    call    localize
    mov     [rsp+GW_LT], rax
    mov     [rsp+GW_GID], rdx
    mov     [rsp+GW_NV], ecx
    mov     rdi, [rsp+GW_AR]            # positions (doubles, from the first)
    lea     rsi, [rcx+rcx*2]
    lea     rsi, [rsi*8+16]
    call    arena_alloc
    mov     [rsp+GW_POS], rax
    mov     rdi, [rsp+GW_AR]
    mov     esi, [rsp+GW_NV]
    add     esi, 16
    call    zalloc
    mov     [rsp+GW_LOCK], rax
    mov     r8, [rsp+GW_GID]
    mov     r9, [rip+w_q]
    mov     r10, [rsp+GW_POS]
    mov     eax, [r8]
    lea     rax, [rax+rax*2]
    movdqu  xmm7, [r9+rax*4]
    xor     ecx, ecx
3:  cmp     ecx, [rsp+GW_NV]
    jae     4f
    mov     eax, [r8+rcx*4]
    lea     rax, [rax+rax*2]
    movdqu  xmm0, [r9+rax*4]
    psubd   xmm0, xmm7
    cvtdq2pd xmm1, xmm0
    pshufd  xmm0, xmm0, 0xaa
    cvtdq2pd xmm0, xmm0
    lea     rax, [rcx+rcx*2]
    movupd  [r10+rax*8], xmm1
    movsd   [r10+rax*8+16], xmm0
    inc     ecx
    jmp     3b
4:  call    gw_lock                     # the group's border
    mov     rdi, [rsp+GW_LT]
    mov     esi, [rsp+GW_N]
    mov     edx, [rsp+GW_NV]
    mov     rcx, [rsp+GW_POS]
    mov     r8, [rsp+GW_LOCK]
    mov     r9, [rsp+GW_AR]
    call    simplify
    mov     [rsp+GW_NN], eax
    movsd   [rsp+GW_ERR], xmm0
    mov     rcx, [rsp+GW_GI]            # split
    mov     ecx, ecx
    mov     rdx, [rip+gin]
    mov     r8d, [rdx+rcx*4]
    shl     r8, 2
    add     r8, [rip+os]
    mov     rdi, [rsp+GW_LT]
    mov     esi, eax
    mov     edx, [rsp+GW_NV]
    mov     rcx, [rsp+GW_AR]
    call    part_local
    mov     [rsp+GW_NCL], eax
    mov     [rsp+GW_ORDER], rdx
    mov     ecx, [rsp+GW_GI]            # the triangles, cluster by cluster
    mov     rax, [rip+gin]
    mov     edi, [rax+rcx*4]
    lea     rdi, [rdi+rdi*2]
    shl     rdi, 2
    add     rdi, [rip+ot]
    mov     r8, [rsp+GW_LT]
    mov     r9, [rsp+GW_GID]
    mov     r10, [rsp+GW_ORDER]
    xor     ecx, ecx
5:  cmp     ecx, [rsp+GW_NN]
    jae     6f
    mov     eax, [r10+rcx*4]
    lea     rax, [rax+rax*2]
    mov     edx, [r8+rax*4]
    mov     edx, [r9+rdx*4]
    mov     [rdi], edx
    mov     edx, [r8+rax*4+4]
    mov     edx, [r9+rdx*4]
    mov     [rdi+4], edx
    mov     edx, [r8+rax*4+8]
    mov     edx, [r9+rdx*4]
    mov     [rdi+8], edx
    add     rdi, 12
    inc     ecx
    jmp     5b
6:  mov     ecx, [rsp+GW_GI]
    mov     rax, [rip+gonc]
    mov     edx, [rsp+GW_NCL]
    mov     [rax+rcx*4], edx
    mov     rax, [rip+gont]
    mov     edx, [rsp+GW_NN]
    mov     [rax+rcx*4], edx
    movsd   xmm0, [rsp+GW_ERR]          # error: grid steps -> world
    sqrtsd  xmm0, xmm0
    cvtsd2ss xmm0, xmm0
    mulss   xmm0, [rip+step]
    mov     rax, [rip+goerr]
    movss   [rax+rcx*4], xmm0
    jmp     9f
.Lgw_empty:
    mov     ecx, [rsp+GW_GI]
    xor     edx, edx
    mov     rax, [rip+gonc]
    mov     [rax+rcx*4], edx
    mov     rax, [rip+gont]
    mov     [rax+rcx*4], edx
    mov     rax, [rip+goerr]
    mov     [rax+rcx*4], edx
9:  add     rsp, 104
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# gw_lock - grp_work's border: both ends of every directed edge whose twin
#   is not in the group are locked (frame at rsp+8)
gw_lock:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    lea     rbx, [rsp+48]               # grp_work's frame
    mov     r13, [rbx+GW_LT]
    mov     r14d, [rbx+GW_N]
    lea     r14d, [r14+r14*2]
    mov     r12d, 64
1:  lea     eax, [r14+r14]
    cmp     r12d, eax
    jae     2f
    add     r12d, r12d
    jmp     1b
2:  mov     rdi, [rbx+GW_AR]
    lea     rsi, [r12*8]
    call    zalloc
    mov     r15, rax
    dec     r12d
    mov     r8, 0x9e3779b97f4a7c15
    xor     ecx, ecx
3:  cmp     ecx, r14d
    jae     5f
    call    be_key
    mov     r9, rax
    imul    rax, r8
    shr     rax, 32
    and     eax, r12d
4:  mov     rdx, [r15+rax*8]
    test    rdx, rdx
    jz      41f
    cmp     rdx, r9
    je      42f
    inc     eax
    and     eax, r12d
    jmp     4b
41: mov     [r15+rax*8], r9
42: inc     ecx
    jmp     3b
5:  mov     r10, [rbx+GW_LOCK]
    xor     ecx, ecx
6:  cmp     ecx, r14d
    jae     9f
    call    be_key
    ror     rax, 32
    mov     r9, rax
    imul    rax, r8
    shr     rax, 32
    and     eax, r12d
7:  mov     rdx, [r15+rax*8]
    test    rdx, rdx
    jz      71f
    cmp     rdx, r9
    je      72f
    inc     eax
    and     eax, r12d
    jmp     7b
71: mov     eax, r9d                    # no twin: lock both ends
    dec     eax
    mov     byte ptr [r10+rax], 1
    shr     r9, 32
    dec     r9d
    mov     byte ptr [r10+r9], 1
72: inc     ecx
    jmp     6b
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Simplification: quadric error, half-edge collapses in passes (each pass
#  takes the cheapest collapses whose ends nothing else moved this pass)
# =============================================================================
# simplify(rdi=triangles (local), esi=n, edx=nv, rcx=positions (double x 3),
#   r8=locked (u8), r9=arena) -> eax = triangles kept (packed to the front),
#   xmm0 = the largest collapse cost (squared grid steps, double)
.equ SM_LT,     0
.equ SM_N,      8
.equ SM_NV,     12
.equ SM_POS,    16
.equ SM_LOCK,   24
.equ SM_AR,     32
.equ SM_Q,      40
.equ SM_ALIVE,  48
.equ SM_NALIVE, 56
.equ SM_TARGET, 60
.equ SM_TOUCH,  64
.equ SM_PASS,   72
.equ SM_ANY,    76
.equ SM_VOFF,   80
.equ SM_VLIST,  88
.equ SM_KEYS,   96
.equ SM_TMP,    104
.equ SM_NK,     112
.equ SM_SHARED, 116
.equ SM_ERR,    120
.equ SM_CNT,    128
.equ SM_NU,     136
.equ SM_NVL,    144
.equ SM_NNU,    152
.equ SM_NNV,    156
.equ SM_CUR,    160
.equ SM_PL,     168                     # 96 bytes: a plane's quadric, area
simplify:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 264
    mov     [rsp+SM_LT], rdi
    mov     [rsp+SM_N], esi
    mov     [rsp+SM_NV], edx
    mov     [rsp+SM_POS], rcx
    mov     [rsp+SM_LOCK], r8
    mov     [rsp+SM_AR], r9
    mov     [rsp+SM_NALIVE], esi
    mov     eax, esi
    shr     eax, 1
    mov     [rsp+SM_TARGET], eax
    xor     eax, eax
    mov     [rsp+SM_PASS], eax
    mov     [rsp+SM_ERR], rax
    mov     rdi, r9
    imul    rsi, rdx, 96
    add     rsi, 16
    call    zalloc
    mov     [rsp+SM_Q], rax
    mov     rdi, [rsp+SM_AR]
    mov     esi, [rsp+SM_N]
    add     esi, 16
    call    arena_alloc
    mov     [rsp+SM_ALIVE], rax
    mov     rdi, rax
    mov     ecx, [rsp+SM_N]
    mov     al, 1
    rep     stosb
    mov     rdi, [rsp+SM_AR]
    mov     esi, [rsp+SM_NV]
    lea     rsi, [rsi*4+16]
    call    zalloc
    mov     [rsp+SM_TOUCH], rax
    mov     ebx, [rsp+SM_N]
    imul    ebx, ebx, 6
    mov     rdi, [rsp+SM_AR]
    lea     rsi, [rbx*8+16]
    call    arena_alloc
    mov     [rsp+SM_KEYS], rax
    mov     rdi, [rsp+SM_AR]
    lea     rsi, [rbx*8+16]
    call    arena_alloc
    mov     [rsp+SM_TMP], rax
    mov     rdi, [rsp+SM_AR]
    mov     esi, 4096
    call    arena_alloc
    mov     [rsp+SM_CNT], rax
    mov     rdi, [rsp+SM_AR]
    mov     esi, 1024
    call    arena_alloc
    mov     [rsp+SM_NU], rax
    mov     rdi, [rsp+SM_AR]
    mov     esi, 1024
    call    arena_alloc
    mov     [rsp+SM_NVL], rax
    mov     rdi, [rsp+SM_AR]
    mov     esi, [rsp+SM_NV]
    lea     rsi, [rsi*4+16]
    call    arena_alloc
    mov     [rsp+SM_VOFF], rax
    mov     rdi, [rsp+SM_AR]
    mov     esi, [rsp+SM_NV]
    lea     rsi, [rsi*4+16]
    call    arena_alloc
    mov     [rsp+SM_CUR], rax
    mov     rdi, [rsp+SM_AR]
    mov     esi, [rsp+SM_N]
    lea     esi, [rsi+rsi*2]
    lea     rsi, [rsi*4+16]
    call    arena_alloc
    mov     [rsp+SM_VLIST], rax
    test    rax, rax
    jz      .Lsm_done
    xor     ebx, ebx                    # the planes' quadrics
1:  cmp     ebx, [rsp+SM_N]
    jae     .Lsm_pass
    mov     edi, ebx
    call    sm_plane
    inc     ebx
    jmp     1b
.Lsm_pass:
    mov     eax, [rsp+SM_NALIVE]
    cmp     eax, [rsp+SM_TARGET]
    jbe     .Lsm_done
    cmp     dword ptr [rsp+SM_PASS], 32
    jae     .Lsm_done
    inc     dword ptr [rsp+SM_PASS]
    mov     dword ptr [rsp+SM_ANY], 0
    # vertex -> live triangles
    mov     rdi, [rsp+SM_VOFF]
    mov     ecx, [rsp+SM_NV]
    inc     ecx
    xor     eax, eax
    rep     stosd
    mov     r8, [rsp+SM_VOFF]
    mov     r9, [rsp+SM_LT]
    mov     r10, [rsp+SM_ALIVE]
    xor     ecx, ecx
1:  cmp     ecx, [rsp+SM_N]
    jae     2f
    cmp     byte ptr [r10+rcx], 0
    je      11f
    lea     rax, [rcx+rcx*2]
    mov     edx, [r9+rax*4]
    inc     dword ptr [r8+rdx*4+4]
    mov     edx, [r9+rax*4+4]
    inc     dword ptr [r8+rdx*4+4]
    mov     edx, [r9+rax*4+8]
    inc     dword ptr [r8+rdx*4+4]
11: inc     ecx
    jmp     1b
2:  mov     r11, [rsp+SM_CUR]
    xor     ecx, ecx
    xor     eax, eax
3:  cmp     ecx, [rsp+SM_NV]
    jae     4f
    mov     edx, [r8+rcx*4]
    mov     [r11+rcx*4], edx
    add     eax, [r8+rcx*4+4]
    mov     [r8+rcx*4+4], eax
    inc     ecx
    jmp     3b
4:  mov     rsi, [rsp+SM_VLIST]
    xor     ecx, ecx
5:  cmp     ecx, [rsp+SM_N]
    jae     6f
    cmp     byte ptr [r10+rcx], 0
    je      51f
    lea     rax, [rcx+rcx*2]
    mov     edx, [r9+rax*4]
    mov     edi, [r11+rdx*4]
    inc     dword ptr [r11+rdx*4]
    mov     [rsi+rdi*4], ecx
    mov     edx, [r9+rax*4+4]
    mov     edi, [r11+rdx*4]
    inc     dword ptr [r11+rdx*4]
    mov     [rsi+rdi*4], ecx
    mov     edx, [r9+rax*4+8]
    mov     edi, [r11+rdx*4]
    inc     dword ptr [r11+rdx*4]
    mov     [rsi+rdi*4], ecx
51: inc     ecx
    jmp     5b
    # candidate collapses, both ways along every live edge
6:  mov     dword ptr [rsp+SM_NK], 0
    xor     ebx, ebx                    # entry 3t + e
7:  mov     eax, [rsp+SM_N]
    lea     eax, [rax+rax*2]
    cmp     ebx, eax
    jae     .Lsm_sort
    mov     eax, ebx
    imul    rax, rax, 0x55555556
    shr     rax, 32
    mov     r10, [rsp+SM_ALIVE]
    cmp     byte ptr [r10+rax], 0
    je      75f
    lea     edx, [rax+rax*2+3]
    lea     ecx, [rbx+1]
    cmp     ecx, edx
    jb      71f
    sub     ecx, 3
71: mov     r9, [rsp+SM_LT]
    mov     r12d, [r9+rbx*4]            # a
    mov     r13d, [r9+rcx*4]            # b
    mov     r10, [rsp+SM_LOCK]
    cmp     byte ptr [r10+r12], 0
    jne     72f
    mov     edi, r12d
    mov     esi, r13d
    call    sm_cand
72: mov     r10, [rsp+SM_LOCK]
    cmp     byte ptr [r10+r13], 0
    jne     75f
    mov     edi, r13d
    mov     esi, r12d
    call    sm_cand
75: inc     ebx
    jmp     7b
.Lsm_sort:
    mov     rdi, [rsp+SM_KEYS]
    mov     rsi, [rsp+SM_TMP]
    mov     edx, [rsp+SM_NK]
    mov     ecx, 32
    mov     r8, [rsp+SM_CNT]
    call    radix10
    mov     rdi, [rsp+SM_TMP]
    mov     rsi, [rsp+SM_KEYS]
    mov     edx, [rsp+SM_NK]
    mov     ecx, 42
    mov     r8, [rsp+SM_CNT]
    call    radix10
    mov     rdi, [rsp+SM_KEYS]
    mov     rsi, [rsp+SM_TMP]
    mov     edx, [rsp+SM_NK]
    mov     ecx, 52
    mov     r8, [rsp+SM_CNT]
    call    radix10
    mov     rdi, [rsp+SM_TMP]
    mov     rsi, [rsp+SM_KEYS]
    mov     edx, [rsp+SM_NK]
    mov     ecx, 62
    mov     r8, [rsp+SM_CNT]
    call    radix10
    xor     ebx, ebx                    # cheapest first
.Lsm_try:
    cmp     ebx, [rsp+SM_NK]
    jae     .Lsm_end
    mov     eax, [rsp+SM_NALIVE]
    cmp     eax, [rsp+SM_TARGET]
    jbe     .Lsm_end
    mov     rax, [rsp+SM_KEYS]
    mov     r14, [rax+rbx*8]
    inc     ebx
    movzx   r12d, r14w                  # u
    mov     r13, r14
    shr     r13, 16
    movzx   r13d, r13w                  # v
    mov     rax, [rsp+SM_TOUCH]
    mov     ecx, [rsp+SM_PASS]
    cmp     [rax+r12*4], ecx
    je      .Lsm_try
    cmp     [rax+r13*4], ecx
    je      .Lsm_try
    call    sm_valid
    test    eax, eax
    jz      .Lsm_try
    mov     r8, [rsp+SM_VOFF]           # collapse u into v
    mov     r9, [rsp+SM_VLIST]
    mov     r10, [rsp+SM_LT]
    mov     r11, [rsp+SM_ALIVE]
    mov     ecx, [r8+r12*4]
    mov     edx, [r8+r12*4+4]
1:  cmp     ecx, edx
    jae     4f
    mov     eax, [r9+rcx*4]
    inc     ecx
    cmp     byte ptr [r11+rax], 0
    je      1b
    lea     rsi, [rax+rax*2]
    cmp     [r10+rsi*4], r13d
    je      2f
    cmp     [r10+rsi*4+4], r13d
    je      2f
    cmp     [r10+rsi*4+8], r13d
    je      2f
    xor     edi, edi                    # keeps: u -> v
3:  cmp     [r10+rsi*4], r12d
    jne     31f
    mov     [r10+rsi*4], r13d
31: inc     rsi
    inc     edi
    cmp     edi, 3
    jb      3b
    jmp     1b
2:  mov     byte ptr [r11+rax], 0       # has the edge: gone
    dec     dword ptr [rsp+SM_NALIVE]
    jmp     1b
4:  mov     rax, [rsp+SM_Q]             # Q[v] += Q[u]
    imul    rcx, r12, 96
    imul    rdx, r13, 96
    xor     esi, esi
5:  movupd  xmm0, [rax+rcx]
    movupd  xmm1, [rax+rdx]
    addpd   xmm0, xmm1
    movupd  [rax+rdx], xmm0
    add     rcx, 16
    add     rdx, 16
    inc     esi
    cmp     esi, 6
    jb      5b
    mov     rax, r14                    # its cost
    shr     rax, 32
    movd    xmm0, eax
    cvtss2sd xmm0, xmm0
    maxsd   xmm0, [rsp+SM_ERR]
    movsd   [rsp+SM_ERR], xmm0
    mov     rax, [rsp+SM_TOUCH]
    mov     ecx, [rsp+SM_PASS]
    mov     [rax+r12*4], ecx
    mov     [rax+r13*4], ecx
    inc     dword ptr [rsp+SM_ANY]
    jmp     .Lsm_try
.Lsm_end:                               # another pass, unless this one did
    mov     eax, [rsp+SM_ANY]           #   little (2% of what is left)
    imul    eax, eax, 50
    cmp     eax, [rsp+SM_NALIVE]
    jae     .Lsm_pass
.Lsm_done:
    mov     r8, [rsp+SM_LT]             # pack the live triangles
    mov     r9, [rsp+SM_ALIVE]
    xor     ecx, ecx
    xor     edx, edx
1:  cmp     ecx, [rsp+SM_N]
    jae     2f
    test    r9, r9
    jz      11f
    cmp     byte ptr [r9+rcx], 0
    je      12f
11: lea     rax, [rcx+rcx*2]
    lea     rsi, [rdx+rdx*2]
    mov     edi, [r8+rax*4]
    mov     [r8+rsi*4], edi
    mov     edi, [r8+rax*4+4]
    mov     [r8+rsi*4+4], edi
    mov     edi, [r8+rax*4+8]
    mov     [r8+rsi*4+8], edi
    inc     edx
12: inc     ecx
    jmp     1b
2:  mov     eax, edx
    movsd   xmm0, [rsp+SM_ERR]
    add     rsp, 264
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# sm_pos(eax=vertex) -> xmm0 x, xmm1 y, xmm2 z (frame at rsp+16: called from
#   a helper of simplify)
.macro SMPOS reg, base
    lea     rax, [\reg+\reg*2]
    mov     rdx, [\base+SM_POS]
    movsd   xmm0, [rdx+rax*8]
    movsd   xmm1, [rdx+rax*8+8]
    movsd   xmm2, [rdx+rax*8+16]
.endm

# qeval(rdi=quadric, xmm0..2 = point) -> xmm3 = its value (xmm4, xmm5)
qeval:
    movsd   xmm3, [rdi]
    mulsd   xmm3, xmm0
    movsd   xmm4, [rdi+8]
    mulsd   xmm4, xmm1
    addsd   xmm4, xmm4
    addsd   xmm3, xmm4
    movsd   xmm4, [rdi+16]
    mulsd   xmm4, xmm2
    addsd   xmm4, xmm4
    addsd   xmm3, xmm4
    movsd   xmm4, [rdi+24]
    addsd   xmm4, xmm4
    addsd   xmm3, xmm4
    mulsd   xmm3, xmm0
    movsd   xmm4, [rdi+32]
    mulsd   xmm4, xmm1
    movsd   xmm5, [rdi+40]
    mulsd   xmm5, xmm2
    addsd   xmm5, xmm5
    addsd   xmm4, xmm5
    movsd   xmm5, [rdi+48]
    addsd   xmm5, xmm5
    addsd   xmm4, xmm5
    mulsd   xmm4, xmm1
    addsd   xmm3, xmm4
    movsd   xmm4, [rdi+56]
    mulsd   xmm4, xmm2
    movsd   xmm5, [rdi+64]
    addsd   xmm5, xmm5
    addsd   xmm4, xmm5
    mulsd   xmm4, xmm2
    addsd   xmm3, xmm4
    addsd   xmm3, [rdi+72]
    ret

# sm_cand(edi=u, esi=v) - the collapse u -> v as a key (cost << 32 | u |
#   v << 16) (simplify's frame at rsp+8)
sm_cand:
    push    rbx
    push    r12
    lea     rbx, [rsp+24]
    mov     r12d, esi
    mov     r8d, edi
    SMPOS   r12, rbx
    mov     rdi, [rbx+SM_Q]
    imul    rax, r8, 96
    add     rdi, rax
    call    qeval
    movsd   xmm6, xmm3
    movsd   xmm7, [rdi+80]              # (the area behind it)
    mov     rdi, [rbx+SM_Q]
    imul    rax, r12, 96
    add     rdi, rax
    call    qeval
    addsd   xmm3, xmm6
    addsd   xmm7, [rdi+80]
    xorpd   xmm4, xmm4
    comisd  xmm7, xmm4
    jbe     1f
    divsd   xmm3, xmm7                  # mean squared distance
1:  maxsd   xmm3, xmm4
    cvtsd2ss xmm3, xmm3
    movd    eax, xmm3
    shl     rax, 32
    shl     r12d, 16
    or      r12d, r8d
    or      rax, r12
    mov     rcx, [rbx+SM_KEYS]
    mov     edx, [rbx+SM_NK]
    mov     [rcx+rdx*8], rax
    inc     dword ptr [rbx+SM_NK]
    pop     r12
    pop     rbx
    ret

# sm_plane(edi=triangle) - its plane's quadric added to its corners
#   (simplify's frame at rsp+8)
sm_plane:
    push    rbx
    push    r12
    push    r13
    lea     rbx, [rsp+32]
    mov     rax, [rbx+SM_LT]
    lea     rcx, [rdi+rdi*2]
    lea     r12, [rax+rcx*4]            # its corners
    mov     eax, [r12]
    SMPOS   rax, rbx
    movsd   xmm8, xmm0                  # p0
    movsd   xmm9, xmm1
    movsd   xmm10, xmm2
    mov     eax, [r12+4]
    SMPOS   rax, rbx
    subsd   xmm0, xmm8                  # e1
    subsd   xmm1, xmm9
    subsd   xmm2, xmm10
    movsd   xmm11, xmm0
    movsd   xmm12, xmm1
    movsd   xmm13, xmm2
    mov     eax, [r12+8]
    SMPOS   rax, rbx
    subsd   xmm0, xmm8                  # e2
    subsd   xmm1, xmm9
    subsd   xmm2, xmm10
    movsd   xmm3, xmm12                 # n = e1 x e2
    mulsd   xmm3, xmm2
    movsd   xmm4, xmm13
    mulsd   xmm4, xmm1
    subsd   xmm3, xmm4                  # nx = e1y e2z - e1z e2y
    movsd   xmm4, xmm13
    mulsd   xmm4, xmm0
    movsd   xmm5, xmm11
    mulsd   xmm5, xmm2
    subsd   xmm4, xmm5                  # ny = e1z e2x - e1x e2z
    movsd   xmm5, xmm11
    mulsd   xmm5, xmm1
    movsd   xmm6, xmm12
    mulsd   xmm6, xmm0
    subsd   xmm5, xmm6                  # nz = e1x e2y - e1y e2x
    movsd   xmm6, xmm3
    mulsd   xmm6, xmm3
    movsd   xmm7, xmm4
    mulsd   xmm7, xmm4
    addsd   xmm6, xmm7
    movsd   xmm7, xmm5
    mulsd   xmm7, xmm5
    addsd   xmm6, xmm7
    xorpd   xmm7, xmm7
    comisd  xmm6, xmm7
    jbe     9f                          # degenerate: no plane
    sqrtsd  xmm6, xmm6
    divsd   xmm3, xmm6                  # a b c
    divsd   xmm4, xmm6
    divsd   xmm5, xmm6
    mulsd   xmm6, [rip+d_half]
    movsd   xmm14, xmm6                 # the area: the plane's weight
    movsd   xmm6, xmm3                  # d = -(n . p0)
    mulsd   xmm6, xmm8
    movsd   xmm7, xmm4
    mulsd   xmm7, xmm9
    addsd   xmm6, xmm7
    movsd   xmm7, xmm5
    mulsd   xmm7, xmm10
    addsd   xmm6, xmm7
    xorpd   xmm7, xmm7
    subsd   xmm7, xmm6
    movsd   xmm6, xmm7
    lea     rdi, [rbx+SM_PL]
    movsd   xmm0, xmm3                  # a2 ab ac ad
    mulsd   xmm0, xmm3
    movsd   [rdi], xmm0
    movsd   xmm0, xmm3
    mulsd   xmm0, xmm4
    movsd   [rdi+8], xmm0
    movsd   xmm0, xmm3
    mulsd   xmm0, xmm5
    movsd   [rdi+16], xmm0
    movsd   xmm0, xmm3
    mulsd   xmm0, xmm6
    movsd   [rdi+24], xmm0
    movsd   xmm0, xmm4                  # b2 bc bd
    mulsd   xmm0, xmm4
    movsd   [rdi+32], xmm0
    movsd   xmm0, xmm4
    mulsd   xmm0, xmm5
    movsd   [rdi+40], xmm0
    movsd   xmm0, xmm4
    mulsd   xmm0, xmm6
    movsd   [rdi+48], xmm0
    movsd   xmm0, xmm5                  # c2 cd d2
    mulsd   xmm0, xmm5
    movsd   [rdi+56], xmm0
    movsd   xmm0, xmm5
    mulsd   xmm0, xmm6
    movsd   [rdi+64], xmm0
    movsd   xmm0, xmm6
    mulsd   xmm0, xmm6
    movsd   [rdi+72], xmm0
    movsd   xmm0, xmm14                 # x area
    unpcklpd xmm0, xmm0
    xor     ecx, ecx
0:  movupd  xmm1, [rdi+rcx]
    mulpd   xmm1, xmm0
    movupd  [rdi+rcx], xmm1
    add     ecx, 16
    cmp     ecx, 80
    jb      0b
    movsd   [rdi+80], xmm14
    xor     eax, eax
    mov     [rdi+88], rax
    xor     r13d, r13d
1:  mov     eax, [r12+r13*4]
    imul    rax, rax, 96
    add     rax, [rbx+SM_Q]
    xor     ecx, ecx
2:  movupd  xmm0, [rax+rcx]
    movupd  xmm1, [rdi+rcx]
    addpd   xmm0, xmm1
    movupd  [rax+rcx], xmm0
    add     ecx, 16
    cmp     ecx, 96
    jb      2b
    inc     r13d
    cmp     r13d, 3
    jb      1b
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# sm_valid (simplify's frame at rsp+8; r12 = u, r13 = v) -> eax = 1: the
#   collapse keeps the surface a manifold (link condition) and turns no
#   triangle over
sm_valid:
    push    rbx
    push    r14
    push    r15
    lea     rbx, [rsp+32]
    mov     dword ptr [rbx+SM_NNU], 0
    mov     dword ptr [rbx+SM_SHARED], 0
    mov     r8, [rbx+SM_VOFF]           # u's neighbours; triangles with v
    mov     r9, [rbx+SM_VLIST]
    mov     r10, [rbx+SM_LT]
    mov     r11, [rbx+SM_ALIVE]
    mov     r14d, [r8+r12*4]
    mov     r15d, [r8+r12*4+4]
1:  cmp     r14d, r15d
    jae     5f
    mov     eax, [r9+r14*4]
    inc     r14d
    cmp     byte ptr [r11+rax], 0
    je      1b
    lea     rsi, [rax+rax*2]
    xor     ecx, ecx
2:  mov     eax, [r10+rsi*4]
    cmp     eax, r13d
    jne     3f
    inc     dword ptr [rbx+SM_SHARED]
3:  cmp     eax, r12d
    je      4f
    mov     rdi, [rbx+SM_NU]
    lea     rdx, [rbx+SM_NNU]
    call    set_add
    test    eax, eax
    jz      .Lsv_no
4:  inc     rsi
    inc     ecx
    cmp     ecx, 3
    jb      2b
    jmp     1b
5:  cmp     dword ptr [rbx+SM_SHARED], 0
    je      .Lsv_no
    mov     dword ptr [rbx+SM_NNV], 0   # v's neighbours
    mov     r14d, [r8+r13*4]
    mov     r15d, [r8+r13*4+4]
1:  cmp     r14d, r15d
    jae     5f
    mov     eax, [r9+r14*4]
    inc     r14d
    cmp     byte ptr [r11+rax], 0
    je      1b
    lea     rsi, [rax+rax*2]
    xor     ecx, ecx
2:  mov     eax, [r10+rsi*4]
    cmp     eax, r13d
    je      4f
    mov     rdi, [rbx+SM_NVL]
    lea     rdx, [rbx+SM_NNV]
    call    set_add
    test    eax, eax
    jz      .Lsv_no
4:  inc     rsi
    inc     ecx
    cmp     ecx, 3
    jb      2b
    jmp     1b
5:  xor     r14d, r14d                  # common neighbours (not u, v)
    mov     rdi, [rbx+SM_NU]
    mov     rsi, [rbx+SM_NVL]
    xor     ecx, ecx
6:  cmp     ecx, [rbx+SM_NNU]
    jae     8f
    mov     eax, [rdi+rcx*4]
    inc     ecx
    cmp     eax, r13d
    je      6b
    xor     edx, edx
7:  cmp     edx, [rbx+SM_NNV]
    jae     6b
    cmp     [rsi+rdx*4], eax
    je      71f
    inc     edx
    jmp     7b
71: inc     r14d
    jmp     6b
8:  cmp     r14d, [rbx+SM_SHARED]
    jne     .Lsv_no
    mov     r14d, [r8+r12*4]            # no triangle of u turns over
    mov     r15d, [r8+r12*4+4]
.Lsv_flip:
    cmp     r14d, r15d
    jae     .Lsv_yes
    mov     eax, [r9+r14*4]
    inc     r14d
    cmp     byte ptr [r11+rax], 0
    je      .Lsv_flip
    lea     rsi, [rax+rax*2]
    lea     rsi, [r10+rsi*4]
    mov     eax, [rsi]
    cmp     eax, r13d
    je      .Lsv_flip
    cmp     dword ptr [rsi+4], r13d
    je      .Lsv_flip
    cmp     dword ptr [rsi+8], r13d
    je      .Lsv_flip
    call    sv_dup                      # the new triangle: already v's?
    test    eax, eax
    jnz     .Lsv_no
    xor     edi, edi                    # before
    call    tri_normal
    movsd   xmm8, xmm3
    movsd   xmm9, xmm4
    movsd   xmm10, xmm5
    mov     edi, 1                      # after
    call    tri_normal
    mulsd   xmm3, xmm8
    mulsd   xmm4, xmm9
    mulsd   xmm5, xmm10
    addsd   xmm3, xmm4
    addsd   xmm3, xmm5
    xorpd   xmm4, xmm4
    comisd  xmm3, xmm4
    jbe     .Lsv_no
    jmp     .Lsv_flip
.Lsv_yes:
    mov     eax, 1
    jmp     9f
.Lsv_no:
    xor     eax, eax
9:  pop     r15
    pop     r14
    pop     rbx
    ret

# sv_dup(rsi=corners of a triangle of u; rbx simplify's frame, r8 offsets,
#   r9 lists, r10 triangles, r11 alive, r12 u, r13 v) -> eax = 1: the
#   triangle it becomes is v's already, or has all three corners on the
#   group's border (it could be one next door): either folds a pillow
sv_dup:
    mov     rdi, [rbx+SM_LOCK]
    push    rbx
    push    r14
    push    r15
    xor     ecx, ecx                    # the corners other than u
    xor     ebx, ebx
    xor     edx, edx
1:  mov     eax, [rsi+rcx*4]
    cmp     eax, r12d
    je      2f
    test    ebx, ebx
    jnz     11f
    mov     ebx, eax
    inc     ebx
    jmp     2f
11: mov     edx, eax
2:  inc     ecx
    cmp     ecx, 3
    jb      1b
    dec     ebx                         # p, q
    cmp     byte ptr [rdi+r13], 0       # all three on the border: it might be
    je      21f                         #   a triangle of the group next door
    cmp     byte ptr [rdi+rbx], 0
    je      21f
    cmp     byte ptr [rdi+rdx], 0
    jne     7f
21: mov     r14d, [r8+r13*4]
    mov     r15d, [r8+r13*4+4]
3:  cmp     r14d, r15d
    jae     8f
    mov     eax, [r9+r14*4]
    inc     r14d
    cmp     byte ptr [r11+rax], 0
    je      3b
    lea     rax, [rax+rax*2]
    lea     rax, [r10+rax*4]
    xor     ecx, ecx                    # has p and q?
    cmp     [rax], ebx
    sete    cl
    cmp     [rax+4], ebx
    sete    ch
    or      cl, ch
    cmp     [rax+8], ebx
    sete    ch
    or      cl, ch
    test    cl, cl
    jz      3b
    xor     ecx, ecx
    cmp     [rax], edx
    sete    cl
    cmp     [rax+4], edx
    sete    ch
    or      cl, ch
    cmp     [rax+8], edx
    sete    ch
    or      cl, ch
    test    cl, cl
    jz      3b
7:  mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  pop     r15
    pop     r14
    pop     rbx
    ret

# set_add(eax=value, rdi=set, rdx=its count) -> eax = 0: full (256)
set_add:
    push    rcx
    mov     ecx, [rdx]
1:  test    ecx, ecx
    jz      2f
    dec     ecx
    cmp     [rdi+rcx*4], eax
    jne     1b
    mov     eax, 1
    pop     rcx
    ret
2:  mov     ecx, [rdx]
    cmp     ecx, 256
    jae     3f
    mov     [rdi+rcx*4], eax
    inc     dword ptr [rdx]
    mov     eax, 1
    pop     rcx
    ret
3:  xor     eax, eax
    pop     rcx
    ret

# tri_normal(rsi=corners, edi=1: u read as v; rbx = simplify's frame,
#   r12 = u, r13 = v) -> xmm3..5 = (p1 - p0) x (p2 - p0)
tri_normal:
    push    r14
    push    r15
    mov     r15d, edi
    xor     r14d, r14d
1:  mov     eax, [rsi+r14*4]
    test    r15d, r15d
    jz      2f
    cmp     eax, r12d
    cmove   eax, r13d
2:  push    rsi
    SMPOS   rax, rbx
    pop     rsi
    cmp     r14d, 0
    jne     3f
    movsd   xmm11, xmm0
    movsd   xmm12, xmm1
    movsd   xmm13, xmm2
    jmp     5f
3:  subsd   xmm0, xmm11
    subsd   xmm1, xmm12
    subsd   xmm2, xmm13
    cmp     r14d, 1
    jne     4f
    movsd   xmm14, xmm0
    movsd   xmm15, xmm1
    movsd   xmm6, xmm2
    jmp     5f
4:  movsd   xmm3, xmm15                 # e1 = (14, 15, 6), e2 = (0, 1, 2)
    mulsd   xmm3, xmm2
    movsd   xmm4, xmm6
    mulsd   xmm4, xmm1
    subsd   xmm3, xmm4
    movsd   xmm4, xmm6
    mulsd   xmm4, xmm0
    movsd   xmm5, xmm14
    mulsd   xmm5, xmm2
    subsd   xmm4, xmm5
    movsd   xmm5, xmm14
    mulsd   xmm5, xmm1
    movsd   xmm7, xmm15
    mulsd   xmm7, xmm0
    subsd   xmm5, xmm7
5:  inc     r14d
    cmp     r14d, 3
    jb      1b
    pop     r15
    pop     r14
    ret

# finish_group(edi=group (local)) -> xmm0 = its error: the group's error
#   (its simplification's + its members' largest) and LOD sphere (holding
#   its members'), given to its members as their parents' and to the
#   clusters it made, which are appended (level nlv)
finish_group:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 40
    mov     ebp, edi
    mov     eax, [rip+glo]
    add     eax, edi
    imul    rax, rax, GR_SZ
    add     rax, [rip+gr]
    mov     r15, rax
    mov     r12d, [r15+GR_MEM]
    mov     r13d, [r15+GR_NMEM]
    xorps   xmm7, xmm7                  # members' largest error
    movaps  xmm5, [rip+f_big4]          # box of their spheres
    movaps  xmm6, [rip+f_nbig4]
    mov     ecx, r12d
    mov     edx, r13d
1:  test    edx, edx
    jz      2f
    mov     rax, [rip+mem]
    mov     eax, [rax+rcx*4]
    shl     rax, 6
    add     rax, [rip+cr]
    maxss   xmm7, [rax+CR_ERR]
    movaps  xmm0, [rax+CR_LOD]
    movaps  xmm1, xmm0
    shufps  xmm1, xmm1, 0xff            # r
    movaps  xmm2, xmm0
    subps   xmm2, xmm1
    addps   xmm0, xmm1
    minps   xmm5, xmm2
    maxps   xmm6, xmm0
    inc     ecx
    dec     edx
    jmp     1b
2:  addps   xmm5, xmm6
    mulps   xmm5, [rip+f_half4]         # centre
    xorps   xmm4, xmm4                  # radius: holds every member's sphere
    mov     ecx, r12d
    mov     edx, r13d
3:  test    edx, edx
    jz      4f
    mov     rax, [rip+mem]
    mov     eax, [rax+rcx*4]
    shl     rax, 6
    add     rax, [rip+cr]
    movaps  xmm0, [rax+CR_LOD]
    movaps  xmm1, xmm0
    shufps  xmm1, xmm1, 0xff
    subps   xmm0, xmm5
    mulps   xmm0, xmm0
    movaps  xmm2, xmm0
    shufps  xmm2, xmm2, 0x55
    addss   xmm0, xmm2
    movhlps xmm2, xmm0
    addss   xmm0, xmm2
    sqrtss  xmm0, xmm0
    addss   xmm0, xmm1
    maxss   xmm4, xmm0
    inc     ecx
    dec     edx
    jmp     3b
4:  mulss   xmm4, [rip+f_grow]
    addss   xmm4, [rip+f_tiny]
    insertps xmm5, xmm4, 0x30
    movaps  [rsp], xmm5                 # the sphere
    mov     rax, [rip+goerr]
    movss   xmm0, [rax+rbp*4]
    addss   xmm0, xmm7
    movss   [rsp+16], xmm0              # the error
    movss   [r15+GR_ERR], xmm0
    movups  [r15+GR_LOD], xmm5
    mov     ecx, r12d                   # the members' parent
    mov     edx, r13d
5:  test    edx, edx
    jz      6f
    mov     rax, [rip+mem]
    mov     eax, [rax+rcx*4]
    shl     rax, 6
    add     rax, [rip+cr]
    movss   [rax+CR_PERR], xmm0
    movaps  [rax+CR_PLOD], xmm5
    inc     ecx
    dec     edx
    jmp     5b
6:  mov     eax, [rip+nc]               # the clusters it made
    mov     [r15+GR_PAR], eax
    mov     rax, [rip+gonc]
    mov     eax, [rax+rbp*4]
    mov     [r15+GR_NPAR], eax
    mov     r13d, eax
    mov     rax, [rip+gin]
    mov     r12d, [rax+rbp*4]           # its slot in ot / os
    mov     r14d, r12d                  # triangle read
7:  test    r13d, r13d
    jz      9f
    mov     rax, [rip+os]
    mov     esi, [rax+r12*4]
    mov     edi, [rip+bt_n]
    call    new_cluster
    mov     ebx, [rax+CB_NT]
    mov     rdi, [rip+bt_n]
    mov     edi, edi
    lea     rdi, [rdi+rdi*2]
    shl     rdi, 2
    add     rdi, [rip+bt]
    lea     rsi, [r14+r14*2]
    shl     rsi, 2
    add     rsi, [rip+ot]
    lea     ecx, [rbx+rbx*2]
    rep     movsd
    add     [rip+bt_n], ebx
    add     r14d, ebx
    mov     eax, [rip+nc]
    dec     eax
    shl     rax, 6
    add     rax, [rip+cr]
    movaps  xmm5, [rsp]
    movaps  [rax+CR_LOD], xmm5
    movaps  [rax+CR_PLOD], xmm5
    movss   xmm0, [rsp+16]
    movss   [rax+CR_ERR], xmm0
    mov     ecx, [rip+f_maxf]
    mov     [rax+CR_PERR], ecx
    mov     ecx, [rip+nlv]
    mov     [rax+CR_LEVEL], cl
    mov     eax, [rip+nc]               # (made by this group)
    dec     eax
    mov     rcx, [rip+csrc]
    mov     edx, [rip+glo]
    lea     edx, [rdx+rbp+1]
    mov     [rcx+rax*4], edx
    inc     r12d
    dec     r13d
    jmp     7b
9:  movss   xmm0, [rsp+16]
    add     rsp, 40
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Packing the block
# =============================================================================
# bd_pack -> rax = the DAG block (0: no memory)
bd_pack:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 24
    mov     rbp, [rip+cr]               # data offsets (16-byte units)
    mov     r8, [rip+cb]
    xor     ecx, ecx
    xor     edx, edx
    xor     r9d, r9d                    # all triangles
1:  cmp     ecx, [rip+nc]
    jae     2f
    mov     [rbp+CR_DATA], edx
    mov     eax, [r8+CB_NV]
    mov     [rbp+CR_NV], al
    shl     eax, 4
    mov     esi, [r8+CB_NT]
    mov     [rbp+CR_NT], sil
    add     r9d, esi
    lea     esi, [rsi+rsi*2+15]
    and     esi, -16
    add     eax, esi
    shr     eax, 4
    add     edx, eax
    add     rbp, CR_SZ
    add     r8, CB_SZ
    inc     ecx
    jmp     1b
2:  mov     [rsp], r9d
    mov     ebx, edx
    shl     rbx, 4                      # data bytes
    mov     eax, [rip+nc]
    shl     rax, 6
    mov     r12, rax                    # clusters
    mov     eax, [rip+ng]
    imul    rax, rax, GR_SZ
    mov     r13, rax                    # groups
    mov     eax, [rip+nm]
    shl     rax, 2
    mov     r14, rax                    # members
    lea     r15, [r12+r13+VH_SZ+4095]
    add     r15, r14
    and     r15, -4096                  # data offset
    lea     rsi, [r15+rbx+4095]
    and     rsi, -4096
    mov     [rsp+8], rsi
    xor     edi, edi
    mov     edx, PROT_RW
    mov     r10d, MAP_ANON_PRIV
    mov     r8, -1
    xor     r9d, r9d
    mov     eax, SYS_MMAP
    syscall
    cmp     rax, -4096
    jb      3f
    xor     eax, eax
    jmp     9f
3:  mov     rbp, rax
    mov     dword ptr [rbp+VH_MAGIC], VG_MAGIC
    mov     dword ptr [rbp+VH_VER], VG_VERSION
    mov     dword ptr [rbp+VH_REFS], 1
    mov     eax, [rip+nc]
    mov     [rbp+VH_NCL], eax
    mov     eax, [rip+ng]
    mov     [rbp+VH_NGR], eax
    mov     eax, [rip+nlv]
    mov     [rbp+VH_NLV], eax
    mov     eax, [rip+nt0]
    mov     [rbp+VH_STRI], eax
    mov     eax, [rip+w_n]
    mov     [rbp+VH_SVERT], eax
    movaps  xmm0, [rip+bmin]
    movups  [rbp+VH_BMIN], xmm0
    mov     eax, [rip+step]
    mov     [rbp+VH_STEP], eax
    mov     rax, [rip+s_hash]
    mov     [rbp+VH_HASH], rax
    mov     eax, [rsp]
    mov     [rbp+VH_TTRI], eax
    mov     eax, [rip+nm]
    mov     [rbp+VH_NMEM], eax
    mov     qword ptr [rbp+VH_OCL], VH_SZ
    lea     rax, [r12+VH_SZ]
    mov     [rbp+VH_OGR], rax
    add     rax, r13
    mov     [rbp+VH_OMEM], rax
    mov     [rbp+VH_ODATA], r15
    mov     [rbp+VH_DBYTES], rbx
    mov     rax, [rsp+8]
    mov     [rbp+VH_BYTES], rax
    lea     rdi, [rbp+VH_LV]
    lea     rsi, [rip+lv]
    mov     ecx, 16*VG_MAXLV/4
    rep     movsd
    lea     rdi, [rbp+VH_SZ]
    mov     rsi, [rip+cr]
    mov     rcx, r12
    rep     movsb
    mov     rsi, [rip+gr]
    mov     rcx, r13
    rep     movsb
    mov     rsi, [rip+mem]
    mov     rcx, r14
    rep     movsb
    mov     ecx, [rip+nc]               # roots, the largest error
    mov     rsi, [rip+cr]
    xor     edx, edx
    xorps   xmm0, xmm0
    mov     edi, [rip+f_maxf]
4:  test    ecx, ecx
    jz      5f
    maxss   xmm0, [rsi+CR_ERR]
    cmp     [rsi+CR_PERR], edi
    jne     41f
    inc     edx
41: add     rsi, CR_SZ
    dec     ecx
    jmp     4b
5:  mov     [rbp+VH_ROOTS], edx
    movss   [rbp+VH_RERR], xmm0
    mov     [rip+pk_block], rbp
    lea     rdi, [rip+job_pack]
    mov     esi, [rip+nc]
    mov     edx, 1<<16
    mov     ecx, 64
    call    pfor
    mov     rax, rbp
9:  add     rsp, 24
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# job_pack(rdi=batch, esi..edx) - the clusters' data: vertices (grid x y z,
#   octahedral normal) in first-use order, then the triangles (u8 x 3)
job_pack:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 2048+8                 # table: welded id + 1, local index
    lea     ebx, [rdi+rsi]
    lea     r12d, [rdi+rdx]
.Ljp_next:
    cmp     ebx, r12d
    jae     .Ljp_out
    lea     rdi, [rsp+8]
    mov     ecx, 256
    xor     eax, eax
    rep     stosq
    mov     rbp, [rip+pk_block]
    mov     rax, rbx
    shl     rax, 6
    lea     r13, [rbp+rax+VH_SZ]        # its record
    mov     eax, [r13+CR_DATA]
    shl     rax, 4
    add     rax, [rbp+VH_ODATA]
    lea     r14, [rbp+rax]              # vertices
    movzx   eax, byte ptr [r13+CR_NV]
    shl     eax, 4
    lea     r15, [r14+rax]              # triangles
    mov     rax, rbx
    shl     rax, 4
    add     rax, [rip+cb]
    mov     ecx, [rax+CB_TOFF]
    lea     rcx, [rcx+rcx*2]
    shl     rcx, 2
    add     rcx, [rip+bt]
    mov     r8, rcx
    mov     r9d, [rax+CB_NT]
    lea     r9d, [r9+r9*2]
    xor     ecx, ecx                    # entry
    xor     r10d, r10d                  # vertices so far
1:  cmp     ecx, r9d
    jae     8f
    mov     esi, [r8+rcx*4]
    lea     r11d, [rsi+1]
    imul    eax, r11d, 0x9e3779b1
    shr     eax, 24
2:  mov     edx, [rsp+rax*8+8]
    test    edx, edx
    jz      3f
    cmp     edx, r11d
    je      4f
    inc     eax
    and     eax, 255
    jmp     2b
3:  mov     [rsp+rax*8+8], r11d
    mov     [rsp+rax*8+12], r10d
    mov     edx, r10d
    inc     r10d
    push    rcx
    push    r8
    mov     edi, esi
    mov     rsi, r14
    shl     rdx, 4
    add     rsi, rdx
    call    put_vertex
    pop     r8
    pop     rcx
    mov     eax, r10d
    dec     eax
    mov     [r15+rcx], al
    inc     ecx
    jmp     1b
4:  mov     eax, [rsp+rax*8+12]
    mov     [r15+rcx], al
    inc     ecx
    jmp     1b
8:  inc     ebx
    jmp     .Ljp_next
.Ljp_out:
    add     rsp, 2048+8
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# put_vertex(edi=welded id, rsi=out 16 bytes) - grid x y z and the normal
#   (octahedral, 2 x i16)
put_vertex:
    lea     rax, [rdi+rdi*2]
    mov     rcx, [rip+w_q]
    mov     edx, [rcx+rax*4]
    mov     [rsi], edx
    mov     edx, [rcx+rax*4+4]
    mov     [rsi+4], edx
    mov     edx, [rcx+rax*4+8]
    mov     [rsi+8], edx
    mov     rcx, [rip+w_nrm]
    movups  xmm0, [rcx+rax*4]
    jmp     oct_store

# oct_store(xmm0 = normal x y z, rsi = out: its 16 bytes, writes [rsi+12])
oct_store:
    movaps  xmm1, xmm0
    andps   xmm1, [rip+f_absm]
    movaps  xmm2, xmm1                  # |x| + |y| + |z|
    shufps  xmm2, xmm2, 0x55
    addss   xmm2, xmm1
    movaps  xmm3, xmm1
    movhlps xmm3, xmm3
    addss   xmm2, xmm3
    xorps   xmm3, xmm3
    comiss  xmm2, xmm3
    ja      1f
    mov     dword ptr [rsi+12], 0x7fff0000  # (no normal: +z)
    ret
1:  shufps  xmm2, xmm2, 0
    divps   xmm0, xmm2                  # on the octahedron
    movaps  xmm1, xmm0
    shufps  xmm1, xmm1, 0xaa            # z
    comiss  xmm1, xmm3
    jae     2f
    movaps  xmm1, xmm0                  # lower half: folded
    andps   xmm1, [rip+f_absm]
    shufps  xmm1, xmm1, 0xe1            # |y| |x|
    movss   xmm2, [rip+f_one]
    shufps  xmm2, xmm2, 0
    subps   xmm2, xmm1                  # 1 - |y|, 1 - |x|
    movaps  xmm1, xmm0                  # with the signs of x, y
    andps   xmm1, [rip+f_sign]
    orps    xmm2, xmm1
    movaps  xmm0, xmm2
2:  movss   xmm1, [rip+f_32767]
    shufps  xmm1, xmm1, 0
    mulps   xmm0, xmm1
    cvtps2dq xmm0, xmm0
    movd    eax, xmm0
    pextrd  edx, xmm0, 1
    shl     edx, 16
    and     eax, 0xffff
    or      eax, edx
    mov     [rsi+12], eax
    ret

# =============================================================================
#  The build
# =============================================================================
# vg_run - the DAG of the snapshot -> vg_out (0: failed); the builder's
#   memory is given back
vg_run:
    push    rbx
    call    now_ms
    mov     [rip+vg_t0], rax
    mov     qword ptr [rip+vg_out], 0
    call    bd_weld
    test    eax, eax
    jz      8f
    call    bd_alloc
    test    eax, eax
    jz      8f
    call    bd_level0
    test    eax, eax
    jz      8f
1:  call    bd_level
    test    eax, eax
    jnz     1b
    cmp     dword ptr [rip+vg_fail], 0
    jne     8f
    call    bd_pack
    test    rax, rax
    jz      8f
    mov     rbx, rax
    call    now_ms
    sub     rax, [rip+vg_t0]
    mov     [rbx+VH_MS], eax
    mov     [rip+vg_out], rbx
8:  xor     edi, edi
    call    vfree_to
    pop     rbx
    ret

# vg_thread(rdi) - the background thread's job
vg_thread:
    sub     rsp, 8
    call    vg_run
    mov     dword ptr [rip+vg_state], 2 # built: the UI thread attaches it
    add     rsp, 8
    ret

# vg_build_mesh(rdi=mesh) -> rax = its DAG, built now (0: failed); the mesh
#   keeps a reference
vg_build_mesh:
    push    rbx
    mov     rbx, rdi
    call    vg_snap
    test    eax, eax
    jz      8f
    call    vg_run
    mov     rsi, [rip+vg_out]
    test    rsi, rsi
    jz      8f
    mov     rdi, rbx
    call    vg_attach
    mov     rax, [rip+vg_out]
    pop     rbx
    ret
8:  xor     eax, eax
    pop     rbx
    ret

# =============================================================================
#  The DAG of a mesh
# =============================================================================
# vg_ref(rdi=dag) / vg_unref(rdi=dag) - shared by a mesh's copies; the last
#   reference unmaps it
vg_ref:
    test    rdi, rdi
    jz      1f
    lock inc dword ptr [rdi+VH_REFS]
1:  ret
vg_unref:
    test    rdi, rdi
    jz      1f
    lock dec dword ptr [rdi+VH_REFS]
    jnz     1f
    mov     rsi, [rdi+VH_BYTES]
    mov     eax, SYS_MUNMAP
    syscall
1:  ret

# vg_attach(rdi=mesh, rsi=dag) - the mesh's DAG (its reference taken over;
#   the old one let go)
vg_attach:
    mov     rax, [rdi+ME_VGEO]
    mov     [rdi+ME_VGEO], rsi
    cmp     rax, rsi
    je      1f
    mov     rdi, rax
    jmp     vg_unref
1:  ret

# vg_get(rdi=mesh) -> rax = its DAG when it was built from the mesh as it
#   is now (0: none, or the mesh was edited since)
vg_get:
    test    rdi, rdi
    jz      8f
    mov     rax, [rdi+ME_VGEO]
    test    rax, rax
    jz      9f
    push    rbx
    mov     rbx, rax
    mov     rax, 0xcbf29ce484222325
    call    sc_meshhash
    cmp     rax, [rbx+VH_HASH]
    mov     rax, rbx
    pop     rbx
    je      9f
8:  xor     eax, eax
9:  ret

# proj(xmm0=error, rdi=sphere, rsi=camera or 0) -> xmm0: the error seen from
#   the camera (error / distance to the sphere), or as it is
proj:
    test    rsi, rsi
    jz      9f
    movups  xmm1, [rdi]
    movss   xmm3, [rdi+12]
    movsd   xmm2, [rsi]
    insertps xmm2, [rsi+8], 0x20
    subps   xmm1, xmm2
    mulps   xmm1, xmm1
    movaps  xmm2, xmm1
    shufps  xmm2, xmm2, 0x55
    addss   xmm2, xmm1
    movhlps xmm1, xmm1
    addss   xmm2, xmm1
    sqrtss  xmm2, xmm2
    subss   xmm2, xmm3
    maxss   xmm2, [rip+f_tiny]
    divss   xmm0, xmm2
9:  ret

# vg_select(rdi=dag, xmm0=threshold, rsi=camera (x y z) or 0, rdx=out: a
#   byte per cluster) -> eax = clusters chosen, edx = their triangles: the
#   cut "error <= t < parent error" (projected from the camera when given)
vg_select:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 24
    movss   [rsp], xmm0
    mov     r12, rsi
    mov     r13, rdx
    mov     ebp, [rdi+VH_NCL]
    lea     rbx, [rdi+VH_SZ]
    xor     r14d, r14d
    xor     r15d, r15d
    xor     ecx, ecx
1:  cmp     ecx, ebp
    jae     9f
    mov     [rsp+4], ecx
    mov     byte ptr [r13+rcx], 0
    movss   xmm0, [rbx+CR_ERR]
    lea     rdi, [rbx+CR_LOD]
    mov     rsi, r12
    call    proj
    comiss  xmm0, [rsp]
    ja      2f                          # too coarse
    movss   xmm0, [rbx+CR_PERR]
    lea     rdi, [rbx+CR_PLOD]
    mov     rsi, r12
    call    proj
    movss   xmm1, [rsp]
    comiss  xmm1, xmm0
    jae     2f                          # its parents are fine enough
    mov     ecx, [rsp+4]
    mov     byte ptr [r13+rcx], 1
    inc     r14d
    movzx   eax, byte ptr [rbx+CR_NT]
    add     r15d, eax
2:  mov     ecx, [rsp+4]
    inc     ecx
    add     rbx, CR_SZ
    jmp     1b
9:  mov     eax, r14d
    mov     edx, r15d
    add     rsp, 24
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# vg_edges(rdi=dag, rsi=chosen (a byte per cluster)) -> rax: the sum over
#   the chosen triangles' directed edges of g(a, b) - g(b, a), vertices by
#   their grid position. A crack-free cut has the same sum as level 0 (0 for
#   a closed mesh).
vg_edges:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 40
    mov     [rsp], rdi
    mov     [rsp+8], rsi
    xor     eax, eax
    mov     [rsp+16], rax               # the sum
    xor     ebx, ebx
.Lve_next:
    mov     rdi, [rsp]
    cmp     ebx, [rdi+VH_NCL]
    jae     .Lve_out
    mov     rsi, [rsp+8]
    cmp     byte ptr [rsi+rbx], 0
    je      .Lve_skip
    mov     rax, rbx
    shl     rax, 6
    lea     r12, [rdi+rax+VH_SZ]
    mov     eax, [r12+CR_DATA]
    shl     rax, 4
    add     rax, [rdi+VH_ODATA]
    lea     r13, [rdi+rax]              # vertices
    movzx   eax, byte ptr [r12+CR_NV]
    shl     eax, 4
    lea     r14, [r13+rax]              # triangles
    movzx   r15d, byte ptr [r12+CR_NT]
1:  test    r15d, r15d
    jz      .Lve_skip
    movzx   edi, byte ptr [r14]
    call    ve_hash
    mov     [rsp+24], rax
    movzx   edi, byte ptr [r14+1]
    call    ve_hash
    mov     [rsp+32], rax
    movzx   edi, byte ptr [r14+2]
    call    ve_hash
    mov     rbp, rax                    # c
    mov     rdi, [rsp+24]
    mov     rsi, [rsp+32]
    call    ve_pair
    mov     rdi, [rsp+32]
    mov     rsi, rbp
    call    ve_pair
    mov     rdi, rbp
    mov     rsi, [rsp+24]
    call    ve_pair
    add     r14, 3
    dec     r15d
    jmp     1b
.Lve_skip:
    inc     ebx
    jmp     .Lve_next
.Lve_out:
    mov     rax, [rsp+16]
    add     rsp, 40
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ve_hash(edi=local vertex; r13 = the cluster's vertices) -> rax
ve_hash:
    shl     edi, 4
    mov     eax, [r13+rdi]
    mov     edx, [r13+rdi+4]
    shl     rdx, 21
    or      rax, rdx
    mov     edx, [r13+rdi+8]
    shl     rdx, 42
    or      rax, rdx
    jmp     mix

# ve_pair(rdi=a, rsi=b) - vg_edges' sum (at rsp+8+16 in its frame) +=
#   g(a, b) - g(b, a)
ve_pair:
    push    rbx
    mov     rax, rsi
    rol     rax, 23
    xor     rax, rdi
    call    mix
    mov     rbx, rax
    mov     rax, rdi
    rol     rax, 23
    xor     rax, rsi
    call    mix
    sub     rbx, rax
    add     [rsp+16+16], rbx
    pop     rbx
    ret

# vg_check(rdi=dag) -> eax = 1: every cluster within its limits, errors
#   only growing to the parents, LOD spheres inside the parents', and every
#   cut crack-free - each level, 16 error thresholds, 24 cameras around it
.equ VC_DAG,    0
.equ VC_SEL,    8
.equ VC_D0,     16
.equ VC_OK,     24
.equ VC_K,      28
.equ VC_CAM,    32                      # x y z
.equ VC_T,      44
.equ VC_CTR,    48                      # x y z, radius
vg_check:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 80
    mov     [rsp+VC_DAG], rdi
    mov     dword ptr [rsp+VC_OK], 0
    mov     esi, [rdi+VH_NCL]           # (its own pages: a build may run)
    add     rsi, 4095
    and     rsi, -4096
    xor     edi, edi
    mov     edx, PROT_RW
    mov     r10d, MAP_ANON_PRIV
    mov     r8, -1
    xor     r9d, r9d
    mov     eax, SYS_MMAP
    syscall
    cmp     rax, -4096
    jae     .Lvc_out
    mov     [rsp+VC_SEL], rax
    mov     rdi, [rsp+VC_DAG]           # the records
    lea     rbx, [rdi+VH_SZ]
    mov     r12d, [rdi+VH_NCL]
1:  test    r12d, r12d
    jz      2f
    movzx   eax, byte ptr [rbx+CR_NT]
    test    eax, eax
    jz      .Lvc_bad
    cmp     eax, CL_TRIS
    ja      .Lvc_bad
    movzx   eax, byte ptr [rbx+CR_NV]
    test    eax, eax
    jz      .Lvc_bad
    cmp     eax, CL_VERTS
    ja      .Lvc_bad
    movss   xmm0, [rbx+CR_ERR]
    comiss  xmm0, [rbx+CR_PERR]
    ja      .Lvc_bad
    movaps  xmm0, [rbx+CR_LOD]          # |c - pc| + r <= pr
    movaps  xmm1, [rbx+CR_PLOD]
    movaps  xmm2, xmm0
    subps   xmm2, xmm1
    mulps   xmm2, xmm2
    movaps  xmm3, xmm2
    shufps  xmm3, xmm3, 0x55
    addss   xmm3, xmm2
    movhlps xmm2, xmm2
    addss   xmm3, xmm2
    sqrtss  xmm3, xmm3
    shufps  xmm0, xmm0, 0xff
    addss   xmm3, xmm0
    shufps  xmm1, xmm1, 0xff
    mulss   xmm1, [rip+f_grow]
    addss   xmm1, [rip+f_tiny]
    comiss  xmm3, xmm1
    ja      .Lvc_bad
    add     rbx, CR_SZ
    dec     r12d
    jmp     1b
2:  xor     edi, edi                    # level 0's sum
    call    vc_level
    mov     [rsp+VC_D0], rax
    mov     dword ptr [rsp+VC_K], 1     # every level
3:  mov     rdi, [rsp+VC_DAG]
    mov     eax, [rsp+VC_K]
    cmp     eax, [rdi+VH_NLV]
    jae     4f
    mov     edi, eax
    call    vc_level
    cmp     rax, [rsp+VC_D0]
    jne     .Lvc_bad
    inc     dword ptr [rsp+VC_K]
    jmp     3b
4:  mov     dword ptr [rsp+VC_K], 0     # thresholds 0 .. 1.25 x the largest
5:  cmp     dword ptr [rsp+VC_K], 16
    jae     6f
    mov     rdi, [rsp+VC_DAG]
    cvtsi2ss xmm0, dword ptr [rsp+VC_K]
    mulss   xmm0, [rdi+VH_RERR]
    mulss   xmm0, [rip+f_twelfth]
    xor     esi, esi
    call    vc_cut
    test    eax, eax
    jz      .Lvc_bad
    inc     dword ptr [rsp+VC_K]
    jmp     5b
6:  mov     rdi, [rsp+VC_DAG]           # cameras: around the grid's centre
    movss   xmm0, [rdi+VH_STEP]
    mulss   xmm0, [rip+f_half_q]
    movaps  xmm1, xmm0
    shufps  xmm1, xmm1, 0
    movups  xmm2, [rdi+VH_BMIN]
    addps   xmm2, xmm1
    movaps  [rsp+VC_CTR], xmm2
    movss   [rsp+VC_CTR+12], xmm0       # half the grid
    mov     dword ptr [rsp+VC_K], 0
7:  cmp     dword ptr [rsp+VC_K], 24
    jae     8f
    mov     eax, [rsp+VC_K]             # a direction from a hash
    add     rax, 0x5eed
    call    mix
    mov     r12, rax
    xor     r13d, r13d
71: mov     eax, r12d
    and     eax, 0xffff
    cvtsi2ss xmm0, eax
    mulss   xmm0, [rip+f_inv32k]
    subss   xmm0, [rip+f_one]           # -1 .. 1
    lea     rcx, [rsp+VC_CAM]
    movss   [rcx+r13*4], xmm0
    shr     r12, 16
    inc     r13d
    cmp     r13d, 3
    jb      71b
    mov     eax, r12d                   # distance 0.1 .. 6.4 half-grids
    and     eax, 7
    cvtsi2ss xmm1, eax
    mulss   xmm1, [rip+f_dstep]
    addss   xmm1, [rip+f_dmin]
    mulss   xmm1, [rsp+VC_CTR+12]
    shufps  xmm1, xmm1, 0
    movups  xmm0, [rsp+VC_CAM]
    mulps   xmm0, xmm1
    addps   xmm0, [rsp+VC_CTR]
    movups  [rsp+VC_CAM], xmm0
    mov     eax, [rsp+VC_K]             # threshold: 1/2000 .. 1/60
    and     eax, 7
    cvtsi2ss xmm0, eax
    mulss   xmm0, [rip+f_tstep]
    addss   xmm0, [rip+f_tmin]
    lea     rsi, [rsp+VC_CAM]
    mov     rdi, [rsp+VC_DAG]
    call    vc_cut
    test    eax, eax
    jz      .Lvc_bad
    inc     dword ptr [rsp+VC_K]
    jmp     7b
8:  mov     dword ptr [rsp+VC_OK], 1
.Lvc_bad:
    mov     rdi, [rsp+VC_SEL]
    mov     rax, [rsp+VC_DAG]
    mov     esi, [rax+VH_NCL]
    add     rsi, 4095
    and     rsi, -4096
    mov     eax, SYS_MUNMAP
    syscall
.Lvc_out:
    mov     eax, [rsp+VC_OK]
    add     rsp, 80
    pop     r13
    pop     r12
    pop     rbx
    ret

# vc_level(edi=level) -> rax: vg_edges of that level's clusters (vg_check's
#   frame at rsp+8)
vc_level:
    lea     r8, [rsp+8]
    mov     r9, [r8+VC_DAG]
    mov     r10, [r8+VC_SEL]
    lea     r11, [r9+VH_SZ]
    xor     ecx, ecx
1:  cmp     ecx, [r9+VH_NCL]
    jae     2f
    movzx   eax, byte ptr [r11+CR_LEVEL]
    cmp     eax, edi
    sete    byte ptr [r10+rcx]
    add     r11, CR_SZ
    inc     ecx
    jmp     1b
2:  mov     rdi, r9
    mov     rsi, r10
    jmp     vg_edges

# vc_cut(rdi=dag, xmm0=threshold, rsi=camera or 0) -> eax = 1: the cut has
#   triangles and level 0's edge sum (vg_check's frame at rsp+8)
vc_cut:
    push    rbx
    lea     rbx, [rsp+16]
    mov     rdx, [rbx+VC_SEL]
    call    vg_select
    test    eax, eax
    jz      8f
    mov     rdi, [rbx+VC_DAG]
    mov     rsi, [rbx+VC_SEL]
    call    vg_edges
    cmp     rax, [rbx+VC_D0]
    jne     8f
    mov     eax, 1
    pop     rbx
    ret
8:  xor     eax, eax
    pop     rbx
    ret

# vg_info(rdi=mesh, esi=k) -> xmm0: 0 state (0 none, 1 building, 2 ready,
#   3 out of date), 1 clusters, 2 levels, 3 groups, 4 source triangles,
#   5 the top level's triangles, 6 build ms, 7 KB, 8 the largest error,
#   9 roots, 10 the most triangles in a cluster, 11 the most vertices,
#   12 vg_check (1 ok), 13 triangles over all clusters, 14 level 0 clusters,
#   100 + L / 200 + L / 300 + L: level L's triangles, clusters, largest
#   error, 400 + L its clusters under 32 triangles, 500 + L its groups
vg_info:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12d, esi
    xorps   xmm0, xmm0
    test    rbx, rbx
    jz      9f
    test    r12d, r12d
    jnz     2f
    cmp     dword ptr [rip+vg_state], 0
    je      1f
    cmp     [rip+vg_mesh], rbx
    jne     1f
    mov     eax, 1
    jmp     8f
1:  xor     eax, eax
    cmp     qword ptr [rbx+ME_VGEO], 0
    je      8f
    mov     rdi, rbx
    call    vg_get
    test    rax, rax
    mov     eax, 2
    jnz     8f
    mov     eax, 3
    jmp     8f
2:  mov     rdi, rbx
    call    vg_get
    test    rax, rax
    jz      9f
    mov     r13, rax
    cmp     r12d, 1
    jne     21f
    mov     eax, [r13+VH_NCL]
    jmp     8f
21: cmp     r12d, 2
    jne     22f
    mov     eax, [r13+VH_NLV]
    jmp     8f
22: cmp     r12d, 3
    jne     23f
    mov     eax, [r13+VH_NGR]
    jmp     8f
23: cmp     r12d, 4
    jne     24f
    mov     eax, [r13+VH_STRI]
    jmp     8f
24: cmp     r12d, 5
    jne     25f
    mov     eax, [r13+VH_NLV]
    dec     eax
    shl     eax, 4
    mov     eax, [r13+rax+VH_LV+8]
    jmp     8f
25: cmp     r12d, 6
    jne     26f
    mov     eax, [r13+VH_MS]
    jmp     8f
26: cmp     r12d, 7
    jne     27f
    mov     rax, [r13+VH_BYTES]
    shr     rax, 10
    jmp     8f
27: cmp     r12d, 8
    jne     28f
    movss   xmm0, [r13+VH_RERR]
    jmp     9f
28: cmp     r12d, 9
    jne     29f
    mov     eax, [r13+VH_ROOTS]
    jmp     8f
29: cmp     r12d, 10
    jb      30f
    cmp     r12d, 11
    ja      30f
    lea     rcx, [r13+VH_SZ]            # the most triangles / vertices
    mov     edx, [r13+VH_NCL]
    xor     eax, eax
    mov     esi, CR_NT
    cmp     r12d, 10
    je      291f
    mov     esi, CR_NV
291:test    edx, edx
    jz      8f
    movzx   edi, byte ptr [rcx+rsi]
    cmp     edi, eax
    cmova   eax, edi
    add     rcx, CR_SZ
    dec     edx
    jmp     291b
30: cmp     r12d, 12
    jne     31f
    mov     rdi, r13
    call    vg_check
    jmp     8f
31: cmp     r12d, 13
    jne     32f
    mov     eax, [r13+VH_TTRI]
    jmp     8f
32: cmp     r12d, 14
    jne     33f
    mov     eax, [r13+VH_LV+4]
    jmp     8f
33: cmp     r12d, 500                   # (500 + L: groups of level L)
    jb      39f
    sub     r12d, 500
    mov     rcx, [r13+VH_OGR]
    add     rcx, r13
    mov     edx, [r13+VH_NGR]
    xor     eax, eax
391:test    edx, edx
    jz      8f
    cmp     [rcx+GR_LEVEL], r12d
    jne     392f
    inc     eax
392:add     rcx, GR_SZ
    dec     edx
    jmp     391b
39: cmp     r12d, 400                   # (400 + L: level L's clusters under 32)
    jb      36f
    sub     r12d, 400
    lea     rcx, [r13+VH_SZ]
    mov     edx, [r13+VH_NCL]
    xor     eax, eax
37: test    edx, edx
    jz      8f
    movzx   esi, byte ptr [rcx+CR_LEVEL]
    cmp     esi, r12d
    jne     38f
    cmp     byte ptr [rcx+CR_NT], 32
    jae     38f
    inc     eax
38: add     rcx, CR_SZ
    dec     edx
    jmp     37b
36: cmp     r12d, 100                   # 100 + L, 200 + L, 300 + L: level L's
    jb      9f                          #   triangles, clusters, largest error
    mov     eax, r12d
    xor     edx, edx
    mov     ecx, 100
    div     ecx
    cmp     edx, [r13+VH_NLV]
    jae     9f
    shl     edx, 4
    lea     rcx, [r13+rdx+VH_LV]
    cmp     eax, 2
    je      34f
    ja      35f
    mov     eax, [rcx+8]
    jmp     8f
34: mov     eax, [rcx+4]
    jmp     8f
35: movss   xmm0, [rcx+12]
    jmp     9f
8:  cvtsi2ss xmm0, eax
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# vgeo_read(rdi=chunk data, esi=bytes) -> rax = a DAG (its own pages) and
#   edx = the mesh (index in the file), or rax = 0
vgeo_read:
    push    rbx
    push    r12
    push    r13
    cmp     esi, 8
    jb      8f
    mov     r13d, [rdi]                 # mesh
    mov     eax, [rdi+4]                # padding to the page
    lea     rbx, [rdi+rax+8]
    sub     esi, eax
    sub     esi, 8
    jb      8f
    cmp     esi, VH_SZ
    jb      8f
    cmp     dword ptr [rbx+VH_MAGIC], VG_MAGIC
    jne     8f
    cmp     dword ptr [rbx+VH_VER], VG_VERSION
    jne     8f
    mov     r12, [rbx+VH_BYTES]
    cmp     r12, rsi
    ja      8f
    xor     edi, edi
    mov     rsi, r12
    mov     edx, PROT_RW
    mov     r10d, MAP_ANON_PRIV
    mov     r8, -1
    xor     r9d, r9d
    mov     eax, SYS_MMAP
    syscall
    cmp     rax, -4096
    jae     8f
    mov     rdi, rax
    mov     rsi, rbx
    mov     rcx, r12
    mov     rbx, rax
    rep     movsb
    mov     dword ptr [rbx+VH_REFS], 1
    mov     rax, rbx
    mov     edx, r13d
    jmp     9f
8:  xor     eax, eax
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Operators
# =============================================================================
OPERATOR op_vg_build, "vgeo.build", "Virtualize Geometry", do_vg_build, flags=OPF_AI_SAFE, doc="Build the active mesh's cluster LOD DAG: meshlets of up to 128 triangles, grouped and simplified level by level (in the background; kept with the mesh, saved in the .bee file)"
OPERATOR op_vg_clear, "vgeo.clear", "Clear Virtual Geometry", do_vg_clear, flags=OPF_AI_SAFE, doc="Forget the active mesh's cluster LOD DAG"
OPERATOR op_vg_extract, "vgeo.extract", "Extract LOD", do_vg_extract, flags=OPF_AI_SAFE|OPF_UNDO, doc="Add the active mesh's DAG cut as a new object, its clusters coloured: vgeo.extract <level> or vgeo.extract <error, e.g. 0.01>"

# vg_active -> rax = the active object if it is a mesh, rdx = its mesh
vg_active:
    sub     rsp, 8
    mov     edi, [rip+active_obj]
    call    obj_get
    add     rsp, 8
    test    rax, rax
    jz      8f
    cmp     dword ptr [rax+OB_TYPE], OT_MESH
    jne     8f
    mov     rdx, [rax+OB_MESH]
    test    rdx, rdx
    jz      8f
    ret
8:  xor     eax, eax
    xor     edx, edx
    ret

do_vg_build:
    push    rbx
    push    r12
    sub     rsp, 8
    cmp     dword ptr [rip+vg_state], 0
    je      1f
    lea     rdi, [rip+s_vg_busy]
    call    log_line
    jmp     9f
1:  call    vg_active
    test    rax, rax
    jz      7f
    mov     rbx, rax
    mov     r12, rdx
    mov     rdi, r12
    call    vg_snap
    test    eax, eax
    jz      7f
    mov     rdi, r12
    call    mesh_ref
    mov     [rip+vg_mesh], r12
    call    fmt_reset
    lea     rdi, [rip+s_vg_start]
    call    fmt_str
    mov     rdi, rbx
    call    fmt_str
    lea     rdi, [rip+s_vg_open]
    call    fmt_str
    mov     edi, [rip+s_nt]
    call    fmt_int
    lea     rdi, [rip+s_vg_tris]
    call    fmt_str
    lea     rdi, [rip+s_vg_close]
    call    fmt_str
    lea     rdi, [rip+fmt_buf]
    call    log_line
    mov     dword ptr [rip+vg_state], 1
    cmp     dword ptr [rip+vg_async], 0
    je      2f
    lea     rdi, [rip+vg_thread]        # the window: in the background
    xor     esi, esi
    call    job_spawn
    test    eax, eax
    jg      9f
2:  call    vg_run                      # (scripts, headless: now)
    mov     dword ptr [rip+vg_state], 2
    call    vg_tick
    jmp     9f
7:  lea     rdi, [rip+s_vg_none]
    call    log_line
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# vg_tick - a build that finished: its DAG goes to the mesh (UI thread)
vg_tick:
    cmp     dword ptr [rip+vg_state], 2
    jne     9f
    push    rbx
    push    r12
    sub     rsp, 8
    mov     r12, [rip+vg_mesh]
    mov     rbx, [rip+vg_out]
    test    rbx, rbx
    jz      7f
    mov     rdi, r12
    mov     rsi, rbx
    call    vg_attach
    call    fmt_reset
    lea     rdi, [rip+s_vg_done]
    call    fmt_str
    mov     edi, [rbx+VH_STRI]
    call    fmt_int
    lea     rdi, [rip+s_vg_tris]
    call    fmt_str
    lea     rdi, [rip+s_vg_comma]
    call    fmt_str
    mov     edi, [rbx+VH_NCL]
    call    fmt_int
    lea     rdi, [rip+s_vg_clusters]
    call    fmt_str
    mov     edi, [rbx+VH_NLV]
    call    fmt_int
    lea     rdi, [rip+s_vg_levels]
    call    fmt_str
    mov     edi, [rbx+VH_ROOTS]
    call    fmt_int
    lea     rdi, [rip+s_vg_roots]
    call    fmt_str
    mov     edi, [rbx+VH_MS]
    call    fmt_int
    lea     rdi, [rip+s_vg_ms]
    call    fmt_str
    lea     rdi, [rip+fmt_buf]
    call    log_line
    jmp     8f
7:  lea     rdi, [rip+s_vg_failed]
    call    log_line
8:  mov     rdi, r12
    call    mesh_unref
    mov     qword ptr [rip+vg_mesh], 0
    mov     dword ptr [rip+vg_state], 0
    mov     dword ptr [rip+dirty], 1
    add     rsp, 8
    pop     r12
    pop     rbx
9:  ret

do_vg_clear:
    sub     rsp, 8
    call    vg_active
    test    rax, rax
    jz      9f
    mov     rdi, rdx
    xor     esi, esi
    call    vg_attach
    lea     rdi, [rip+s_vg_cleared]
    call    log_line
9:  add     rsp, 8
    ret

# vgeo.extract <level | error> - the cut as a new mesh object, a colour per
#   cluster
.equ VX_OBJ,    0
.equ VX_DAG,    8
.equ VX_SEL,    16
.equ VX_MESH,   24
.equ VX_NV,     32
.equ VX_NT,     36
.equ VX_LEVEL,  40
.equ VX_T,      44
.equ VX_BASE,   48
.equ VX_IDX,    56                      # 3 x u32
do_vg_extract:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 72
    call    vg_active
    test    rax, rax
    jz      .Lvx_none
    mov     [rsp+VX_OBJ], rax
    mov     rdi, rdx
    call    vg_get
    test    rax, rax
    jz      .Lvx_none
    mov     [rsp+VX_DAG], rax
    mov     eax, [rax+VH_NLV]           # default: the middle level
    shr     eax, 1
    mov     [rsp+VX_LEVEL], eax
    mov     rsi, [rip+op_arg]
    call    im_next_word
    test    eax, eax
    jz      2f
    lea     rsi, [rip+im_word]
    lea     rdx, [rsi+rax]
    xor     ecx, ecx                    # a '.': an error, else a level
1:  cmp     byte ptr [rsi+rcx], '.'
    je      11f
    inc     ecx
    cmp     ecx, eax
    jb      1b
    call    parse_float
    test    eax, eax
    jz      2f
    cvttss2si eax, xmm0
    mov     rcx, [rsp+VX_DAG]
    mov     edx, [rcx+VH_NLV]
    dec     edx
    cmp     eax, edx
    cmovg   eax, edx
    test    eax, eax
    jns     12f
    xor     eax, eax
12: mov     [rsp+VX_LEVEL], eax
    jmp     2f
11: call    parse_float
    test    eax, eax
    jz      2f
    movss   [rsp+VX_T], xmm0
    mov     dword ptr [rsp+VX_LEVEL], -1
2:  mov     rax, [rsp+VX_DAG]           # choose
    mov     esi, [rax+VH_NCL]
    add     rsi, 4095
    and     rsi, -4096
    xor     edi, edi
    mov     edx, PROT_RW
    mov     r10d, MAP_ANON_PRIV
    mov     r8, -1
    xor     r9d, r9d
    mov     eax, SYS_MMAP
    syscall
    cmp     rax, -4096
    jae     .Lvx_none
    mov     [rsp+VX_SEL], rax
    mov     rdi, [rsp+VX_DAG]
    cmp     dword ptr [rsp+VX_LEVEL], 0
    jl      3f
    lea     r11, [rdi+VH_SZ]
    mov     r10, rax
    xor     ecx, ecx
21: cmp     ecx, [rdi+VH_NCL]
    jae     4f
    movzx   eax, byte ptr [r11+CR_LEVEL]
    cmp     eax, [rsp+VX_LEVEL]
    sete    byte ptr [r10+rcx]
    add     r11, CR_SZ
    inc     ecx
    jmp     21b
3:  movss   xmm0, [rsp+VX_T]
    xor     esi, esi
    mov     rdx, rax
    call    vg_select
4:  mov     rdi, [rsp+VX_DAG]           # count
    mov     r10, [rsp+VX_SEL]
    lea     r11, [rdi+VH_SZ]
    xor     ecx, ecx
    xor     edx, edx
    xor     esi, esi
5:  cmp     ecx, [rdi+VH_NCL]
    jae     6f
    cmp     byte ptr [r10+rcx], 0
    je      51f
    movzx   eax, byte ptr [r11+CR_NV]
    add     edx, eax
    movzx   eax, byte ptr [r11+CR_NT]
    add     esi, eax
51: add     r11, CR_SZ
    inc     ecx
    jmp     5b
6:  mov     [rsp+VX_NV], edx
    mov     [rsp+VX_NT], esi
    test    esi, esi
    jz      .Lvx_free
    mov     edi, edx
    lea     esi, [rsi+rsi*2]
    mov     edx, [rsp+VX_NT]
    call    mesh_new
    test    rax, rax
    jz      .Lvx_free
    mov     [rsp+VX_MESH], rax
    mov     rdi, rax
    call    mesh_vcol_alloc
    xor     ebx, ebx                    # cluster
.Lvx_cl:
    mov     rdi, [rsp+VX_DAG]
    cmp     ebx, [rdi+VH_NCL]
    jae     .Lvx_add
    mov     r10, [rsp+VX_SEL]
    cmp     byte ptr [r10+rbx], 0
    je      .Lvx_skip
    mov     rax, rbx
    shl     rax, 6
    lea     r12, [rdi+rax+VH_SZ]
    mov     eax, [r12+CR_DATA]
    shl     rax, 4
    add     rax, [rdi+VH_ODATA]
    lea     r13, [rdi+rax]              # vertices
    movzx   r14d, byte ptr [r12+CR_NV]
    mov     rax, [rsp+VX_MESH]
    mov     eax, [rax+ME_NVERTS]
    mov     [rsp+VX_BASE], eax
    mov     eax, ebx                    # its colour
    call    mix
    or      eax, 0xff404040
    mov     ebp, eax
    xor     r15d, r15d
7:  cmp     r15d, r14d
    jae     8f
    mov     rdi, [rsp+VX_DAG]
    mov     rax, r15
    shl     rax, 4
    cvtsi2ss xmm0, dword ptr [r13+rax]
    cvtsi2ss xmm1, dword ptr [r13+rax+4]
    cvtsi2ss xmm2, dword ptr [r13+rax+8]
    movss   xmm3, [rdi+VH_STEP]
    mulss   xmm0, xmm3
    mulss   xmm1, xmm3
    mulss   xmm2, xmm3
    addss   xmm0, [rdi+VH_BMIN]
    addss   xmm1, [rdi+VH_BMIN+4]
    addss   xmm2, [rdi+VH_BMIN+8]
    mov     rdi, [rsp+VX_MESH]
    call    mesh_add_vert
    mov     rcx, [rsp+VX_MESH]
    mov     rcx, [rcx+ME_VCOL]
    test    rcx, rcx
    jz      71f
    mov     [rcx+rax*4], ebp
71: inc     r15d
    jmp     7b
8:  movzx   r14d, byte ptr [r12+CR_NV]  # its triangles
    shl     r14d, 4
    add     r14, r13
    movzx   r15d, byte ptr [r12+CR_NT]
9:  test    r15d, r15d
    jz      .Lvx_skip
    xor     ecx, ecx
91: movzx   eax, byte ptr [r14+rcx]
    add     eax, [rsp+VX_BASE]
    mov     [rsp+VX_IDX+rcx*4], eax
    inc     ecx
    cmp     ecx, 3
    jb      91b
    mov     rdi, [rsp+VX_MESH]
    lea     rsi, [rsp+VX_IDX]
    mov     edx, 3
    call    mesh_add_poly
    add     r14, 3
    dec     r15d
    jmp     9b
.Lvx_skip:
    inc     ebx
    jmp     .Lvx_cl
.Lvx_add:
    mov     rdi, [rsp+VX_MESH]
    call    mesh_finish
    mov     edi, OT_MESH
    lea     rsi, [rip+s_vg_lod]
    mov     rdx, [rsp+VX_MESH]
    call    obj_new
    test    eax, eax
    jz      .Lvx_free
    mov     ebx, eax
    mov     edi, eax
    call    obj_get
    mov     rcx, [rsp+VX_OBJ]           # where the source is
    lea     rsi, [rcx+OB_LOC]
    lea     rdi, [rax+OB_LOC]
    mov     ecx, 9
    rep     movsd
    mov     [rip+active_obj], ebx
    mov     dword ptr [rip+dirty], 1
    call    fmt_reset
    lea     rdi, [rip+s_vg_lodmsg]
    call    fmt_str
    mov     edi, [rsp+VX_NT]
    call    fmt_int
    lea     rdi, [rip+s_vg_tris]
    call    fmt_str
    lea     rdi, [rip+fmt_buf]
    call    log_line
.Lvx_free:
    mov     rdi, [rsp+VX_SEL]
    mov     rax, [rsp+VX_DAG]
    mov     esi, [rax+VH_NCL]
    add     rsi, 4095
    and     rsi, -4096
    mov     eax, SYS_MUNMAP
    syscall
    jmp     .Lvx_out
.Lvx_none:
    lea     rdi, [rip+s_vg_nodag]
    call    log_line
.Lvx_out:
    add     rsp, 72
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Self-test (beemodel --selftest)
# =============================================================================
# vg_selftest(rdi=check(eax=ok, rdi=label)) - DAGs of a torus (closed), a
#   rippled grid (open, 1M triangles: timed), 216 separate cubes (islands):
#   built, every cut crack-free, the clusters within their limits, few roots
vg_selftest:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r15, rdi
    call    prim_torus                  # the torus: one root
    mov     rbx, rax
    mov     rdi, rax
    call    vg_test
    mov     r13d, eax
    xor     ecx, ecx
    test    rdx, rdx
    jz      0f
    cmp     dword ptr [rdx+VH_ROOTS], 1
    sete    cl
0:  and     r13d, ecx
    mov     rdi, rbx
    call    st_line
    mov     rdi, rbx
    call    mesh_unref
    mov     eax, r13d
    lea     rdi, [rip+s_st_torus]
    call    r15
    mov     edi, 724                    # the rippled grid
    call    prim_grid_n
    mov     rbx, rax
    mov     r14, [rbx+ME_POS]
    mov     r13d, [rbx+ME_NVERTS]
    sub     rsp, 16
1:  test    r13d, r13d                  # y = 0.05 sin(5 x) cos(7 z)
    jz      2f
    movss   xmm0, [r14]
    mulss   xmm0, [rip+f_st5]
    call    sincos
    movss   [rsp], xmm0
    movss   xmm0, [r14+8]
    mulss   xmm0, [rip+f_st7]
    call    sincos
    mulss   xmm1, [rsp]
    mulss   xmm1, [rip+f_st05]
    movss   [r14+4], xmm1
    add     r14, 12
    dec     r13d
    jmp     1b
2:  add     rsp, 16
    call    now_ms
    mov     r12, rax
    mov     rdi, rbx
    call    vg_test
    mov     r13d, eax
    test    rdx, rdx                    # (the top: 1/100 of it at most)
    jz      21f
    call    top_tris
    imul    ecx, ecx, 100
    cmp     ecx, [rdx+VH_STRI]
    jbe     21f
    xor     r13d, r13d
21: call    now_ms
    sub     rax, r12
    mov     r12, rax
    mov     eax, r13d
    lea     rdi, [rip+s_st_grid]
    call    r15
    mov     rdi, rbx
    call    st_line
    mov     rdi, rbx
    call    mesh_unref
    call    st_cubes                    # islands
    mov     rbx, rax
    mov     rdi, rax
    call    vg_test
    mov     r13d, eax
    xor     eax, eax                    # (each a tetrahedron at the top, in
    test    rdx, rdx                    #   at most 16 clusters)
    jz      3f
    cmp     dword ptr [rdx+VH_ROOTS], 16
    ja      3f
    call    top_tris
    cmp     ecx, 216*4
    setbe   al
3:  and     r13d, eax
    mov     rdi, rbx
    call    st_line
    mov     rdi, rbx
    call    mesh_unref
    mov     eax, r13d
    lea     rdi, [rip+s_st_cubes]
    call    r15
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# vg_test(rdi=mesh) -> eax = 1: its DAG built, the clusters within their
#   limits and every cut crack-free; rdx = the DAG
vg_test:
    push    rbx
    mov     rbx, rdi
    call    vg_build_mesh
    test    rax, rax
    jz      8f
    mov     rbx, rax
    mov     rdi, rax
    call    vg_check
    mov     rdx, rbx
    pop     rbx
    ret
8:  xor     eax, eax
    xor     edx, edx
    pop     rbx
    ret

# top_tris(rdx=dag) -> ecx = its top level's triangles
top_tris:
    mov     ecx, [rdx+VH_NLV]
    dec     ecx
    shl     ecx, 4
    mov     ecx, [rdx+rcx+VH_LV+8]
    ret

# st_line(rdi=mesh) - "cluster DAG of n triangles: ms, levels, clusters,
#   roots, top level triangles"
st_line:
    push    rbx
    mov     rbx, [rdi+ME_VGEO]
    test    rbx, rbx
    jz      9f
    call    fmt_reset
    lea     rdi, [rip+s_st_time]
    call    fmt_str
    mov     edi, [rbx+VH_STRI]
    call    fmt_int
    lea     rdi, [rip+s_st_time2]
    call    fmt_str
    mov     edi, [rbx+VH_MS]
    call    fmt_int
    lea     rdi, [rip+s_st_time3]
    call    fmt_str
    mov     edi, [rbx+VH_NLV]
    call    fmt_int
    lea     rdi, [rip+s_st_time4]
    call    fmt_str
    mov     edi, [rbx+VH_NCL]
    call    fmt_int
    lea     rdi, [rip+s_st_time6]
    call    fmt_str
    mov     edi, [rbx+VH_ROOTS]
    call    fmt_int
    lea     rdi, [rip+s_st_time7]
    call    fmt_str
    mov     eax, [rbx+VH_NLV]
    dec     eax
    shl     eax, 4
    mov     edi, [rbx+rax+VH_LV+8]
    call    fmt_int
    lea     rdi, [rip+s_st_time8]
    call    fmt_str
    lea     rdi, [rip+fmt_buf]
    call    write_out
9:  pop     rbx
    ret

# st_cubes -> rax = a mesh of 6 x 6 x 6 separate cubes
st_cubes:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 40
    mov     edi, 216*8
    mov     esi, 216*24
    mov     edx, 216*6
    call    mesh_new
    mov     rbx, rax
    xor     r12d, r12d                  # cube
1:  cmp     r12d, 216
    jae     5f
    mov     eax, r12d                   # its centre: (i, j, k)
    xor     edx, edx
    mov     ecx, 6
    div     ecx
    cvtsi2ss xmm5, edx
    xor     edx, edx
    div     ecx
    cvtsi2ss xmm6, edx
    cvtsi2ss xmm7, eax
    mov     r13d, [rbx+ME_NVERTS]
    xor     r14d, r14d
2:  cmp     r14d, 8
    jae     3f
    lea     rax, [r14+r14*2]
    lea     rcx, [rip+st_cv]
    movss   xmm0, [rcx+rax*4]
    movss   xmm1, [rcx+rax*4+4]
    movss   xmm2, [rcx+rax*4+8]
    mulss   xmm0, [rip+f_st03]
    mulss   xmm1, [rip+f_st03]
    mulss   xmm2, [rip+f_st03]
    addss   xmm0, xmm5
    addss   xmm1, xmm6
    addss   xmm2, xmm7
    movss   [rsp+16], xmm5
    movss   [rsp+20], xmm6
    movss   [rsp+24], xmm7
    mov     rdi, rbx
    call    mesh_add_vert
    movss   xmm5, [rsp+16]
    movss   xmm6, [rsp+20]
    movss   xmm7, [rsp+24]
    inc     r14d
    jmp     2b
3:  xor     r14d, r14d
4:  cmp     r14d, 6
    jae     41f
    lea     rcx, [rip+st_cf]
    mov     eax, r14d
    shl     eax, 4
    xor     edx, edx
42: mov     esi, [rcx+rax]
    add     esi, r13d
    mov     [rsp+rdx*4], esi
    add     eax, 4
    inc     edx
    cmp     edx, 4
    jb      42b
    mov     rdi, rbx
    mov     rsi, rsp
    mov     edx, 4
    call    mesh_add_poly
    inc     r14d
    jmp     4b
41: inc     r12d
    jmp     1b
5:  mov     rdi, rbx
    call    mesh_finish
    mov     rax, rbx
    add     rsp, 40
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.section .rodata
.align 4
st_cv:          .float -1,-1,-1,  1,-1,-1,  1,-1,1,  -1,-1,1
                .float -1, 1,-1,  1, 1,-1,  1, 1,1,  -1, 1,1
st_cf:          .long 0,1,2,3, 7,6,5,4, 0,4,5,1, 1,5,6,2, 2,6,7,3, 3,7,4,0
f_st5:          .float 5.0
f_st7:          .float 7.0
f_st05:         .float 0.05
f_st03:         .float 0.3
s_st_torus:     .asciz "virtual geometry: a torus's cluster DAG, every cut crack-free, one root"
s_st_grid:      .asciz "virtual geometry: a rippled 1M-triangle grid (open), every cut crack-free, 1/100 at the top"
s_st_cubes:     .asciz "virtual geometry: 216 separate cubes (islands) share clusters, each down to a tetrahedron"
s_st_time:      .asciz "  cluster DAG of "
s_st_time2:     .asciz " triangles: "
s_st_time3:     .asciz " ms, "
s_st_time4:     .asciz " levels, "
s_st_time6:     .asciz " clusters, "
s_st_time7:     .asciz " roots, "
s_st_time8:     .asciz " at the top\n"
.text

.section .rodata
f_twelfth:      .float 0.104166667      # 1.25 / 12
f_half_q:       .float 524288.0
f_inv32k:       .float 0.000030518      # 2 / 65536
f_dstep:        .float 0.9
f_dmin:         .float 0.1
f_tstep:        .float 0.0024
f_tmin:         .float 0.0005
s_vg_busy:      .asciz "A mesh is being virtualized already"
s_vg_none:      .asciz "Virtualize: the active object has no triangles"
s_vg_nodag:     .asciz "No cluster DAG for this mesh (vgeo.build)"
s_vg_start:     .asciz "Virtualizing "
s_vg_open:      .asciz " ("
s_vg_tris:      .asciz " triangles"
s_vg_comma:     .asciz ", "
s_vg_close:     .asciz ")"
s_vg_done:      .asciz "Virtualized: "
s_vg_clusters:  .asciz " clusters, "
s_vg_levels:    .asciz " levels, "
s_vg_roots:     .asciz " roots, "
s_vg_ms:        .asciz " ms"
s_vg_failed:    .asciz "Virtualize failed (out of memory?)"
s_vg_cleared:   .asciz "Cluster DAG cleared"
s_vg_lod:       .asciz "LOD"
s_vg_lodmsg:    .asciz "LOD: "

.section .note.GNU-stack,"",@progbits
