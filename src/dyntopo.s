# =============================================================================
#  BeeModel - dynamic topology for sculpt mode
#
#  With dyntopo on, sculpt mode works on its own copy of the triangles
#  (dw_pos, dw_tris, with room to grow). After each dab (every quarter
#  radius of the way) dyn_remesh changes the triangles inside the brush:
#  edges longer than the detail size are split at their middle, those
#  shorter than 0.4 of it collapse to their middle when that keeps the
#  surface a manifold (the ends share exactly two neighbours, no triangle
#  flips, no vertex is left with fewer than three edges). The leaves around
#  are gathered with an edge hash (a vertex ring index for collapses);
#  only those leaves get new triangle and vertex lists (who owns each
#  vertex), boxes, and their splats redrawn.
#
#  The detail is in pixels: brush radius / sc_radius pixels x dyn_detail.
#  At the end of the stroke the copy becomes the object's mesh (triangles;
#  the stroke's undo step keeps the mesh before) and the leaves are built
#  again from it.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"
.include "sculpt.inc"

.globl sc_dyn
.globl dyn_detail
.globl sc_capv
.globl sc_capt
.globl sc_tri_used
.globl dyn_alloc
.globl dyn_free
.globl dyn_tail
.globl dyn_reset
.globl dyn_after_dab
.globl dyn_commit
.globl dyn_remesh

.equ SYS_MREMAP, 25
.equ DEAD,       -1                     # a triangle's first corner: removed

.section .data
.align 4
sc_dyn:         .long 0                 # 1: dynamic topology
dyn_detail:     .float 10.0             # pixels

.section .rodata
.align 8
df_hashk:       .quad 0x9E3779B97F4A7C15
# the per-vertex arrays that grow with the vertices: pointer, bytes, size
dyn_vtab:       .quad dw_pos, dw_pos_b, 12
                .quad sc_vn, sc_vn_b, 12
                .quad sc_mask, sc_mask_b, 1
                .quad sc_stamp, sc_stamp_b, 4
                .quad sc_rec, sc_rec_b, 1
                .quad sc_acc, sc_acc_b, 16
                .quad sc_vown, sc_vown_b, 4
                .quad dy_vst, dy_vst_b, 4
                .quad dy_vloc, dy_vloc_b, 4
.equ DYN_NV, 9
df_quarter:     .float 0.25
df_half:        .float 0.5
df_04:          .float 0.4
df_cos2:        .float 0.25                     # (cos 60 deg)^2: no flip
df_049:         .float 0.49                     # 0.7^2
df_q2:          .float 0.0009                   # (0.03)^2: triangle shape
df_tiny:        .float 1.0e-30
df_one:         .float 1.0
df_finer:       .float 0.8
df_coarser:     .float 1.25
df_dmin:        .float 2.0
df_dmax:        .float 64.0
s_dyn_on:       .asciz "  dyntopo on, detail "
s_dyn_off:      .asciz "  dyntopo off"
s_dyn_px:       .asciz " px"
s_dyn_mem:      .asciz "  dyntopo: out of memory"
s_dyn_mr:       .asciz "  dyntopo: not on a multires level (level 0 sculpts the base)"

.section .bss
.align 8
dw_pos:         .skip 8                 # the working copy: positions,
dw_pos_b:       .skip 8
dw_tris:        .skip 8                 #  triangles (DEAD first corner: gone)
dw_tris_b:      .skip 8
sc_vown:        .skip 8                 # u32 per vertex: the leaf owning it
sc_vown_b:      .skip 8
dy_vst:         .skip 8                 # u32 per vertex: stamps, local ids
dy_vst_b:       .skip 8
dy_vloc:        .skip 8
dy_vloc_b:      .skip 8
dy_mcarry:      .skip 8                 # the mask across a rebuild
dy_mcarry_b:    .skip 8
dy_mcarry_n:    .skip 4
sc_capv:        .skip 4                 # room: vertices, triangles
sc_capt:        .skip 4
sc_tri_used:    .skip 4                 # triangle-id pool in use
dy_serial:      .skip 4
dy_last:        .skip 16*8              # the last remesh centre, + have
                                        #  (each mirror: sculpt's mask)
# one remesh
rm_r:           .skip 4
rm_r2:          .skip 4
rm_dmax2:       .skip 4
rm_dmin2:       .skip 4
rm_mid:         .skip 12
rm_nL:          .skip 4
rm_nT:          .skip 4
rm_Tcap:        .skip 4
rm_hsize:       .skip 4
rm_hmask:       .skip 4
rm_nvl:         .skip 4
rm_cs:          .skip 4
rm_changed:     .skip 4
.align 8
rm_mark:        .skip 8
rm_L:           .skip 8                 # the leaves touched
rm_lidx:        .skip 8                 # per leaf: its place in rm_L, or -1
rm_T:           .skip 8                 # their triangles (local k -> id),
rm_TL:          .skip 8                 #  each one's leaf,
rm_TM:          .skip 8                 #  changed in this pass (u8)
rm_H:           .skip 8                 # edge hash: key, half, half
rm_roff:        .skip 8                 # vertex rings (local vertex -> k)
rm_rt:          .skip 8
rm_vlock:       .skip 8
rm_nb:          .skip 8

.text
OPERATOR op_s_dyn,      "sculpt.dyntopo",        "Dynamic Topology", do_dyntopo, check=dyn_check, key=KEY_D|KM_CTRL, flags=OPF_AI_SAFE|OPF_QUIET|OPF_SCULPT, doc="Sculpt: brushes add and remove triangles to keep the detail size (the mesh becomes triangles)"
OPERATOR op_s_dfine,    "sculpt.detail_finer",   "Finer Detail",   do_detail, arg=0, key=KEY_LEFTBRACE|KM_CTRL, flags=OPF_AI_SAFE|OPF_QUIET|OPF_SCULPT, doc="Sculpt: dyntopo detail size x 0.8 (pixels)"
OPERATOR op_s_dcoarse,  "sculpt.detail_coarser", "Coarser Detail", do_detail, arg=1, key=KEY_RIGHTBRACE|KM_CTRL, flags=OPF_AI_SAFE|OPF_QUIET|OPF_SCULPT, doc="Sculpt: dyntopo detail size x 1.25 (pixels)"

do_dyntopo:                             # on / off: the leaves built again
    push    rbx
    cmp     dword ptr [rip+sc_obj], 0
    je      9f
    cmp     dword ptr [rip+sc_land], 0  # (not on a landscape)
    jne     9f
    cmp     dword ptr [rip+sc_stroking], 0
    jne     9f
    mov     rdi, [rip+sc_mesh]          # (not on a multires level)
    call    mr_owns
    test    eax, eax
    jz      4f
    lea     rdi, [rip+s_dyn_mr]
    call    log_line
    jmp     9f
4:  xor     dword ptr [rip+sc_dyn], 1
    mov     edi, [rip+sc_nv]            # (the mask stays)
    xor     esi, esi
    call    carry_mask
    mov     edi, [rip+sc_obj]
    call    obj_get
    test    rax, rax
    jz      9f
    mov     rdi, rax
    call    sculpt_build
    test    eax, eax
    jnz     1f
    call    sculpt_exit
    jmp     9f
1:  call    fmt_reset
    cmp     dword ptr [rip+sc_dyn], 0
    jne     2f
    lea     rdi, [rip+s_dyn_off]
    call    fmt_str
    jmp     3f
2:  lea     rdi, [rip+s_dyn_on]
    call    fmt_str
    cvttss2si edi, [rip+dyn_detail]
    call    fmt_int
    lea     rdi, [rip+s_dyn_px]
    call    fmt_str
3:  lea     rdi, [rip+fmt_buf]
    call    log_line
9:  mov     dword ptr [rip+dirty], 1
    pop     rbx
    ret
dyn_check:
    mov     eax, [rip+sc_dyn]
    ret
do_detail:                              # edi = 0 finer, 1 coarser
    movss   xmm0, [rip+dyn_detail]
    mulss   xmm0, [rip+df_finer]
    test    edi, edi
    jz      1f
    movss   xmm0, [rip+dyn_detail]
    mulss   xmm0, [rip+df_coarser]
1:  maxss   xmm0, [rip+df_dmin]
    minss   xmm0, [rip+df_dmax]
    movss   [rip+dyn_detail], xmm0
    mov     dword ptr [rip+dirty], 1
    ret

# =============================================================================
#  Memory
# =============================================================================
# sgrow(rdi=&pointer, rsi=&bytes, rdx=size) -> rax = the mapping, now at
#   least that big (moved, contents kept, the rest zero); 0: no memory
sgrow:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12, rsi
    add     rdx, 4095
    and     rdx, -4096
    mov     r13, rdx
    mov     rdi, [rbx]
    test    rdi, rdi
    jz      5f
    mov     rsi, [r12]
    add     rsi, 4095
    and     rsi, -4096
    cmp     r13, rsi
    jbe     4f
    mov     rdx, r13
    mov     r10d, 1                     # MREMAP_MAYMOVE
    call    plat_mremap
    cmp     rax, -4096
    jae     8f
    mov     [rbx], rax
    mov     [r12], r13
    jmp     9f
4:  mov     rax, rdi
    jmp     9f
5:  mov     rdi, r13
    call    smap
    test    rax, rax
    jz      8f
    mov     [rbx], rax
    mov     [r12], r13
    jmp     9f
