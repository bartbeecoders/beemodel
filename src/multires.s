# =============================================================================
#  BeeModel - multiresolution: sculpted detail kept as displacements over
#  the subdivision levels of a base cage
#
#  A multires modifier (levels L, level k) shows level k of the stack's
#  input subdivided (Catmull-Clark), each level j displaced after it is
#  made:   P_0 = base,  P_j = S(P_j-1) + D_j.
#  The displacements live on the object (OB_MRES): a reference-counted
#  block shared with undo steps like a mesh - a mesh whose positions are
#  D_1, D_2, ... one level after the other, with the base's vertex,
#  polygon and loop counts (a base with another topology: no
#  displacements).
#
#  Sculpting at level k >= 1 works on a copy of P_k; a stroke adds its
#  moves to D_k (in a new block, the undo step keeps the old): the finer
#  levels follow (S is linear; their own D_j stay on top), the coarser
#  keep theirs. At level 0 the base itself is sculpted. Propagate down
#  refits the coarser levels to the finest: every vertex keeps its number
#  through the levels, so P_j takes the finest level's positions of its
#  vertices and D_j becomes what makes that so; the finest stays exact.
#  Applying the modifier keeps the level shown.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

.globl mod_multires
.globl mr_target
.globl mr_owns
.globl mr_stroke_end
.globl mr_drop
.globl mr_find
.globl mr_prune
.globl mr_klev
.globl mres_write
.globl mres_read

.equ MB_COUNT,    4                     # (mods.s: the stack block)
.equ MB_HDR,      16
.equ MOD_SZ,      48
.equ MD_TYPE,     0
.equ MD_FLAGS,    4
.equ MD_P,        8
.equ MT_MULTIRES, 9
.equ ME_VER,      108                   # (mesh header: edits in place)
# a displacement block's base fingerprint (in its mesh header)
.equ DB_V,        ME_NEDGES
.equ DB_P,        ME_NPOLYS
.equ DB_L,        ME_NLOOPS

.section .rodata
s_mr_need:      .asciz "  multires: select a mesh with a multires modifier"
s_mr_mem:       .asciz "  multires: out of memory"
s_mr_down:      .asciz "  multires: coarser levels follow the finest"

.section .bss
.align 8
mr_copy:        .skip 8                 # the sculpted copy of level k, and
mr_kobj:        .skip 8                 #  what it was made from: object,
mr_kbase:       .skip 8                 #  base mesh, its version,
mr_kver:        .skip 4                 #  displacements, level, levels
mr_klev:        .skip 4
mr_kd:          .skip 8
mr_off:         .skip 4                 # level k's displacements: where,
mr_n:           .skip 4                 #  how many, the end of them
mr_end:         .skip 4

.text
OPERATOR op_mr_down, "multires.propagate_down", "Propagate Down", do_mr_down, flags=OPF_AI_SAFE|OPF_UNDO, doc="Multires: the coarser levels take the shape of the finest (which stays exact)"

# mr_find(rdi=object) -> rax = its first enabled modifier when that is a
#   multires one (0: none)
mr_find:
    mov     rax, [rdi+OB_MODS]
    test    rax, rax
    jz      8f
    xor     ecx, ecx
1:  cmp     ecx, [rax+MB_COUNT]
    jae     8f
    imul    edx, ecx, MOD_SZ
    lea     rdx, [rax+MB_HDR+rdx]
    test    dword ptr [rdx+MD_FLAGS], 1
    jnz     2f
    inc     ecx
    jmp     1b
2:  cmp     dword ptr [rdx+MD_TYPE], MT_MULTIRES
    jne     8f
    mov     rax, rdx
    ret
8:  xor     eax, eax
    ret

# mr_levels(rsi=modifier) -> eax = levels L (1..6), edx = level k (0..L)
mr_levels:
    cvttss2si eax, [rsi+MD_P]
    cmp     eax, 1
    jge     1f
    mov     eax, 1
1:  cmp     eax, 6
    jle     2f
    mov     eax, 6
2:  cvttss2si edx, [rsi+MD_P+4]
    test    edx, edx
    jns     3f
    xor     edx, edx
3:  cmp     edx, eax
    jle     4f
    mov     edx, eax
4:  ret

# mr_disp(rdi=object, rsi=base) -> rax = its displacements when they were
#   made on this base's topology (else 0)
mr_disp:
    mov     rax, [rdi+OB_MRES]
    test    rax, rax
    jz      9f
    mov     ecx, [rsi+ME_NVERTS]
    cmp     ecx, [rax+DB_V]
    jne     8f
    mov     ecx, [rsi+ME_NPOLYS]
    cmp     ecx, [rax+DB_P]
    jne     8f
    mov     ecx, [rsi+ME_NLOOPS]
    cmp     ecx, [rax+DB_L]
    je      9f
8:  xor     eax, eax
9:  ret

# mr_prune(rdi=object) - displacements made for another base go
mr_prune:
    push    rbx
    mov     rbx, rdi
    cmp     qword ptr [rbx+OB_MRES], 0
    je      9f
    mov     rsi, [rbx+OB_MESH]
    call    mr_disp
    test    rax, rax
    jnz     9f
    mov     rdi, [rbx+OB_MRES]
    mov     qword ptr [rbx+OB_MRES], 0
    call    mesh_unref
9:  pop     rbx
    ret

# mr_eval(rdi=object, rsi=base, edx=level) -> rax = level k displaced (a
#   new reference), or 0; mr_off / mr_n / mr_end of that level
mr_eval:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13d, edx
    call    mr_disp
    xor     ecx, ecx
    xor     edx, edx
    test    rax, rax
    jz      1f
    mov     rdx, [rax+ME_POS]
    mov     ecx, [rax+ME_NVERTS]
1:  mov     rdi, r12
    mov     esi, r13d
    call    subsurf_mr
    mov     ecx, [rip+ss_off]
    mov     [rip+mr_off], ecx
    mov     edx, [rip+ss_total]
    mov     [rip+mr_end], edx
    sub     edx, ecx
    mov     [rip+mr_n], edx
    pop     r13
    pop     r12
    pop     rbx
    ret

# mod_multires(rdi=mesh, rsi=modifier) -> rax = level k, displaced (0 for
#   level 0: the mesh as it is)
mod_multires:
    sub     rsp, 8
    call    mr_levels
    test    edx, edx
    jz      8f
    mov     rsi, rdi
    mov     rdi, [rip+ev_owner]
    call    mr_eval
    add     rsp, 8
    ret
8:  xor     eax, eax
    add     rsp, 8
    ret

# =============================================================================
#  Sculpting
# =============================================================================
# mr_target(rdi=object) -> rax = the mesh sculpt mode works on: with a
#   multires modifier first at level k >= 1 (and no dyntopo), a copy of
#   level k (kept while object, base, displacements and level stay);
#   otherwise its own mesh
mr_target:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     rbx, rdi
    cmp     dword ptr [rip+sc_dyn], 0
    jne     .Lmt_base
    call    mr_find
    test    rax, rax
    jz      .Lmt_base
    mov     rsi, rax
    call    mr_levels
    test    edx, edx
    jz      .Lmt_base
    mov     r12d, edx
    mov     r13, [rbx+OB_MESH]
    cmp     qword ptr [rip+mr_copy], 0  # the same as made last time?
    je      1f
    cmp     [rip+mr_kobj], rbx
    jne     1f
    cmp     [rip+mr_kbase], r13
    jne     1f
    mov     eax, [r13+ME_VER]
    cmp     [rip+mr_kver], eax
    jne     1f
    cmp     [rip+mr_klev], r12d
    jne     1f
    mov     rax, [rbx+OB_MRES]
    cmp     [rip+mr_kd], rax
    jne     1f
    mov     rax, [rip+mr_copy]
    jmp     9f
1:  call    mr_drop
    mov     rdi, rbx
    mov     rsi, r13
    mov     edx, r12d
    call    mr_eval
    test    rax, rax
    jz      .Lmt_base
    mov     r14, rax
    mov     rdi, rax
    call    mesh_copy
    mov     rdi, r14
    mov     r14, rax
    call    mesh_unref
    mov     rax, r14
    test    rax, rax
    jz      .Lmt_base
    mov     [rip+mr_copy], rax
    mov     [rip+mr_kobj], rbx
    mov     [rip+mr_kbase], r13
    mov     ecx, [r13+ME_VER]
    mov     [rip+mr_kver], ecx
    mov     [rip+mr_klev], r12d
    mov     rcx, [rbx+OB_MRES]
    mov     [rip+mr_kd], rcx
    jmp     9f