8:  xor     eax, eax
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# dyn_alloc -> eax = 1 (0: no memory). sculpt_build, with sv_pos, sv_tris,
#   sc_nv, sc_nt the mesh's: the room the per-vertex arrays get; dyntopo
#   copies the positions and triangles (twice the room, and more)
dyn_alloc:
    push    rbx
    mov     eax, [rip+sc_nv]
    mov     [rip+sc_capv], eax
    mov     eax, [rip+sc_nt]
    mov     [rip+sc_capt], eax
    cmp     dword ptr [rip+sc_dyn], 0
    je      7f
    mov     eax, [rip+sc_nv]
    lea     eax, [rax+rax+65536]
    mov     [rip+sc_capv], eax
    mov     eax, [rip+sc_nt]
    lea     eax, [rax+rax+131072]
    mov     [rip+sc_capt], eax
    mov     edx, [rip+sc_capv]
    imul    rdx, rdx, 12
    lea     rdi, [rip+dw_pos]
    lea     rsi, [rip+dw_pos_b]
    call    salloc
    test    rax, rax
    jz      8f
    mov     rdi, rax
    mov     rsi, [rip+sv_pos]
    mov     ecx, [rip+sc_nv]
    imul    rcx, rcx, 12
    rep     movsb
    mov     rax, [rip+dw_pos]
    mov     [rip+sv_pos], rax
    mov     edx, [rip+sc_capt]
    imul    rdx, rdx, 12
    lea     rdi, [rip+dw_tris]
    lea     rsi, [rip+dw_tris_b]
    call    salloc
    test    rax, rax
    jz      8f
    mov     rdi, rax
    mov     rsi, [rip+sv_tris]
    mov     ecx, [rip+sc_nt]
    imul    rcx, rcx, 12
    rep     movsb
    mov     rax, [rip+dw_tris]
    mov     [rip+sv_tris], rax
    lea     rbx, [rip+dyn_vtab+6*24]    # owners, stamps, local ids
1:  mov     edx, [rip+sc_capv]
    imul    rdx, [rbx+16]
    mov     rdi, [rbx]
    mov     rsi, [rbx+8]
    call    salloc
    test    rax, rax
    jz      8f
    add     rbx, 24
    lea     rax, [rip+dyn_vtab+DYN_NV*24]
    cmp     rbx, rax
    jb      1b
7:  mov     eax, 1
    pop     rbx
    ret
8:  xor     eax, eax
    pop     rbx
    ret

dyn_free:
    sub     rsp, 8
    lea     rdi, [rip+dw_pos]
    lea     rsi, [rip+dw_pos_b]
    call    sfree
    lea     rdi, [rip+dw_tris]
    lea     rsi, [rip+dw_tris_b]
    call    sfree
    lea     rdi, [rip+sc_vown]
    lea     rsi, [rip+sc_vown_b]
    call    sfree
    lea     rdi, [rip+dy_vst]
    lea     rsi, [rip+dy_vst_b]
    call    sfree
    lea     rdi, [rip+dy_vloc]
    lea     rsi, [rip+dy_vloc_b]
    call    sfree
    add     rsp, 8
    ret

# dyn_reserve(edi=vertices, esi=triangles) -> eax = 1 when the working copy
#   (and every per-vertex array) has room for that many (0: no memory)
dyn_reserve:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r12d, edi
    mov     r13d, esi
    cmp     r12d, [rip+sc_capv]
    jbe     5f
    mov     eax, [rip+sc_capv]
    add     eax, eax
    cmp     eax, r12d
    jae     1f
    mov     eax, r12d
1:  mov     r14d, eax
    lea     rbx, [rip+dyn_vtab]
    mov     r15d, DYN_NV
2:  mov     rdi, [rbx]
    cmp     qword ptr [rdi], 0          # (not made yet: left so)
    je      3f
    mov     rsi, [rbx+8]
    mov     edx, r14d
    imul    rdx, [rbx+16]
    call    sgrow
    test    rax, rax
    jz      8f
3:  add     rbx, 24
    dec     r15d
    jnz     2b
    mov     [rip+sc_capv], r14d
    mov     rax, [rip+dw_pos]
    mov     [rip+sv_pos], rax
5:  cmp     r13d, [rip+sc_capt]
    jbe     7f
    mov     eax, [rip+sc_capt]
    add     eax, eax
    cmp     eax, r13d
    jae     6f
    mov     eax, r13d
6:  mov     r14d, eax
    lea     rdi, [rip+dw_tris]
    lea     rsi, [rip+dw_tris_b]
    mov     edx, r14d
    imul    rdx, rdx, 12
    call    sgrow
    test    rax, rax
    jz      8f
    mov     [rip+sc_capt], r14d
    mov     [rip+sv_tris], rax
7:  mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# dyn_tail - sculpt_build, the leaves made: each list's room is its length;
#   dyntopo: each vertex's owner; a mask carried over a rebuild comes back
dyn_tail:
    push    rbx
    push    r12
    push    r13
    xor     ecx, ecx
    mov     rdx, [rip+sc_nodes]
1:  cmp     ecx, [rip+sc_nnodes]
    jae     2f
    mov     eax, [rdx+ND_TN]
    mov     [rdx+ND_TCAP], eax
    mov     eax, [rdx+ND_VN]
    mov     [rdx+ND_VCAP], eax
    add     rdx, ND_SZ
    inc     ecx
    jmp     1b
2:  mov     eax, [rip+sc_nt]
    mov     [rip+sc_tri_used], eax
    cmp     dword ptr [rip+sc_dyn], 0
    je      5f
    mov     rdi, [rip+sc_vown]          # owners: none, then each leaf's own
    mov     ecx, [rip+sc_nv]
    mov     eax, -1
    rep     stosd
    xor     ebx, ebx
3:  cmp     ebx, [rip+sc_nnodes]
    jae     5f
    imul    eax, ebx, ND_SZ
    mov     rdx, [rip+sc_nodes]
    add     rdx, rax
    mov     ecx, [rdx+ND_VOFF]
    mov     r8d, [rdx+ND_VOWN]
    add     r8d, ecx
    mov     r9, [rip+sc_vl]
    mov     r10, [rip+sc_vown]
4:  cmp     ecx, r8d
    jae     41f
    mov     eax, [r9+rcx*4]
    mov     [r10+rax*4], ebx
    inc     ecx
    jmp     4b
41: inc     ebx
    jmp     3b
5:  mov     rsi, [rip+dy_mcarry]
    test    rsi, rsi
    jz      9f
    mov     ecx, [rip+dy_mcarry_n]
    cmp     ecx, [rip+sc_nv]
    jne     8f
    mov     rdi, [rip+sc_mask]
    rep     movsb
    mov     rsi, [rip+sc_mask]
    mov     ecx, [rip+sc_nv]
6:  test    ecx, ecx
    jz      8f
    dec     ecx
    cmp     byte ptr [rsi+rcx], 0
    je      6b
    mov     dword ptr [rip+sc_masked], 1
8:  lea     rdi, [rip+dy_mcarry]
    lea     rsi, [rip+dy_mcarry_b]
    call    sfree
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# carry_mask(edi=vertices, rsi=map vertex -> new index or 0: the same) -
#   the mask, kept for the next build (when anything is masked)
carry_mask:
    push    rbx
    push    r12
    push    r13
    mov     ebx, edi
    mov     r12, rsi
    cmp     dword ptr [rip+sc_masked], 0
    je      9f
    lea     rdi, [rip+dy_mcarry]
    lea     rsi, [rip+dy_mcarry_b]
    call    sfree
    mov     edx, ebx
    lea     rdi, [rip+dy_mcarry]
    lea     rsi, [rip+dy_mcarry_b]
    call    salloc
    test    rax, rax
    jz      9f
    mov     [rip+dy_mcarry_n], ebx
    mov     rsi, [rip+sc_mask]
    test    r12, r12
    jnz     1f
    mov     rdi, rax
    mov     ecx, ebx
    rep     movsb
    jmp     9f
1:  mov     r13d, [rip+dy_serial]       # (the live ones: stamped)
    xor     ecx, ecx
2:  cmp     ecx, [rip+sc_nv]
    jae     9f
    mov     rdx, [rip+dy_vst]
    cmp     [rdx+rcx*4], r13d
    jne     3f
    mov     edx, [r12+rcx*4]
    mov     r8b, [rsi+rcx]
    mov     [rax+rdx], r8b
3:  inc     ecx
    jmp     2b
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Strokes
# =============================================================================
dyn_reset:
    xor     eax, eax                    # (every mirror's)
1:  lea     rcx, [rip+dy_last]
    mov     dword ptr [rcx+rax+12], 0
    add     eax, 16
    cmp     eax, 16*8
    jb      1b
    ret

# dyn_after_dab(xmm0=radius (local), edi=0, or the mirror's mask) - remesh
#   around dab_p once the brush is a quarter radius on (the sphere reaching
#   back to the last one)
dyn_after_dab:
    cmp     dword ptr [rip+sc_dyn], 0
    je      1f
    mov     eax, [rip+sc_brush_now]
    cmp     eax, B_GRAB
    je      1f
    cmp     eax, B_MASK
    jne     2f
1:  ret
2:  push    rbx
    sub     rsp, 16
    movss   [rsp], xmm0
    and     edi, 7                      # (each mirror its own)
    shl     edi, 4
    lea     rbx, [rip+dy_last]
    add     rbx, rdi