.Lmt_base:
    mov     rax, [rbx+OB_MESH]
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# mr_owns(rdi=mesh) -> eax = 1 when it is the multires copy
mr_owns:
    xor     eax, eax
    test    rdi, rdi
    jz      1f
    cmp     rdi, [rip+mr_copy]
    sete    al
1:  ret

mr_drop:
    mov     rdi, [rip+mr_copy]
    mov     qword ptr [rip+mr_copy], 0
    jmp     mesh_unref

# mr_stroke_end - a stroke on the copy: its moves (old positions in the
#   stroke's deltas, new ones in the copy) added to level k's displacements,
#   in a new block the object takes
mr_stroke_end:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rbx, [rip+mr_kobj]
    mov     r12, [rbx+OB_MESH]
    mov     rdi, rbx                    # the block: at least up to level k
    mov     rsi, r12
    call    mr_disp
    mov     r13, rax
    mov     r14d, [rip+mr_end]
    test    r13, r13
    jz      1f
    cmp     r14d, [r13+ME_NVERTS]
    jae     1f
    mov     r14d, [r13+ME_NVERTS]
1:  mov     edi, r14d
    xor     esi, esi
    xor     edx, edx
    call    mesh_new
    test    rax, rax
    jz      .Lms_mem
    mov     r15, rax
    mov     [r15+ME_NVERTS], r14d
    mov     eax, [r12+ME_NVERTS]
    mov     [r15+DB_V], eax
    mov     eax, [r12+ME_NPOLYS]
    mov     [r15+DB_P], eax
    mov     eax, [r12+ME_NLOOPS]
    mov     [r15+DB_L], eax
    test    r13, r13                    # the old ones (the rest: zero)
    jz      2f
    mov     rdi, [r15+ME_POS]
    mov     rsi, [r13+ME_POS]
    mov     ecx, [r13+ME_NVERTS]
    imul    rcx, rcx, 12
    rep     movsb
2:  mov     r8, [r15+ME_POS]            # + the moves, at level k
    mov     eax, [rip+mr_off]
    lea     rax, [rax+rax*2]
    lea     r8, [r8+rax*4]
    mov     r9, [rip+sv_pos]
    xor     ecx, ecx
3:  cmp     ecx, [rip+sc_d_n]
    jae     4f
    cmp     ecx, [rip+sc_d_cap]
    jae     4f
    mov     rax, [rip+sc_d_idx]
    mov     eax, [rax+rcx*4]
    cmp     eax, [rip+mr_n]
    jae     31f
    lea     rdx, [rcx+rcx*2]
    shl     rdx, 2
    add     rdx, [rip+sc_d_old]
    lea     rax, [rax+rax*2]
    xor     r10d, r10d
32: movss   xmm0, [r9+rax*4]
    subss   xmm0, [rdx+r10*4]
    addss   xmm0, [r8+rax*4]
    movss   [r8+rax*4], xmm0
    inc     rax
    inc     r10d
    cmp     r10d, 3
    jb      32b
31: inc     ecx
    jmp     3b
4:  mov     rdi, [rbx+OB_MRES]          # the object takes it
    mov     [rbx+OB_MRES], r15
    call    mesh_unref
    mov     [rip+mr_kd], r15            # (the copy is that, as sculpted)
    jmp     9f