3:  movss   xmm0, [rsp]
    cmp     dword ptr [rbx+12], 0
    je      5f
    xorps   xmm1, xmm1
    xor     ecx, ecx
4:  lea     rax, [rip+dab_p]
    movss   xmm2, [rax+rcx*4]
    subss   xmm2, [rbx+rcx*4]
    mulss   xmm2, xmm2
    addss   xmm1, xmm2
    inc     ecx
    cmp     ecx, 3
    jb      4b
    sqrtss  xmm1, xmm1
    movss   xmm2, [rsp]
    mulss   xmm2, [rip+df_quarter]
    comiss  xmm1, xmm2
    jb      9f
    addss   xmm0, xmm1
5:  movss   xmm1, [rsp]                 # the detail: radius / pixels x px
    mulss   xmm1, [rip+dyn_detail]
    divss   xmm1, [rip+sc_radius]
    call    dyn_remesh
    mov     rax, [rip+dab_p]
    mov     [rbx], rax
    mov     eax, [rip+dab_p+8]
    mov     [rbx+8], eax
    mov     dword ptr [rbx+12], 1
9:  add     rsp, 16
    pop     rbx
    ret

# dyn_commit - the end of a dyntopo stroke: the working copy's live
#   triangles become the object's mesh (vertices in leaf order), the mask
#   is carried, the leaves are built again
dyn_commit:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 24
    inc     dword ptr [rip+dy_serial]   # number the live vertices
    mov     r15d, [rip+dy_serial]
    xor     r12d, r12d                  # vertices
    xor     r13d, r13d                  # triangles
    xor     ebx, ebx
1:  cmp     ebx, [rip+sc_nnodes]
    jae     4f
    imul    eax, ebx, ND_SZ
    mov     rbp, [rip+sc_nodes]
    add     rbp, rax
    mov     ecx, [rbp+ND_TOFF]
    mov     r14d, [rbp+ND_TN]
    add     r14d, ecx
    add     r13d, [rbp+ND_TN]
2:  cmp     ecx, r14d
    jae     3f
    mov     rax, [rip+sc_tri]
    mov     eax, [rax+rcx*4]
    lea     rax, [rax+rax*2]
    mov     rdx, [rip+sv_tris]
    lea     r8, [rdx+rax*4]
    xor     r9d, r9d
21: mov     eax, [r8+r9*4]
    mov     rdx, [rip+dy_vst]
    cmp     [rdx+rax*4], r15d
    je      22f
    mov     [rdx+rax*4], r15d
    mov     rdx, [rip+dy_vloc]
    mov     [rdx+rax*4], r12d
    inc     r12d
22: inc     r9d
    cmp     r9d, 3
    jb      21b
    inc     ecx
    jmp     2b
3:  inc     ebx
    jmp     1b
4:  mov     edi, r12d                   # the mesh: a polygon a triangle
    lea     esi, [r13+r13*2]
    mov     edx, r13d
    call    mesh_new
    test    rax, rax
    jz      .Ldc_mem
    mov     rbp, rax
    mov     [rbp+ME_NVERTS], r12d
    mov     [rbp+ME_NPOLYS], r13d
    lea     eax, [r13+r13*2]
    mov     [rbp+ME_NLOOPS], eax
    xor     ecx, ecx                    # positions
5:  cmp     ecx, [rip+sc_nv]
    jae     6f
    mov     rdx, [rip+dy_vst]
    cmp     [rdx+rcx*4], r15d
    jne     51f
    mov     rdx, [rip+dy_vloc]
    mov     eax, [rdx+rcx*4]
    lea     rax, [rax+rax*2]
    mov     rdx, [rbp+ME_POS]
    lea     rdx, [rdx+rax*4]
    lea     rax, [rcx+rcx*2]
    mov     r8, [rip+sv_pos]
    lea     r8, [r8+rax*4]
    mov     rax, [r8]
    mov     [rdx], rax
    mov     eax, [r8+8]
    mov     [rdx+8], eax
51: inc     ecx
    jmp     5b
6:  mov     rdx, [rbp+ME_POFF]          # loop offsets
    xor     ecx, ecx
    xor     eax, eax
61: mov     [rdx+rcx*4], eax
    add     eax, 3
    inc     ecx
    cmp     ecx, r13d
    jbe     61b
    xor     r12d, r12d                  # loops, in the same leaf order
    xor     ebx, ebx
7:  cmp     ebx, [rip+sc_nnodes]
    jae     8f
    imul    eax, ebx, ND_SZ
    mov     rdx, [rip+sc_nodes]
    add     rdx, rax
    mov     ecx, [rdx+ND_TOFF]
    mov     r14d, [rdx+ND_TN]
    add     r14d, ecx
71: cmp     ecx, r14d
    jae     73f
    mov     rax, [rip+sc_tri]
    mov     eax, [rax+rcx*4]
    lea     rax, [rax+rax*2]
    mov     rdx, [rip+sv_tris]
    lea     r8, [rdx+rax*4]
    xor     r9d, r9d
72: mov     eax, [r8+r9*4]
    mov     rdx, [rip+dy_vloc]
    mov     eax, [rdx+rax*4]
    mov     rdx, [rbp+ME_LOOPS]
    mov     [rdx+r12*4], eax
    inc     r12d
    inc     r9d
    cmp     r9d, 3
    jb      72b
    inc     ecx
    jmp     71b
73: inc     ebx
    jmp     7b
8:  mov     rdi, rbp
    call    mesh_finish
    mov     rax, [rbp+ME_NVERTS]        # (keep the mask for the new build)
    mov     edi, eax
    mov     rsi, [rip+dy_vloc]
    call    carry_mask
    mov     edi, [rip+sc_obj]           # the object takes it
    call    obj_get
    test    rax, rax
    jz      .Ldc_drop
    mov     rbx, rax
    mov     rdi, [rbx+OB_MESH]
    mov     [rbx+OB_MESH], rbp
    call    mesh_unref
    mov     rdi, rbx
    call    sculpt_build
    test    eax, eax
    jnz     9f
    call    sculpt_exit
    jmp     9f
.Ldc_drop:
    mov     rdi, rbp
    call    mesh_unref
    jmp     9f
.Ldc_mem:
    lea     rdi, [rip+s_dyn_mem]
    call    log_line
9:  mov     dword ptr [rip+dirty], 1
    add     rsp, 24
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Remeshing
# =============================================================================
# rm_tv(edi=local triangle) -> rax = its corners in the working copy
rm_tv:
    mov     eax, edi
    mov     rcx, [rip+rm_T]
    mov     eax, [rcx+rax*4]
    lea     rax, [rax+rax*2]
    shl     rax, 2
    add     rax, [rip+sv_tris]
    ret

# rm_pos(edi=vertex) -> rax = its position
rm_pos:
    mov     eax, edi
    lea     rax, [rax+rax*2]
    shl     rax, 2
    add     rax, [rip+sv_pos]
    ret

# rm_len2(edi, esi = vertices) -> xmm0 = squared distance
rm_len2:
    call    rm_pos
    mov     rdx, rax
    mov     edi, esi
    call    rm_pos
    movss   xmm0, [rax]
    subss   xmm0, [rdx]
    mulss   xmm0, xmm0
    movss   xmm1, [rax+4]
    subss   xmm1, [rdx+4]
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    movss   xmm1, [rax+8]
    subss   xmm1, [rdx+8]
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    ret

# rm_midin(edi, esi = vertices) -> eax = 1 when their middle (rm_mid) is in
#   the sphere
rm_midin:
    call    rm_pos
    mov     rdx, rax
    mov     edi, esi
    call    rm_pos
    xorps   xmm2, xmm2
    xor     ecx, ecx
1:  movss   xmm0, [rax+rcx*4]
    addss   xmm0, [rdx+rcx*4]
    mulss   xmm0, [rip+df_half]
    lea     r8, [rip+rm_mid]
    movss   [r8+rcx*4], xmm0
    lea     r8, [rip+dab_p]
    subss   xmm0, [r8+rcx*4]
    mulss   xmm0, xmm0
    addss   xmm2, xmm0
    inc     ecx
    cmp     ecx, 3
    jb      1b
    xor     eax, eax
    comiss  xmm2, [rip+rm_r2]
    setb    al
    ret

# rm_key(edi, esi = vertices) -> rax = the edge's key, rcx = its first slot
rm_key:
    cmp     edi, esi
    jbe     1f
    xchg    edi, esi
1:  mov     eax, edi
    shl     rax, 32
    or      rax, rsi
    inc     rax
    mov     rcx, rax
    imul    rcx, qword ptr [rip+df_hashk]
    shr     rcx, 32
    and     ecx, [rip+rm_hmask]
    ret

# rm_insert(edi, esi = the edge's ends, edx = half: local triangle x 3 +
#   corner) - a third half makes the edge unusable (-2)
rm_insert:
    call    rm_key
    mov     r8, [rip+rm_H]
1:  mov     r9, rcx
    shl     r9, 4
    add     r9, r8
    mov     r10, [r9]
    test    r10, r10
    jz      3f
    cmp     r10, rax
    je      4f
    inc     ecx
    and     ecx, [rip+rm_hmask]
    jmp     1b
3:  mov     [r9], rax
    mov     [r9+8], edx
    mov     dword ptr [r9+12], -1
    ret
4:  cmp     dword ptr [r9+12], -1
    jne     5f
    cmp     dword ptr [r9+8], -2
    je      5f
    mov     [r9+12], edx
    ret