.Lms_mem:
    lea     rdi, [rip+s_mr_mem]
    call    log_line
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Propagate down
# =============================================================================
do_mr_down:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    call    active_mesh_obj
    test    rax, rax
    jz      .Lmd_need
    mov     rbx, rax
    mov     rdi, rbx
    call    mr_find
    test    rax, rax
    jz      .Lmd_need
    mov     rsi, rax
    call    mr_levels
    mov     r12d, eax                   # L
    mov     r13, [rbx+OB_MESH]
    mov     rdi, rbx                    # the finest level as it is
    mov     rsi, r13
    mov     edx, r12d
    call    mr_eval
    test    rax, rax
    jz      .Lmd_mem
    mov     r14, rax
    mov     edi, [rip+mr_end]           # a new block for all levels
    xor     esi, esi
    xor     edx, edx
    call    mesh_new
    test    rax, rax
    jz      .Lmd_mem2
    mov     r15, rax
    mov     eax, [rip+mr_end]
    mov     [r15+ME_NVERTS], eax
    mov     eax, [r13+ME_NVERTS]
    mov     [r15+DB_V], eax
    mov     eax, [r13+ME_NPOLYS]
    mov     [r15+DB_P], eax
    mov     eax, [r13+ME_NLOOPS]
    mov     [r15+DB_L], eax
    mov     edi, [r14+ME_NVERTS]        # its positions: the targets
    imul    rdi, rdi, 12
    push    rdi                         # (their size)
    call    smap
    test    rax, rax
    jz      .Lmd_mem4
    push    rax
    mov     rdi, rax
    mov     rsi, [r14+ME_POS]
    mov     ecx, [r14+ME_NVERTS]
    imul    rcx, rcx, 12
    rep     movsb
    mov     rdi, r14
    call    mesh_unref
    mov     rdi, r13                    # fit, level by level
    mov     esi, r12d
    mov     rdx, [r15+ME_POS]
    mov     rcx, [rsp]
    call    subsurf_fit
    mov     rdi, rax
    call    mesh_unref
    pop     rdi                         # (the targets go)
    pop     rsi
    add     rsi, 4095
    and     rsi, -4096
    call    plat_munmap
    mov     rdi, [rbx+OB_MRES]
    mov     [rbx+OB_MRES], r15
    call    mesh_unref
    lea     rdi, [rip+s_mr_down]
    call    log_line
    mov     dword ptr [rip+dirty], 1
    jmp     9f
.Lmd_mem4:
    pop     rdi
.Lmd_mem3:
    mov     rdi, r15
    call    mesh_unref
.Lmd_mem2:
    mov     rdi, r14
    call    mesh_unref
.Lmd_mem:
    lea     rdi, [rip+s_mr_mem]
    call    log_line
    call    undo_drop_last
    jmp     9f
.Lmd_need:
    lea     rdi, [rip+s_mr_need]
    call    log_line
    call    undo_drop_last
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Files: MRES - per object with displacements: index, count, the base's
#  vertices / polygons / loops, then the floats
# =============================================================================
mres_write:
    push    rbx
    push    r12
    sub     rsp, 8
    xor     ebx, ebx
1:  cmp     ebx, [rip+obj_count]
    jae     9f
    mov     edi, ebx
    call    obj_at
    mov     r12, [rax+OB_MRES]
    test    r12, r12
    jz      2f
    mov     edi, ebx
    call    wb_u32
    mov     edi, [r12+ME_NVERTS]
    call    wb_u32
    mov     edi, [r12+DB_V]
    call    wb_u32
    mov     edi, [r12+DB_P]
    call    wb_u32
    mov     edi, [r12+DB_L]
    call    wb_u32
    mov     rsi, [r12+ME_POS]
    imul    edx, [r12+ME_NVERTS], 12
    call    wb_bytes
2:  inc     ebx
    jmp     1b
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# mres_read(rdi=data, esi=bytes) - the blocks back on their objects
mres_read:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r12, rdi
    mov     r13d, esi
1:  cmp     r13d, 20
    jb      9f
    mov     r14d, [r12+4]               # count
    mov     eax, r14d
    cmp     eax, 0x8000000
    jae     9f
    imul    eax, eax, 12
    add     eax, 20
    cmp     eax, r13d
    ja      9f
    mov     edi, [r12]
    cmp     edi, [rip+obj_count]
    jae     8f
    call    obj_at
    mov     rbx, rax
    mov     edi, r14d
    xor     esi, esi
    xor     edx, edx
    call    mesh_new
    test    rax, rax
    jz      9f
    mov     r15, rax
    mov     [r15+ME_NVERTS], r14d
    mov     eax, [r12+8]
    mov     [r15+DB_V], eax
    mov     eax, [r12+12]
    mov     [r15+DB_P], eax
    mov     eax, [r12+16]
    mov     [r15+DB_L], eax
    mov     rdi, [r15+ME_POS]
    lea     rsi, [r12+20]
    imul    ecx, r14d, 12
    rep     movsb
    mov     rdi, [rbx+OB_MRES]
    mov     [rbx+OB_MRES], r15
    call    mesh_unref
8:  imul    eax, r14d, 12
    add     eax, 20
    add     r12, rax
    sub     r13d, eax
    jmp     1b
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