5:  mov     dword ptr [r9+8], -2
    mov     dword ptr [r9+12], -2
    ret

# rm_find(edi, esi = ends) -> rax = the edge's entry (0: none)
rm_find:
    call    rm_key
    mov     r8, [rip+rm_H]
1:  mov     r9, rcx
    shl     r9, 4
    add     r9, r8
    mov     r10, [r9]
    test    r10, r10
    jz      3f
    cmp     r10, rax
    je      4f
    inc     ecx
    and     ecx, [rip+rm_hmask]
    jmp     1b
3:  xor     eax, eax
    ret
4:  mov     rax, r9
    ret

# rm_other(edi=local triangle, esi=corner) -> eax = the other half of that
#   edge (local x 3 + corner), -1 when it has none (or more than one)
rm_other:
    push    rbx
    push    r12
    sub     rsp, 8
    lea     ebx, [rdi+rdi*2]
    add     ebx, esi
    call    rm_tv
    mov     edi, [rax+rsi*4]
    lea     ecx, [rsi+1]
    cmp     ecx, 3
    jb      1f
    xor     ecx, ecx
1:  mov     esi, [rax+rcx*4]
    call    rm_find
    test    rax, rax
    jz      8f
    mov     ecx, [rax+8]
    mov     edx, [rax+12]
    test    ecx, ecx
    js      8f
    test    edx, edx
    js      8f
    mov     eax, ecx
    cmp     ecx, ebx
    jne     9f
    mov     eax, edx
    jmp     9f
8:  mov     eax, -1
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# rm_hash -> eax = 1: the edge hash of the live triangles (0: no memory)
rm_hash:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     eax, [rip+rm_nT]
    shl     eax, 2
    mov     ecx, 64
1:  cmp     ecx, eax
    jae     2f
    add     ecx, ecx
    jmp     1b
2:  mov     [rip+rm_hsize], ecx
    dec     ecx
    mov     [rip+rm_hmask], ecx
    lea     rdi, [rip+frame_arena]
    mov     esi, [rip+rm_hsize]
    shl     esi, 4
    call    arena_alloc
    test    rax, rax
    jz      8f
    mov     [rip+rm_H], rax
    mov     rdi, rax
    mov     ecx, [rip+rm_hsize]
    add     ecx, ecx
    xor     eax, eax
    rep     stosq
    xor     r12d, r12d
3:  cmp     r12d, [rip+rm_nT]
    jae     7f
    mov     edi, r12d
    call    rm_tv
    mov     r13, rax
    cmp     dword ptr [r13], DEAD
    je      6f
    xor     r14d, r14d
4:  mov     edi, [r13+r14*4]
    lea     ecx, [r14+1]
    cmp     ecx, 3
    jb      5f
    xor     ecx, ecx
5:  mov     esi, [r13+rcx*4]
    lea     edx, [r12+r12*2]
    add     edx, r14d
    call    rm_insert
    inc     r14d
    cmp     r14d, 3
    jb      4b
6:  inc     r12d
    jmp     3b
7:  mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# rm_clear_mod - nothing changed in this pass yet
rm_clear_mod:
    mov     rdi, [rip+rm_TM]
    mov     ecx, [rip+rm_nT]
    xor     eax, eax
    rep     stosb
    ret

# rm_split_pass -> eax = edges split: in each triangle not yet changed in
#   this pass, its longest edge over the detail (middle in the sphere)
rm_split_pass:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 56
    mov     dword ptr [rsp+44], 0
    call    rm_hash
    test    eax, eax
    jz      9f
    call    rm_clear_mod
    mov     eax, [rip+rm_nT]
    mov     [rsp+40], eax
    xor     r12d, r12d
1:  cmp     r12d, [rsp+40]
    jae     9f
    mov     rax, [rip+rm_TM]
    cmp     byte ptr [rax+r12], 0
    jne     8f
    mov     edi, r12d
    call    rm_tv
    mov     r13, rax
    cmp     dword ptr [r13], DEAD
    je      8f
    mov     edi, r12d                   # its longest edge: over the detail,
    call    rm_longest                  #  its middle in the sphere
    mov     r14d, eax
    movss   [rsp+52], xmm0
    comiss  xmm0, [rip+rm_dmax2]
    jbe     8f
    mov     edi, [r13+r14*4]
    mov     ecx, r14d
    call    rm_next
    mov     esi, [r13+rcx*4]
    call    rm_midin
    test    eax, eax
    jz      8f
    mov     edi, r12d
    mov     esi, r14d
    call    rm_other
    test    eax, eax
    js      8f
    xor     edx, edx
    mov     ecx, 3
    div     ecx
    mov     r15d, eax                   # the other triangle, its corner
    mov     ebp, edx
    cmp     r15d, r12d
    je      8f
    mov     rax, [rip+rm_TM]
    cmp     byte ptr [rax+r15], 0
    jne     8f
    mov     edi, r15d                   # (and not the short side of the
    call    rm_longest                  #  other: no slivers)
    mulss   xmm0, [rip+df_049]
    comiss  xmm0, [rsp+52]
    ja      8f
    mov     eax, [rip+rm_nT]
    add     eax, 2
    cmp     eax, [rip+rm_Tcap]
    ja      9f
    mov     eax, [rip+sc_nv]            # (room was reserved for this many)
    cmp     eax, [rip+sc_capv]
    jae     9f
    mov     eax, [rip+sc_nt]
    add     eax, 2
    cmp     eax, [rip+sc_capt]
    ja      9f
    mov     edi, r12d
    mov     esi, r14d
    mov     edx, r15d
    mov     ecx, ebp
    call    rm_split
    inc     dword ptr [rsp+44]
8:  inc     r12d
    jmp     1b
9:  mov     eax, [rsp+44]
    add     rsp, 56
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# rm_longest(edi=local triangle) -> eax = the corner its longest edge starts
#   at, xmm0 = its squared length
rm_longest:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 16
    call    rm_tv
    mov     rbx, rax
    xor     r12d, r12d
    mov     r13d, -1
    xorps   xmm0, xmm0
    movss   [rsp], xmm0
1:  mov     edi, [rbx+r12*4]
    mov     ecx, r12d
    call    rm_next
    mov     esi, [rbx+rcx*4]
    call    rm_len2
    comiss  xmm0, [rsp]
    jbe     2f
    movss   [rsp], xmm0
    mov     r13d, r12d
2:  inc     r12d
    cmp     r12d, 3
    jb      1b
    mov     eax, r13d
    test    eax, eax
    jns     3f
    xor     eax, eax
3:  movss   xmm0, [rsp]
    add     rsp, 16
    pop     r13
    pop     r12
    pop     rbx
    ret

# rm_split(edi=k, esi=corner e, edx=k2, ecx=corner e2) - the edge from
#   corner e of k (= corner e2 of k2, the other way) is halved: a new vertex
#   m in the middle, (a b x) -> (a m x) + (m b x), (p q y) -> (p m y) +
#   (m q y)
rm_split:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 40
    mov     [rsp], edi
    mov     [rsp+4], esi
    mov     [rsp+8], edx
    mov     [rsp+12], ecx
    call    rm_tv
    mov     r12, rax                    # k's corners
    mov     edi, [rsp+8]
    call    rm_tv
    mov     r13, rax                    # k2's
    mov     ecx, [rsp+4]                # a, b, x
    mov     eax, [r12+rcx*4]
    mov     [rsp+16], eax
    call    rm_next
    mov     [rsp+28], ecx               # (b's corner)
    mov     eax, [r12+rcx*4]
    mov     [rsp+20], eax
    call    rm_next
    mov     eax, [r12+rcx*4]
    mov     [rsp+24], eax
    mov     ebx, [rip+sc_nv]            # m
    inc     dword ptr [rip+sc_nv]
    mov     edi, [rsp+16]
    call    rm_pos
    mov     r14, rax
    mov     edi, [rsp+20]
    call    rm_pos
    mov     r15, rax
    mov     edi, ebx
    call    rm_pos
    xor     ecx, ecx
1:  movss   xmm0, [r14+rcx*4]
    addss   xmm0, [r15+rcx*4]
    mulss   xmm0, [rip+df_half]
    movss   [rax+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      1b
    mov     edi, [rsp+16]               # its normal, mask, no owner yet
    mov     esi, [rsp+20]
    mov     edx, ebx
    call    rm_vmerge
    mov     rax, [rip+sc_vown]
    mov     dword ptr [rax+rbx*4], -1
    mov     ecx, [rsp+28]               # k: (a m x)
    mov     [r12+rcx*4], ebx
    mov     edi, [rip+sc_nt]            # + (m b x)
    inc     dword ptr [rip+sc_nt]
    mov     ebp, edi
    lea     rax, [rdi+rdi*2]
    shl     rax, 2
    add     rax, [rip+sv_tris]
    mov     [rax], ebx
    mov     ecx, [rsp+20]
    mov     [rax+4], ecx
    mov     ecx, [rsp+24]
    mov     [rax+8], ecx
    mov     esi, [rsp]
    call    rm_append
    mov     ecx, [rsp+12]               # k2: p q y
    mov     eax, [r13+rcx*4]
    mov     [rsp+16], eax
    call    rm_next
    mov     [rsp+28], ecx
    mov     eax, [r13+rcx*4]
    mov     [rsp+20], eax
    call    rm_next
    mov     eax, [r13+rcx*4]
    mov     [rsp+24], eax
    mov     ecx, [rsp+28]               # (p m y)
    mov     [r13+rcx*4], ebx
    mov     edi, [rip+sc_nt]            # + (m q y)
    inc     dword ptr [rip+sc_nt]
    mov     ebp, edi
    lea     rax, [rdi+rdi*2]
    shl     rax, 2
    add     rax, [rip+sv_tris]
    mov     [rax], ebx
    mov     ecx, [rsp+20]
    mov     [rax+4], ecx
    mov     ecx, [rsp+24]
    mov     [rax+8], ecx
    mov     esi, [rsp+8]
    call    rm_append
    mov     rax, [rip+rm_TM]
    mov     ecx, [rsp]
    mov     byte ptr [rax+rcx], 1
    mov     ecx, [rsp+8]
    mov     byte ptr [rax+rcx], 1
    mov     dword ptr [rip+rm_changed], 1
    add     rsp, 40
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# rm_next(ecx=corner) -> ecx = the next one (0 after 2)
rm_next:
    inc     ecx
    cmp     ecx, 3
    jb      1f
    xor     ecx, ecx
1:  ret

# rm_append(edi=triangle id, esi=local triangle whose leaf it joins) - a
#   new local triangle, changed in this pass
rm_append:
    mov     eax, [rip+rm_nT]
    mov     rcx, [rip+rm_T]
    mov     [rcx+rax*4], edi
    mov     rcx, [rip+rm_TL]
    mov     edx, [rcx+rsi*4]
    mov     [rcx+rax*4], edx
    mov     rcx, [rip+rm_TM]
    mov     byte ptr [rcx+rax], 1
    inc     dword ptr [rip+rm_nT]
    ret

# rm_vmerge(edi=a, esi=b, edx=into) - normal: the two normalized; mask: the
#   larger
rm_vmerge:
    mov     r8, [rip+sc_vn]
    lea     rax, [rdi+rdi*2]
    lea     r9, [r8+rax*4]
    lea     rax, [rsi+rsi*2]
    lea     r10, [r8+rax*4]
    lea     rax, [rdx+rdx*2]
    lea     r11, [r8+rax*4]
    movss   xmm0, [r9]
    addss   xmm0, [r10]
    movss   xmm1, [r9+4]
    addss   xmm1, [r10+4]
    movss   xmm2, [r9+8]
    addss   xmm2, [r10+8]
    movss   xmm3, xmm0
    mulss   xmm3, xmm0
    movss   xmm4, xmm1
    mulss   xmm4, xmm1
    addss   xmm3, xmm4
    movss   xmm4, xmm2
    mulss   xmm4, xmm2
    addss   xmm3, xmm4
    comiss  xmm3, [rip+df_tiny]
    jbe     1f
    sqrtss  xmm3, xmm3
    movss   xmm4, [rip+df_one]
    divss   xmm4, xmm3
    mulss   xmm0, xmm4
    mulss   xmm1, xmm4
    mulss   xmm2, xmm4
    jmp     2f
1:  movss   xmm0, [r9]
    movss   xmm1, [r9+4]
    movss   xmm2, [r9+8]
2:  movss   [r11], xmm0
    movss   [r11+4], xmm1
    movss   [r11+8], xmm2
    mov     r8, [rip+sc_mask]
    movzx   eax, byte ptr [r8+rdi]
    movzx   ecx, byte ptr [r8+rsi]
    cmp     eax, ecx
    jae     3f
    mov     eax, ecx
3:  mov     [r8+rdx], al
    ret

# rm_rings -> eax = 1: local vertex ids (dy_vloc, stamped) and each one's
#   live triangles (rm_roff / rm_rt), locks and link marks cleared
rm_rings:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    inc     dword ptr [rip+dy_serial]
    mov     r15d, [rip+dy_serial]
    xor     ebx, ebx                    # local vertices
    xor     r12d, r12d
1:  cmp     r12d, [rip+rm_nT]
    jae     3f
    mov     edi, r12d
    call    rm_tv
    cmp     dword ptr [rax], DEAD
    je      21f
    xor     ecx, ecx
2:  mov     edx, [rax+rcx*4]
    mov     r8, [rip+dy_vst]
    cmp     [r8+rdx*4], r15d
    je      20f
    mov     [r8+rdx*4], r15d
    mov     r8, [rip+dy_vloc]
    mov     [r8+rdx*4], ebx
    inc     ebx
20: inc     ecx
    cmp     ecx, 3
    jb      2b
21: inc     r12d
    jmp     1b
3:  mov     [rip+rm_nvl], ebx
    lea     rdi, [rip+frame_arena]      # offsets (+2), triangles, locks, marks
    lea     esi, [rbx*4+16]
    call    arena_alloc
    test    rax, rax
    jz      8f
    mov     [rip+rm_roff], rax
    mov     rdi, rax
    lea     ecx, [rbx+2]
    xor     eax, eax
    rep     stosd
    lea     rdi, [rip+frame_arena]
    mov     esi, [rip+rm_nT]
    lea     esi, [rsi+rsi*2]
    shl     esi, 2
    add     esi, 16
    call    arena_alloc
    test    rax, rax
    jz      8f
    mov     [rip+rm_rt], rax
    lea     rdi, [rip+frame_arena]
    lea     esi, [rbx+16]
    call    arena_alloc
    test    rax, rax
    jz      8f
    mov     [rip+rm_vlock], rax
    mov     rdi, rax
    mov     ecx, ebx
    xor     eax, eax
    rep     stosb
    lea     rdi, [rip+frame_arena]
    lea     esi, [rbx*4+16]
    call    arena_alloc
    test    rax, rax
    jz      8f
    mov     [rip+rm_nb], rax
    mov     rdi, rax
    mov     ecx, ebx
    xor     eax, eax
    rep     stosd
    mov     dword ptr [rip+rm_cs], 1
    mov     r13, [rip+rm_roff]          # counts at +2 ...
    xor     r12d, r12d
4:  cmp     r12d, [rip+rm_nT]
    jae     5f
    mov     edi, r12d
    call    rm_tv
    cmp     dword ptr [rax], DEAD
    je      41f
    xor     ecx, ecx
40: mov     edx, [rax+rcx*4]
    mov     r8, [rip+dy_vloc]
    mov     edx, [r8+rdx*4]
    inc     dword ptr [r13+rdx*4+8]
    inc     ecx
    cmp     ecx, 3
    jb      40b
41: inc     r12d
    jmp     4b
5:  xor     ecx, ecx                    # ... prefix: roff[j+1] = start of j
    xor     eax, eax                    #  + 1 (a cursor), roff[j] its start
50: cmp     ecx, ebx
    jae     51f
    add     eax, [r13+rcx*4+8]
    mov     [r13+rcx*4+8], eax
    inc     ecx
    jmp     50b
51: xor     r12d, r12d                  # fill through the cursors at +1
6:  cmp     r12d, [rip+rm_nT]
    jae     7f
    mov     edi, r12d
    call    rm_tv
    cmp     dword ptr [rax], DEAD
    je      61f
    xor     ecx, ecx
60: mov     edx, [rax+rcx*4]
    mov     r8, [rip+dy_vloc]
    mov     edx, [r8+rdx*4]
    mov     r9d, [r13+rdx*4+4]
    inc     dword ptr [r13+rdx*4+4]
    mov     r8, [rip+rm_rt]
    mov     [r8+r9*4], r12d
    inc     ecx
    cmp     ecx, 3
    jb      60b
61: inc     r12d
    jmp     6b
7:  mov     eax, 1                      # (now roff[j] .. roff[j+1]: j's)
    jmp     9f
8:  xor     eax, eax
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# rm_collapse_pass -> eax = edges collapsed (under 0.4 detail, middle in the
#   sphere, one around a vertex a pass)
rm_collapse_pass:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 40
    mov     dword ptr [rsp+32], 0
    call    rm_hash
    test    eax, eax
    jz      9f
    call    rm_rings
    test    eax, eax
    jz      9f
    call    rm_clear_mod
    xor     r12d, r12d
1:  cmp     r12d, [rip+rm_nT]
    jae     9f
    mov     rax, [rip+rm_TM]
    cmp     byte ptr [rax+r12], 0
    jne     8f
    mov     edi, r12d
    call    rm_tv
    mov     r13, rax
    cmp     dword ptr [r13], DEAD
    je      8f
    xor     r14d, r14d
2:  mov     edi, [r13+r14*4]
    mov     ecx, r14d
    call    rm_next
    mov     esi, [r13+rcx*4]
    mov     [rsp], edi
    mov     [rsp+4], esi
    call    rm_len2
    comiss  xmm0, [rip+rm_dmin2]
    jae     3f
    mov     edi, [rsp]
    mov     esi, [rsp+4]
    call    rm_midin
    test    eax, eax
    jz      3f
    mov     edi, r12d
    mov     esi, r14d
    call    rm_other
    test    eax, eax
    js      3f
    mov     edi, [rsp]
    mov     esi, [rsp+4]
    call    rm_collapse
    test    eax, eax
    jz      3f
    inc     dword ptr [rsp+32]
    jmp     8f
3:  inc     r14d
    cmp     r14d, 3
    jb      2b
8:  inc     r12d
    jmp     1b
9:  mov     eax, [rsp+32]
    add     rsp, 40
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# rm_ring(edi=vertex) -> rax = its local triangles, ecx = how many
rm_ring:
    mov     rax, [rip+dy_vloc]
    mov     eax, [rax+rdi*4]
    mov     rdx, [rip+rm_roff]
    mov     ecx, [rdx+rax*4+4]
    mov     edx, [rdx+rax*4]
    sub     ecx, edx
    mov     rax, [rip+rm_rt]
    lea     rax, [rax+rdx*4]
    ret

# rm_collapse(edi=a, esi=b; rm_mid their middle) -> eax = 1 when collapsed:
#   b moves to the middle, a's triangles take b, the two on the edge go
rm_collapse:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 72
    mov     [rsp], edi
    mov     [rsp+4], esi
    mov     rax, [rip+dy_vloc]          # not locked this pass
    mov     ecx, [rax+rdi*4]
    mov     edx, [rax+rsi*4]
    mov     r8, [rip+rm_vlock]
    cmp     byte ptr [r8+rcx], 0
    jne     .Lrc_no
    cmp     byte ptr [r8+rdx], 0
    jne     .Lrc_no
    mov     [rsp+8], ecx                # (local ids)
    mov     [rsp+12], edx
    # each ring: unchanged this pass; every edge at the vertex with two
    #   triangles (no border, nothing odd)
    xor     ebp, ebp                    # side: 0 a, 1 b
.Lrc_side:
    mov     edi, [rsp+rbp*4]
    call    rm_ring
    mov     r12, rax
    mov     r13d, ecx
    mov     [rsp+16+rbp*4], ecx         # (valences)
    xor     ebx, ebx
1:  cmp     ebx, r13d
    jae     4f
    mov     r14d, [r12+rbx*4]
    mov     rax, [rip+rm_TM]
    cmp     byte ptr [rax+r14], 0
    jne     .Lrc_no
    mov     edi, r14d
    call    rm_tv
    mov     r15, rax
    xor     ecx, ecx                    # its corner at the vertex
    mov     edx, [rsp+rbp*4]
2:  cmp     [r15+rcx*4], edx
    je      3f
    inc     ecx
    cmp     ecx, 3
    jb      2b
    jmp     .Lrc_no
3:  mov     [rsp+24], ecx
    mov     edi, r14d                   # the edge out of it ...
    mov     esi, ecx
    call    rm_other
    test    eax, eax
    js      .Lrc_no
    mov     ecx, [rsp+24]               # ... and the one into it
    add     ecx, 2
    cmp     ecx, 3
    jb      31f
    sub     ecx, 3
31: mov     edi, r14d
    mov     esi, ecx
    call    rm_other
    test    eax, eax
    js      .Lrc_no
    inc     ebx
    jmp     1b
4:  inc     ebp
    cmp     ebp, 2
    jb      .Lrc_side
    mov     eax, [rsp+16]               # merged valence va + vb - 4 >= 3
    add     eax, [rsp+20]
    cmp     eax, 7
    jl      .Lrc_no
    # link: exactly two shared neighbours, each keeping three edges or more
    add     dword ptr [rip+rm_cs], 2
    mov     r15d, [rip+rm_cs]
    mov     edi, [rsp]
    call    rm_ring
    mov     r12, rax
    mov     r13d, ecx
    xor     ebx, ebx
5:  cmp     ebx, r13d
    jae     6f
    mov     edi, [r12+rbx*4]
    call    rm_tv
    xor     ecx, ecx
51: mov     edx, [rax+rcx*4]
    cmp     edx, [rsp]
    je      52f
    mov     r8, [rip+dy_vloc]
    mov     edx, [r8+rdx*4]
    mov     r8, [rip+rm_nb]
    mov     [r8+rdx*4], r15d
52: inc     ecx
    cmp     ecx, 3
    jb      51b
    inc     ebx
    jmp     5b
6:  mov     dword ptr [rsp+28], 0       # shared
    mov     edi, [rsp+4]
    call    rm_ring
    mov     r12, rax
    mov     r13d, ecx
    xor     ebx, ebx
61: cmp     ebx, r13d
    jae     65f
    mov     edi, [r12+rbx*4]
    call    rm_tv
    xor     ecx, ecx
62: mov     edx, [rax+rcx*4]
    cmp     edx, [rsp]
    je      64f
    cmp     edx, [rsp+4]
    je      64f
    mov     r8, [rip+dy_vloc]
    mov     edx, [r8+rdx*4]
    mov     r8, [rip+rm_nb]
    cmp     [r8+rdx*4], r15d
    jne     64f
    lea     r9d, [r15+1]
    mov     [r8+rdx*4], r9d
    inc     dword ptr [rsp+28]
    mov     r8, [rip+rm_roff]           # its valence
    mov     r9d, [r8+rdx*4+4]
    sub     r9d, [r8+rdx*4]
    cmp     r9d, 4
    jl      .Lrc_no
64: inc     ecx
    cmp     ecx, 3
    jb      62b
    inc     ebx
    jmp     61b
65: cmp     dword ptr [rsp+28], 2
    jne     .Lrc_no
    # no triangle turns over: each one keeping a side, a or b at the middle
    xor     ebp, ebp
.Lrc_flip:
    mov     edi, [rsp+rbp*4]
    call    rm_ring
    mov     r12, rax
    mov     r13d, ecx
    xor     ebx, ebx
7:  cmp     ebx, r13d
    jae     79f
    mov     edi, [r12+rbx*4]
    call    rm_tv
    mov     r14, rax
    xor     ecx, ecx                    # with both: it goes
    xor     edx, edx
71: mov     eax, [r14+rcx*4]
    cmp     eax, [rsp]
    je      711f
    cmp     eax, [rsp+4]
    jne     712f
711:inc     edx
712:inc     ecx
    cmp     ecx, 3
    jb      71b
    cmp     edx, 2
    jae     78f
    xor     ecx, ecx                    # corners now (rsp+32..), then with
72: mov     edi, [r14+rcx*4]            #  the middle (rsp++36 ...)
    call    rm_pos
    imul    edx, ecx, 12
    mov     r8, [rax]
    mov     [rsp+32+rdx], r8
    mov     r8d, [rax+8]
    mov     [rsp+32+rdx+8], r8d
    inc     ecx
    cmp     ecx, 3
    jb      72b
    lea     rdi, [rsp+32]
    call    tri_qual2                   # (its shape, before)
    movss   [rsp+16], xmm0
    lea     rdi, [rsp+32]
    call    tri_normal                  # xmm0..2
    movss   [rsp+24], xmm0
    movss   [rsp+28], xmm1
    movss   [rsp+68], xmm2
    xor     ecx, ecx
73: mov     eax, [r14+rcx*4]
    cmp     eax, [rsp]
    je      731f
    cmp     eax, [rsp+4]
    jne     732f
731:imul    edx, ecx, 12
    mov     r8, [rip+rm_mid]
    mov     [rsp+32+rdx], r8
    mov     r8d, [rip+rm_mid+8]
    mov     [rsp+32+rdx+8], r8d
732:inc     ecx
    cmp     ecx, 3
    jb      73b
    lea     rdi, [rsp+32]               # no sliver: the shape stays over
    call    tri_qual2                   #  0.03 (or no worse than it was)
    comiss  xmm0, [rip+df_q2]
    jae     733f
    comiss  xmm0, [rsp+16]
    jb      .Lrc_no
733:lea     rdi, [rsp+32]
    call    tri_normal
    movss   xmm3, xmm0                  # dot, |old|^2 |new|^2
    mulss   xmm3, [rsp+24]
    movss   xmm4, xmm1
    mulss   xmm4, [rsp+28]
    addss   xmm3, xmm4
    movss   xmm4, xmm2
    mulss   xmm4, [rsp+68]
    addss   xmm3, xmm4
    xorps   xmm4, xmm4
    comiss  xmm3, xmm4
    jbe     .Lrc_no
    mulss   xmm0, xmm0
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    mulss   xmm2, xmm2
    addss   xmm0, xmm2                  # |new|^2
    movss   xmm1, [rsp+24]
    mulss   xmm1, xmm1
    movss   xmm2, [rsp+28]
    mulss   xmm2, xmm2
    addss   xmm1, xmm2
    movss   xmm2, [rsp+68]
    mulss   xmm2, xmm2
    addss   xmm1, xmm2                  # |old|^2
    mulss   xmm0, xmm1
    mulss   xmm0, [rip+df_cos2]
    mulss   xmm3, xmm3
    comiss  xmm3, xmm0
    jbe     .Lrc_no
78: inc     ebx
    jmp     7b
79: inc     ebp
    cmp     ebp, 2
    jb      .Lrc_flip
    # collapse: b to the middle (normal, mask merged), a's triangles to b
    mov     edi, [rsp+4]
    call    rm_pos
    mov     rcx, [rip+rm_mid]
    mov     [rax], rcx
    mov     ecx, [rip+rm_mid+8]
    mov     [rax+8], ecx
    mov     edi, [rsp]
    mov     esi, [rsp+4]
    mov     edx, esi
    call    rm_vmerge
    mov     edi, [rsp]
    call    rm_ring
    mov     r12, rax
    mov     r13d, ecx
    xor     ebx, ebx
8:  cmp     ebx, r13d
    jae     84f
    mov     edi, [r12+rbx*4]
    call    rm_tv
    xor     ecx, ecx                    # has b: gone
81: mov     edx, [rax+rcx*4]
    cmp     edx, [rsp+4]
    je      83f
    inc     ecx
    cmp     ecx, 3
    jb      81b
    xor     ecx, ecx                    # else a -> b
82: mov     edx, [rax+rcx*4]
    cmp     edx, [rsp]
    jne     821f
    mov     edx, [rsp+4]
    mov     [rax+rcx*4], edx
821:inc     ecx
    cmp     ecx, 3
    jb      82b
    jmp     88f
83: mov     dword ptr [rax], DEAD
88: inc     ebx
    jmp     8b
84: xor     ebp, ebp                    # both rings: changed; both: locked
85: mov     edi, [rsp+rbp*4]
    call    rm_ring
    xor     edx, edx
86: cmp     edx, ecx
    jae     87f
    mov     r8d, [rax+rdx*4]
    mov     r9, [rip+rm_TM]
    mov     byte ptr [r9+r8], 1
    inc     edx
    jmp     86b
87: mov     eax, [rsp+8+rbp*4]
    mov     r9, [rip+rm_vlock]
    mov     byte ptr [r9+rax], 1
    inc     ebp
    cmp     ebp, 2
    jb      85b
    mov     dword ptr [rip+rm_changed], 1
    mov     eax, 1
    jmp     9f
.Lrc_no:
    xor     eax, eax
9:  add     rsp, 72
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# tri_qual2(rdi=three positions) -> xmm0 = (|normal| / sum of squared edges)^2
#   (0.083 equilateral, 0 flat)
tri_qual2:
    sub     rsp, 8
    call    tri_normal
    mulss   xmm0, xmm0
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    mulss   xmm2, xmm2
    addss   xmm0, xmm2                  # |n|^2
    xorps   xmm1, xmm1                  # sum of squared edges
    xor     ecx, ecx
1:  imul    eax, ecx, 12
    lea     edx, [rcx+1]
    cmp     edx, 3
    jb      2f
    xor     edx, edx
2:  imul    edx, edx, 12
    movss   xmm2, [rdi+rax]
    subss   xmm2, [rdi+rdx]
    mulss   xmm2, xmm2
    addss   xmm1, xmm2
    movss   xmm2, [rdi+rax+4]
    subss   xmm2, [rdi+rdx+4]
    mulss   xmm2, xmm2
    addss   xmm1, xmm2
    movss   xmm2, [rdi+rax+8]
    subss   xmm2, [rdi+rdx+8]
    mulss   xmm2, xmm2
    addss   xmm1, xmm2
    inc     ecx
    cmp     ecx, 3
    jb      1b
    mulss   xmm1, xmm1
    maxss   xmm1, [rip+df_tiny]
    divss   xmm0, xmm1
    add     rsp, 8
    ret

# tri_normal(rdi=three positions) -> xmm0..2 = (p1 - p0) x (p2 - p0)
tri_normal:
    movss   xmm3, [rdi+12]
    subss   xmm3, [rdi]
    movss   xmm4, [rdi+16]
    subss   xmm4, [rdi+4]
    movss   xmm5, [rdi+20]
    subss   xmm5, [rdi+8]
    movss   xmm6, [rdi+24]
    subss   xmm6, [rdi]
    movss   xmm7, [rdi+28]
    subss   xmm7, [rdi+4]
    movss   xmm8, [rdi+32]
    subss   xmm8, [rdi+8]
    movss   xmm0, xmm4                  # y1 z2 - z1 y2
    mulss   xmm0, xmm8
    movss   xmm9, xmm5
    mulss   xmm9, xmm7
    subss   xmm0, xmm9
    movss   xmm1, xmm5                  # z1 x2 - x1 z2
    mulss   xmm1, xmm6
    movss   xmm9, xmm3
    mulss   xmm9, xmm8
    subss   xmm1, xmm9
    movss   xmm2, xmm3                  # x1 y2 - y1 x2
    mulss   xmm2, xmm7
    movss   xmm9, xmm4
    mulss   xmm9, xmm6
    subss   xmm2, xmm9
    ret

# dyn_remesh(xmm0=radius, xmm1=detail; both local, around dab_p) - split
#   and collapse inside that sphere, the leaves around brought up to date
dyn_remesh:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 40
    movss   [rip+rm_r], xmm0
    mulss   xmm0, xmm0
    movss   [rip+rm_r2], xmm0
    movss   xmm2, xmm1
    mulss   xmm2, xmm2
    movss   [rip+rm_dmax2], xmm2
    mulss   xmm1, [rip+df_04]
    mulss   xmm1, xmm1
    movss   [rip+rm_dmin2], xmm1
    mov     dword ptr [rip+rm_changed], 0
    call    fa_mark
    mov     [rip+rm_mark], rax
    movss   xmm0, [rip+rm_r]            # the leaves within r + 2 edges
    movss   xmm1, [rip+sc_maxedge]
    addss   xmm1, xmm1
    addss   xmm0, xmm1
    mov     edi, 2
    call    reach
    test    eax, eax
    jz      .Ldr_out
    mov     [rip+rm_nL], eax
    lea     rdi, [rip+frame_arena]
    lea     esi, [rax*4+16]
    call    arena_alloc
    test    rax, rax
    jz      .Ldr_out
    mov     [rip+rm_L], rax
    mov     rdi, rax
    mov     esi, [rip+sc_nnodes]
    shl     rsi, 3
    add     rsi, [rip+sc_hits]
    mov     ecx, [rip+rm_nL]
    rep     movsd
    lea     rdi, [rip+frame_arena]      # leaf -> its place (-1: not here)
    mov     esi, [rip+sc_nnodes]
    lea     esi, [rsi*4+16]
    call    arena_alloc
    test    rax, rax
    jz      .Ldr_out
    mov     [rip+rm_lidx], rax
    mov     rdi, rax
    mov     ecx, [rip+sc_nnodes]
    mov     eax, -1
    rep     stosd
    xor     ecx, ecx
    xor     r12d, r12d                  # their triangles
1:  cmp     ecx, [rip+rm_nL]
    jae     2f
    mov     rax, [rip+rm_L]
    mov     eax, [rax+rcx*4]
    mov     rdx, [rip+rm_lidx]
    mov     [rdx+rax*4], ecx
    imul    eax, eax, ND_SZ
    add     rax, [rip+sc_nodes]
    add     r12d, [rax+ND_TN]
    inc     ecx
    jmp     1b
2:  mov     edi, [rip+sc_nv]            # room: each split one vertex, two
    lea     edi, [rdi+r12*4+64]         #  triangles
    mov     esi, [rip+sc_nt]
    lea     esi, [rsi+r12*8+64]
    call    dyn_reserve
    test    eax, eax
    jz      .Ldr_mem
    lea     eax, [r12*8+64]
    mov     [rip+rm_Tcap], eax
    lea     rdi, [rip+frame_arena]
    lea     esi, [rax*4]
    call    arena_alloc
    test    rax, rax
    jz      .Ldr_out
    mov     [rip+rm_T], rax
    lea     rdi, [rip+frame_arena]
    mov     esi, [rip+rm_Tcap]
    shl     esi, 2
    call    arena_alloc
    test    rax, rax
    jz      .Ldr_out
    mov     [rip+rm_TL], rax
    lea     rdi, [rip+frame_arena]
    mov     esi, [rip+rm_Tcap]
    call    arena_alloc
    test    rax, rax
    jz      .Ldr_out
    mov     [rip+rm_TM], rax
    xor     r13d, r13d                  # fill: id, leaf
    xor     ebx, ebx
3:  cmp     ebx, [rip+rm_nL]
    jae     5f
    mov     rax, [rip+rm_L]
    mov     r14d, [rax+rbx*4]
    imul    eax, r14d, ND_SZ
    add     rax, [rip+sc_nodes]
    mov     ecx, [rax+ND_TOFF]
    mov     r15d, [rax+ND_TN]
    add     r15d, ecx
4:  cmp     ecx, r15d
    jae     41f
    mov     rax, [rip+sc_tri]
    mov     eax, [rax+rcx*4]
    mov     rdx, [rip+rm_T]
    mov     [rdx+r13*4], eax
    mov     rdx, [rip+rm_TL]
    mov     [rdx+r13*4], r14d
    inc     r13d
    inc     ecx
    jmp     4b
41: inc     ebx
    jmp     3b
5:  mov     [rip+rm_nT], r13d
    mov     ebx, 4                      # splits: up to four passes
6:  call    rm_split_pass
    test    eax, eax
    jz      7f
    dec     ebx
    jnz     6b
7:  call    rm_collapse_pass
    cmp     dword ptr [rip+rm_changed], 0
    je      .Ldr_out
    call    rm_finish
    jmp     .Ldr_out
.Ldr_mem:
    lea     rdi, [rip+s_dyn_mem]
    call    log_line
.Ldr_out:
    mov     rdi, [rip+rm_mark]
    call    fa_release
    add     rsp, 40
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# rm_finish - the touched leaves: their live triangles (moved to the end of
#   the pool when they outgrow their room), owners for vertices that lost
#   theirs, vertex lists (own first), boxes; splats redrawn; the longest
#   edge
rm_finish:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 40
    lea     rdi, [rip+frame_arena]      # live triangles per leaf
    mov     esi, [rip+rm_nL]
    lea     esi, [rsi*4+16]
    call    arena_alloc
    test    rax, rax
    jz      .Lrf_out
    mov     r15, rax
    mov     rdi, rax
    mov     ecx, [rip+rm_nL]
    xor     eax, eax
    rep     stosd
    xor     r12d, r12d
1:  cmp     r12d, [rip+rm_nT]
    jae     2f
    mov     edi, r12d
    call    rm_tv
    cmp     dword ptr [rax], DEAD
    je      11f
    mov     rax, [rip+rm_TL]
    mov     eax, [rax+r12*4]
    mov     rdx, [rip+rm_lidx]
    mov     eax, [rdx+rax*4]
    inc     dword ptr [r15+rax*4]
11: inc     r12d
    jmp     1b
2:  mov     dword ptr [rsp+32], 0       # (the most in one leaf)
    xor     ebx, ebx
21: cmp     ebx, [rip+rm_nL]
    jae     3f
    mov     rax, [rip+rm_L]
    mov     eax, [rax+rbx*4]
    imul    eax, eax, ND_SZ
    mov     rbp, [rip+sc_nodes]
    add     rbp, rax
    mov     r12d, [r15+rbx*4]
    cmp     r12d, [rsp+32]
    jbe     22f
    mov     [rsp+32], r12d
22: mov     dword ptr [rbp+ND_TN], 0
    cmp     r12d, [rbp+ND_TCAP]
    jbe     24f
    lea     r13d, [r12+r12+64]          # outgrown: to the end, twice the room
    mov     eax, [rip+sc_tri_used]
    add     eax, r13d
    shl     rax, 2
    cmp     rax, [rip+sc_tri_b]
    jbe     23f
    mov     rdx, [rip+sc_tri_b]
    add     rdx, rdx
    cmp     rdx, rax
    jae     221f
    mov     rdx, rax
221:lea     rdi, [rip+sc_tri]
    lea     rsi, [rip+sc_tri_b]
    call    sgrow
    test    rax, rax
    jz      .Lrf_out
    mov     rax, [rip+rm_L]             # (rbp again: sc_nodes did not move)
    mov     eax, [rax+rbx*4]
    imul    eax, eax, ND_SZ
    mov     rbp, [rip+sc_nodes]
    add     rbp, rax
23: mov     eax, [rip+sc_tri_used]
    mov     [rbp+ND_TOFF], eax
    mov     [rbp+ND_TCAP], r13d
    add     [rip+sc_tri_used], r13d
24: inc     ebx
    jmp     21b
3:  xor     r12d, r12d                  # refill
31: cmp     r12d, [rip+rm_nT]
    jae     4f
    mov     edi, r12d
    call    rm_tv
    cmp     dword ptr [rax], DEAD
    je      32f
    mov     rax, [rip+rm_TL]
    mov     eax, [rax+r12*4]
    imul    eax, eax, ND_SZ
    mov     rbp, [rip+sc_nodes]
    add     rbp, rax
    mov     ecx, [rbp+ND_TOFF]
    add     ecx, [rbp+ND_TN]
    inc     dword ptr [rbp+ND_TN]
    mov     rax, [rip+rm_T]
    mov     eax, [rax+r12*4]
    mov     rdx, [rip+sc_tri]
    mov     [rdx+rcx*4], eax
32: inc     r12d
    jmp     31b
4:  inc     dword ptr [rip+dy_serial]   # owners: a touched leaf's go
    mov     r14d, [rip+dy_serial]
    xor     r12d, r12d
41: cmp     r12d, [rip+rm_nT]
    jae     45f
    mov     edi, r12d
    call    rm_tv
    cmp     dword ptr [rax], DEAD
    je      44f
    xor     ecx, ecx
42: mov     edx, [rax+rcx*4]
    mov     r8, [rip+dy_vst]
    cmp     [r8+rdx*4], r14d
    je      43f
    mov     [r8+rdx*4], r14d
    mov     r8, [rip+sc_vown]
    mov     r9d, [r8+rdx*4]
    cmp     r9d, [rip+sc_nnodes]
    jae     43f                         # (none yet)
    mov     r10, [rip+rm_lidx]
    cmp     dword ptr [r10+r9*4], -1
    je      43f
    mov     dword ptr [r8+rdx*4], -1
43: inc     ecx
    cmp     ecx, 3
    jb      42b
44: inc     r12d
    jmp     41b
45: xor     ebx, ebx                    # ... to the first touched leaf with it
46: cmp     ebx, [rip+rm_nL]
    jae     5f
    mov     rax, [rip+rm_L]
    mov     r13d, [rax+rbx*4]
    imul    eax, r13d, ND_SZ
    mov     rbp, [rip+sc_nodes]
    add     rbp, rax
    mov     ecx, [rbp+ND_TOFF]
    mov     r12d, [rbp+ND_TN]
    add     r12d, ecx
47: cmp     ecx, r12d
    jae     49f
    mov     rax, [rip+sc_tri]
    mov     eax, [rax+rcx*4]
    lea     rax, [rax+rax*2]
    shl     rax, 2
    add     rax, [rip+sv_tris]
    xor     edx, edx
48: mov     r8d, [rax+rdx*4]
    mov     r9, [rip+sc_vown]
    cmp     dword ptr [r9+r8*4], -1
    jne     481f
    mov     [r9+r8*4], r13d
481:inc     edx
    cmp     edx, 3
    jb      48b
    inc     ecx
    jmp     47b
49: inc     ebx
    jmp     46b
5:  lea     rdi, [rip+frame_arena]      # vertex lists: through a buffer
    mov     esi, [rsp+32]
    lea     esi, [rsi+rsi*2]
    lea     esi, [rsi*4+16]
    call    arena_alloc
    test    rax, rax
    jz      .Lrf_out
    mov     r15, rax
    xor     ebx, ebx
51: cmp     ebx, [rip+rm_nL]
    jae     6f
    mov     rax, [rip+rm_L]
    mov     r13d, [rax+rbx*4]
    imul    eax, r13d, ND_SZ
    mov     rbp, [rip+sc_nodes]
    add     rbp, rax
    inc     dword ptr [rip+dy_serial]
    mov     r14d, [rip+dy_serial]
    xor     r12d, r12d                  # in the buffer
    mov     dword ptr [rsp+36], 0       # sub-pass: own, then the rest
52: mov     ecx, [rbp+ND_TOFF]
    mov     eax, [rbp+ND_TN]
    add     eax, ecx
    mov     [rsp+24], eax
53: cmp     ecx, [rsp+24]
    jae     56f
    mov     rax, [rip+sc_tri]
    mov     eax, [rax+rcx*4]
    lea     rax, [rax+rax*2]
    shl     rax, 2
    add     rax, [rip+sv_tris]
    xor     edx, edx
54: mov     r8d, [rax+rdx*4]
    mov     r9, [rip+dy_vst]
    cmp     [r9+r8*4], r14d
    je      55f
    cmp     dword ptr [rsp+36], 0
    jne     541f
    mov     r10, [rip+sc_vown]
    cmp     [r10+r8*4], r13d
    jne     55f
541:mov     [r9+r8*4], r14d
    mov     [r15+r12*4], r8d
    inc     r12d
55: inc     edx
    cmp     edx, 3
    jb      54b
    inc     ecx
    jmp     53b
56: cmp     dword ptr [rsp+36], 0
    jne     57f
    mov     [rbp+ND_VOWN], r12d
    mov     dword ptr [rsp+36], 1
    jmp     52b
57: cmp     r12d, [rbp+ND_VCAP]         # its room (else at the end)
    jbe     59f
    lea     r13d, [r12+r12+64]
    mov     eax, [rip+sc_nvl]
    add     eax, r13d
    shl     rax, 2
    cmp     rax, [rip+sc_vl_b]
    jbe     58f
    mov     rdx, [rip+sc_vl_b]
    add     rdx, rdx
    cmp     rdx, rax
    jae     571f
    mov     rdx, rax
571:lea     rdi, [rip+sc_vl]
    lea     rsi, [rip+sc_vl_b]
    call    sgrow
    test    rax, rax
    jz      .Lrf_out
58: mov     eax, [rip+sc_nvl]
    mov     [rbp+ND_VOFF], eax
    mov     [rbp+ND_VCAP], r13d
    add     [rip+sc_nvl], r13d
59: mov     [rbp+ND_VN], r12d
    mov     edi, [rbp+ND_VOFF]
    shl     rdi, 2
    add     rdi, [rip+sc_vl]
    mov     rsi, r15
    mov     ecx, r12d
    rep     movsd
    mov     rax, [rip+rm_L]
    mov     edi, [rax+rbx*4]
    mov     rax, [rip+sc_lchg]
    mov     byte ptr [rax+rdi], 1
    call    node_box
    inc     ebx
    jmp     51b
6:  xorps   xmm7, xmm7                  # the longest edge, at least
    xor     r12d, r12d
61: cmp     r12d, [rip+rm_nT]
    jae     64f
    mov     edi, r12d
    call    rm_tv
    cmp     dword ptr [rax], DEAD
    je      63f
    mov     r13, rax
    xor     r14d, r14d
62: mov     edi, [r13+r14*4]
    mov     ecx, r14d
    call    rm_next
    mov     esi, [r13+rcx*4]
    call    rm_len2
    maxss   xmm7, xmm0
    inc     r14d
    cmp     r14d, 3
    jb      62b
63: inc     r12d
    jmp     61b
64: sqrtss  xmm7, xmm7
    maxss   xmm7, [rip+sc_maxedge]
    movss   [rip+sc_maxedge], xmm7
.Lrf_out:
    add     rsp, 40
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
