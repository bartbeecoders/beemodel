# =============================================================================
#  BeeModel - mesh editing operators (edit mode): extrude, inset, delete,
#  merge, dissolve, fill, subdivide, duplicate, flip / recalculate normals.
#
#  Every topology change builds a new mesh from the old one and swaps it in;
#  the operator's undo step still references the old mesh, so undo is free.
#  New meshes are compacted (unused vertices dropped, exact capacities).
#
#  Interactive use (keys, menus, console) ends in a modal: extrude moves the
#  new geometry along the normal, inset / individual extrude drag a value.
#  Scripts and agents get the result at once: the operator argument is the
#  distance (default 1 m extrude, 0.1 m inset).
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

# exports
.globl items_mesh
.globl edit_replace
.globl fa
.globl fa_fill
.globl eh_new
.globl eh_slot
.globl ukey
.globl dkey
.globl edge_faces
.globl ef_find
.globl ef_f1
.globl ef_f2
.globl ef_cnt
.globl ef_n
.globl copy_verts
.globl copy_vert
.globl add_vert_at
.globl clear_vsel
.globl poly_copy
.globl mo_commit
.globl mo_fail
.globl normalize
.globl poly_normal
.globl nrm
.globl sel_polys
.globl scr
.globl interactive
.globl arg_value
.globl recalc_all
.globl world_dir
.globl poly_center

.equ KEY_I,     23
.equ KEY_M,     50
.equ KEY_H,     35
.equ SCR_MAX,   65536               # scratch polygon (vertex indices)

.section .bss
.align 8
mo_src:         .skip 8             # modal source mesh (one reference held)
scr:            .skip SCR_MAX*4
mo_kind:        .skip 4
nrm:            .skip 16
tmpv:           .skip 48

.section .rodata
.align 4
mf_one:         .float 1.0
mf_half:        .float 0.5
mf_tenth:       .float 0.1
mf_eps:         .float 1.0e-12
mf_tiny:        .float 1.0e-4
mf_dist0:       .float 0.0001
mf_min_dot:     .float 0.2
s_lbl_ext:      .asciz "Extrude"
s_lbl_inset:    .asciz "Inset"
s_f_nothing:    .asciz "  nothing selected"
s_f_extrude:    .asciz "  extrude: select faces or edges"
s_f_faces:      .asciz "  select faces first (3 = face mode)"
s_f_merge:      .asciz "  merge: select two or more vertices"
s_f_dissolve:   .asciz "  nothing to dissolve (needs neighbouring faces)"
s_f_fill:       .asciz "  fill: select three or more vertices"
s_merged:       .asciz "  vertices removed: "
.align 8
items_mesh:     .quad op_m_extrude, op_m_extrude_ind, op_m_inset, 0
                .quad op_m_subdivide, op_m_fill, op_m_dissolve, 0
                .quad op_m_merge_c, op_m_merge_col, op_m_merge_d, 0
                .quad op_m_del_v, op_m_del_e, op_m_del_f, 0
                .quad op_m_dup, op_m_flip, op_m_recalc

OPERATOR op_m_extrude, "mesh.extrude", "Extrude", do_extrude, key=KEY_E, flags=OPF_AI_SAFE|OPF_UNDO|OPF_EDIT, doc="Extrude the selected faces (or edges) and move them along the normal: mesh.extrude [distance]", params=p_extrude
OPERATOR op_m_extrude_ind, "mesh.extrude_individual", "Extrude Individual Faces", do_extrude_ind, key=KEY_E|KM_ALT, flags=OPF_AI_SAFE|OPF_UNDO|OPF_EDIT, doc="Extrude every selected face along its own normal: mesh.extrude_individual [distance]", params=p_extrude_ind
OPERATOR op_m_inset, "mesh.inset", "Inset Faces", do_inset, key=KEY_I, flags=OPF_AI_SAFE|OPF_UNDO|OPF_EDIT, doc="Inset every selected face: mesh.inset [thickness]", params=p_inset
OPERATOR op_m_subdivide, "mesh.subdivide", "Subdivide", do_subdivide, flags=OPF_AI_SAFE|OPF_UNDO|OPF_EDIT, doc="Split the selected faces (quads into four)"
OPERATOR op_m_fill, "mesh.fill", "Fill / Make Face", do_fill, key=KEY_F, flags=OPF_AI_SAFE|OPF_UNDO|OPF_EDIT, doc="Make a face from the selected vertices (fills holes)"
OPERATOR op_m_dissolve, "mesh.dissolve", "Dissolve", do_dissolve, key=KEY_X|KM_CTRL, flags=OPF_AI_SAFE|OPF_UNDO|OPF_EDIT, doc="Dissolve the selection by select mode: merge the faces around it into n-gons"
OPERATOR op_m_merge_c, "mesh.merge_center", "Merge at Center", do_merge_c, key=KEY_M, flags=OPF_AI_SAFE|OPF_UNDO|OPF_EDIT, doc="Merge all selected vertices into one at their centre"
OPERATOR op_m_merge_col, "mesh.merge_collapse", "Merge Collapse", do_merge_col, flags=OPF_AI_SAFE|OPF_UNDO|OPF_EDIT, doc="Merge each connected group of selected vertices at its centre"
OPERATOR op_m_merge_d, "mesh.merge_distance", "Merge by Distance", do_merge_d, flags=OPF_AI_SAFE|OPF_UNDO|OPF_EDIT, doc="Merge selected vertices closer than a distance: mesh.merge_distance [0.0001]", params=p_merge_d
OPERATOR op_m_del, "mesh.delete", "Delete", do_delete, key=KEY_X, flags=OPF_AI_SAFE|OPF_UNDO|OPF_EDIT|OPF_HIDDEN, doc="Delete by select mode: vertices, edges or faces"
OPERATOR op_m_del_key, "mesh.delete_key", "Delete", do_delete, key=KEY_DELETE, flags=OPF_UNDO|OPF_EDIT|OPF_HIDDEN, doc="Delete by select mode (Delete key)"
OPERATOR op_m_del_v, "mesh.delete_vertices", "Delete Vertices", do_del_v, flags=OPF_AI_SAFE|OPF_UNDO|OPF_EDIT, doc="Delete the selected vertices and their faces"
OPERATOR op_m_del_e, "mesh.delete_edges", "Delete Edges", do_del_e, flags=OPF_AI_SAFE|OPF_UNDO|OPF_EDIT, doc="Delete the faces around the selected edges"
OPERATOR op_m_del_f, "mesh.delete_faces", "Delete Faces", do_del_f, flags=OPF_AI_SAFE|OPF_UNDO|OPF_EDIT, doc="Delete the selected faces"
OPERATOR op_m_dup, "mesh.duplicate", "Duplicate", do_duplicate, key=KEY_D|KM_SHIFT, flags=OPF_AI_SAFE|OPF_UNDO|OPF_EDIT, doc="Duplicate the selected faces and move the copy"
OPERATOR op_m_flip, "mesh.flip_normals", "Flip Normals", do_flip, flags=OPF_AI_SAFE|OPF_UNDO|OPF_EDIT, doc="Reverse the selected faces"
OPERATOR op_m_recalc, "mesh.recalc_normals", "Recalculate Normals", do_recalc, key=KEY_N|KM_SHIFT, flags=OPF_AI_SAFE|OPF_UNDO|OPF_EDIT, doc="Make the faces consistent and point them outside (selected, or all)"

.text

# =============================================================================
#  Helpers
# =============================================================================
# fa(edi=bytes) -> rax = zeroed frame-arena memory (0 on failure)
fa:
    push    rbx
    mov     ebx, edi
    add     ebx, 16
    lea     rdi, [rip+frame_arena]
    mov     esi, ebx
    call    arena_alloc
    test    rax, rax
    jz      9f
    mov     rdx, rax
    mov     rdi, rax
    mov     ecx, ebx
    xor     eax, eax
    rep     stosb
    mov     rax, rdx
9:  pop     rbx
    ret

# fa_fill(edi=count u32, esi=value) -> rax
fa_fill:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     ebx, edi
    mov     r12d, esi
    lea     edi, [rbx*4]
    call    fa
    test    rax, rax
    jz      9f
    mov     rdi, rax
    mov     ecx, ebx
    mov     edx, eax
    mov     eax, r12d
    mov     rdx, rdi
    rep     stosd
    mov     rax, rdx
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# mo_fail(rdi=message) - log, forget the operator's undo step
mo_fail:
    sub     rsp, 8
    call    log_line
    call    undo_drop_last
    add     rsp, 8
    ret

# edit_replace(rdi=mesh) - it becomes the edit object's mesh
edit_replace:
    push    rbx
    mov     rbx, rdi
    call    edit_get
    test    rax, rax
    jz      1f
    mov     rdi, [rax+OB_MESH]
    mov     [rax+OB_MESH], rbx
    call    mesh_unref
    jmp     2f
1:  mov     rdi, rbx                    # (no edit object: drop it)
    call    mesh_unref
2:  mov     dword ptr [rip+dirty], 1
    pop     rbx
    ret

# mo_commit(rdi=built mesh) - finish, compact, swap in
mo_commit:
    push    rbx
    mov     rbx, rdi
    call    mesh_finish
    mov     rdi, rbx
    call    mesh_compact
    mov     rdi, rax
    call    edit_replace
    pop     rbx
    ret

# mesh_compact(rdi=mesh) -> rax = exact-size copy without unused vertices
#   (the input, used by nothing else, is freed)
mesh_compact:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rbx, rdi
    mov     edi, [rbx+ME_NVERTS]
    call    fa
    test    rax, rax
    jz      .Lmc_keep
    mov     r12, rax                    # used flags
    mov     rsi, [rbx+ME_LOOPS]
    mov     ecx, [rbx+ME_NLOOPS]
1:  test    ecx, ecx
    jz      2f
    dec     ecx
    mov     eax, [rsi+rcx*4]
    mov     byte ptr [r12+rax], 1
    jmp     1b
2:  xor     r13d, r13d                  # used count
    xor     ecx, ecx
3:  cmp     ecx, [rbx+ME_NVERTS]
    jae     4f
    movzx   eax, byte ptr [r12+rcx]
    add     r13d, eax
    inc     ecx
    jmp     3b
4:  mov     edi, r13d
    mov     esi, [rbx+ME_NLOOPS]
    mov     edx, [rbx+ME_NPOLYS]
    call    mesh_new
    test    rax, rax
    jz      .Lmc_keep
    mov     r14, rax
    mov     edi, [rbx+ME_NVERTS]
    mov     esi, -1
    call    fa_fill
    test    rax, rax
    jz      .Lmc_keep2
    mov     r15, rax                    # remap
    xor     r13d, r13d
5:  cmp     r13d, [rbx+ME_NVERTS]
    jae     6f
    cmp     byte ptr [r12+r13], 0
    je      51f
    mov     rdi, r14
    mov     rsi, rbx
    mov     edx, r13d
    call    copy_vert
    mov     [r15+r13*4], eax
51: inc     r13d
    jmp     5b
6:  xor     r13d, r13d                  # polygons, remapped
7:  cmp     r13d, [rbx+ME_NPOLYS]
    jae     8f
    mov     rsi, [rbx+ME_POFF]
    mov     ecx, [rsi+r13*4]
    mov     edx, [rsi+r13*4+4]
    mov     rsi, [rbx+ME_LOOPS]
    lea     r8, [rip+scr]
    xor     r9d, r9d
71: cmp     ecx, edx
    jae     72f
    mov     eax, [rsi+rcx*4]
    mov     eax, [r15+rax*4]
    mov     [r8+r9*4], eax
    inc     r9d
    inc     ecx
    jmp     71b
72: mov     rdi, r14
    mov     rsi, r8
    mov     edx, r9d
    call    mesh_add_poly
    inc     r13d
    jmp     7b
8:  mov     rdi, r14
    call    mesh_finish
    mov     rdi, rbx
    call    mesh_unref
    mov     rax, r14
    jmp     9f
.Lmc_keep2:
    mov     rdi, r14
    call    mesh_unref
.Lmc_keep:
    mov     rax, rbx
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# copy_vert(rdi=dst, rsi=src, edx=index) -> eax = new index (position +
#   selection)
copy_vert:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13d, edx
    mov     rax, [r12+ME_POS]
    lea     rcx, [r13+r13*2]
    movss   xmm0, [rax+rcx*4]
    movss   xmm1, [rax+rcx*4+4]
    movss   xmm2, [rax+rcx*4+8]
    call    mesh_add_vert
    mov     rcx, [r12+ME_VSEL]
    mov     dl, [rcx+r13]
    mov     rcx, [rbx+ME_VSEL]
    mov     [rcx+rax], dl
    pop     r13
    pop     r12
    pop     rbx
    ret

# copy_verts(rdi=dst, rsi=src) - all vertices, same indices
copy_verts:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12, rsi
    xor     r13d, r13d
1:  cmp     r13d, [r12+ME_NVERTS]
    jae     2f
    mov     rdi, rbx
    mov     rsi, r12
    mov     edx, r13d
    call    copy_vert
    inc     r13d
    jmp     1b
2:  pop     r13
    pop     r12
    pop     rbx
    ret

# add_vert_at(rdi=dst, rsi=float[3], edx=selected) -> eax
add_vert_at:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    mov     r12d, edx
    movss   xmm0, [rsi]
    movss   xmm1, [rsi+4]
    movss   xmm2, [rsi+8]
    call    mesh_add_vert
    mov     rcx, [rbx+ME_VSEL]
    mov     [rcx+rax], r12b
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# clear_vsel(rdi=mesh)
clear_vsel:
    mov     ecx, [rdi+ME_NVERTS]
    mov     rdi, [rdi+ME_VSEL]
    xor     eax, eax
    rep     stosb
    ret

# poly_copy(rdi=dst, rsi=src, edx=polygon, rcx=remap u32[] or 0, r8d=reverse)
poly_copy:
    push    rbx
    mov     r9, [rsi+ME_POFF]
    mov     r10d, [r9+rdx*4]
    mov     r11d, [r9+rdx*4+4]
    mov     r9, [rsi+ME_LOOPS]
    lea     rsi, [rip+scr]
    xor     ebx, ebx
1:  cmp     r10d, r11d
    jae     2f
    mov     eax, [r9+r10*4]
    test    rcx, rcx
    jz      11f
    mov     eax, [rcx+rax*4]
11: mov     [rsi+rbx*4], eax
    inc     ebx
    inc     r10d
    jmp     1b
2:  test    r8d, r8d                    # reversed order
    jz      4f
    xor     ecx, ecx
    lea     edx, [rbx-1]
3:  cmp     ecx, edx
    jge     4f
    mov     eax, [rsi+rcx*4]
    mov     r9d, [rsi+rdx*4]
    mov     [rsi+rcx*4], r9d
    mov     [rsi+rdx*4], eax
    inc     ecx
    dec     edx
    jmp     3b
4:  mov     edx, ebx
    call    mesh_add_poly
    pop     rbx
    ret

# poly_normal(rdi=mesh, esi=polygon) -> nrm[0..2] (Newell, area-weighted)
poly_normal:
    mov     r8, [rdi+ME_POFF]
    mov     ecx, [r8+rsi*4]
    mov     edx, [r8+rsi*4+4]
    mov     r9, [rdi+ME_LOOPS]
    mov     r10, [rdi+ME_POS]
    xorps   xmm0, xmm0
    xorps   xmm1, xmm1
    xorps   xmm2, xmm2
    mov     r11d, ecx                   # first loop (for wrapping)
1:  cmp     ecx, edx
    jae     2f
    mov     eax, [r9+rcx*4]             # current
    lea     esi, [rcx+1]
    cmp     esi, edx
    jb      11f
    mov     esi, r11d
11: mov     esi, [r9+rsi*4]             # next
    lea     rax, [rax+rax*2]
    lea     rax, [r10+rax*4]
    lea     rsi, [rsi+rsi*2]
    lea     rsi, [r10+rsi*4]
    movss   xmm3, [rax+4]               # x += (yc - yn) (zc + zn)
    subss   xmm3, [rsi+4]
    movss   xmm4, [rax+8]
    addss   xmm4, [rsi+8]
    mulss   xmm3, xmm4
    addss   xmm0, xmm3
    movss   xmm3, [rax+8]               # y += (zc - zn) (xc + xn)
    subss   xmm3, [rsi+8]
    movss   xmm4, [rax]
    addss   xmm4, [rsi]
    mulss   xmm3, xmm4
    addss   xmm1, xmm3
    movss   xmm3, [rax]                 # z += (xc - xn) (yc + yn)
    subss   xmm3, [rsi]
    movss   xmm4, [rax+4]
    addss   xmm4, [rsi+4]
    mulss   xmm3, xmm4
    addss   xmm2, xmm3
    inc     ecx
    jmp     1b
2:  movss   [rip+nrm], xmm0
    movss   [rip+nrm+4], xmm1
    movss   [rip+nrm+8], xmm2
    ret

# normalize(rdi=float[3]) - unit length (unchanged if ~0)
normalize:
    movss   xmm0, [rdi]
    mulss   xmm0, xmm0
    movss   xmm1, [rdi+4]
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    movss   xmm1, [rdi+8]
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    comiss  xmm0, [rip+mf_eps]
    jbe     1f
    sqrtss  xmm0, xmm0
    movss   xmm1, [rip+mf_one]
    divss   xmm1, xmm0
    movss   xmm0, [rdi]
    mulss   xmm0, xmm1
    movss   [rdi], xmm0
    movss   xmm0, [rdi+4]
    mulss   xmm0, xmm1
    movss   [rdi+4], xmm0
    movss   xmm0, [rdi+8]
    mulss   xmm0, xmm1
    movss   [rdi+8], xmm0
1:  ret

# world_dir(rdi=float[3] local direction) - into world space (unit)
world_dir:
    push    rbx
    sub     rsp, 64
    mov     rbx, rdi
    call    edit_get
    test    rax, rax
    jz      9f
    mov     rdi, rax
    lea     rsi, [rsp]
    call    obj_matrix
    xor     ecx, ecx
1:  imul    rdx, rcx, 16
    movss   xmm0, [rsp+rdx]
    mulss   xmm0, [rbx]
    movss   xmm1, [rsp+rdx+4]
    mulss   xmm1, [rbx+4]
    addss   xmm0, xmm1
    movss   xmm1, [rsp+rdx+8]
    mulss   xmm1, [rbx+8]
    addss   xmm0, xmm1
    movss   [rsp+48+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      1b
    mov     rax, [rsp+48]
    mov     [rbx], rax
    mov     eax, [rsp+56]
    mov     [rbx+8], eax
    mov     rdi, rbx
    call    normalize
9:  add     rsp, 64
    pop     rbx
    ret

# interactive -> eax = 1 when a person runs the operator (not a script or
#   an agent): then it may continue as a modal tool
interactive:
    xor     eax, eax
    cmp     dword ptr [rip+op_quiet], 0
    sete    al
    ret

# arg_value(xmm0=default) -> xmm0 = the operator argument as a number, or the
#   default
arg_value:
    push    rbx
    sub     rsp, 16
    movss   [rsp], xmm0
    mov     rsi, [rip+op_arg]
    test    rsi, rsi
    jz      9f
    call    skip_space
    cmp     byte ptr [rsi], 0
    je      9f
    lea     rdx, [rsi+64]
    call    parse_float
    movss   [rsp], xmm0
9:  movss   xmm0, [rsp]
    add     rsp, 16
    pop     rbx
    ret

# move_selected(rdi=world direction unit, xmm0=distance) - offsets the
#   selected vertices of the edit mesh in world space
move_selected:
    push    rbx
    sub     rsp, 48
    mov     rbx, rdi
    movss   [rsp+32], xmm0
    lea     rdi, [rsp+16]               # pivot (unused)
    call    edit_tm_snapshot
    test    eax, eax
    jz      9f
    xor     ecx, ecx
1:  movss   xmm0, [rbx+rcx*4]
    mulss   xmm0, [rsp+32]
    movss   [rsp+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      1b
    lea     rdi, [rsp]
    call    edit_tm_grab
    call    edit_tm_end
9:  add     rsp, 48
    pop     rbx
    ret

# ---- edge hash: undirected or directed u64 keys -> u32 values --------------------
# eh_new(edi=expected) -> rax = table: [0] mask, [8] keys u64[n], vals u32[n]
eh_new:
    push    rbx
    lea     eax, [rdi+rdi]
    mov     ebx, 16
1:  cmp     ebx, eax
    jae     2f
    add     ebx, ebx
    jmp     1b
2:  imul    edi, ebx, 12
    add     edi, 8
    call    fa
    test    rax, rax
    jz      9f
    lea     ecx, [rbx-1]
    mov     [rax], rcx
9:  pop     rbx
    ret

# eh_slot(rdi=table, rsi=key) -> rax = &value (u32), edx = 1 if it existed;
#   a new key gets value -1
eh_slot:
    inc     rsi                         # 0 marks an empty slot
    mov     r8, [rdi]                   # mask
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
2:  mov     [rdi+8+rax*8], rsi
    lea     rcx, [r8+1]
    lea     rcx, [rdi+8+rcx*8]
    lea     rax, [rcx+rax*4]
    mov     dword ptr [rax], -1
    xor     edx, edx
    ret
3:  lea     rcx, [r8+1]
    lea     rcx, [rdi+8+rcx*8]
    lea     rax, [rcx+rax*4]
    mov     edx, 1
    ret

# ukey(edi=a, esi=b) -> rax = undirected key ; dkey -> directed
ukey:
    cmp     edi, esi
    jbe     dkey
    xchg    edi, esi
dkey:
    mov     eax, edi
    shl     rax, 32
    mov     ecx, esi
    or      rax, rcx
    ret

# ---- edge -> face adjacency ---------------------------------------------------------
# edge_faces(rbx=mesh) -> eax = 1 ok; ef_tab (hash) maps an undirected edge
#   to a slot s with ef_f1[s], ef_f2[s] (-1 = none), ef_cnt[s]
edge_faces:
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    mov     edi, [rbx+ME_NLOOPS]
    call    eh_new
    test    rax, rax
    jz      .Lef_fail
    mov     [rip+ef_tab], rax
    mov     edi, [rbx+ME_NLOOPS]
    mov     esi, -1
    call    fa_fill
    test    rax, rax
    jz      .Lef_fail
    mov     [rip+ef_f1], rax
    mov     edi, [rbx+ME_NLOOPS]
    mov     esi, -1
    call    fa_fill
    test    rax, rax
    jz      .Lef_fail
    mov     [rip+ef_f2], rax
    mov     edi, [rbx+ME_NLOOPS]
    shl     edi, 2
    call    fa
    test    rax, rax
    jz      .Lef_fail
    mov     [rip+ef_cnt], rax
    mov     dword ptr [rip+ef_n], 0
    xor     r12d, r12d                  # polygon
1:  cmp     r12d, [rbx+ME_NPOLYS]
    jae     .Lef_ok
    mov     rsi, [rbx+ME_POFF]
    mov     r13d, [rsi+r12*4]
    mov     r14d, [rsi+r12*4+4]
    mov     r15d, r13d
2:  cmp     r15d, r14d
    jae     5f
    mov     rsi, [rbx+ME_LOOPS]
    mov     edi, [rsi+r15*4]
    lea     eax, [r15+1]
    cmp     eax, r14d
    jb      3f
    mov     eax, r13d
3:  mov     esi, [rsi+rax*4]
    call    ukey
    mov     rsi, rax
    mov     rdi, [rip+ef_tab]
    call    eh_slot
    test    edx, edx
    jnz     4f
    mov     ecx, [rip+ef_n]             # new edge: next slot index
    mov     [rax], ecx
    inc     dword ptr [rip+ef_n]
4:  mov     ecx, [rax]
    mov     rdx, [rip+ef_cnt]
    inc     dword ptr [rdx+rcx*4]
    mov     rdx, [rip+ef_f1]
    cmp     dword ptr [rdx+rcx*4], -1
    jne     41f
    mov     [rdx+rcx*4], r12d
    jmp     42f
41: mov     rdx, [rip+ef_f2]
    cmp     dword ptr [rdx+rcx*4], -1
    jne     42f
    mov     [rdx+rcx*4], r12d
42: inc     r15d
    jmp     2b
5:  inc     r12d
    jmp     1b
.Lef_ok:
    mov     eax, 1
    jmp     9f
.Lef_fail:
    xor     eax, eax
9:  add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    ret

# ef_find(edi=a, esi=b) -> eax = edge slot (or -1)
ef_find:
    call    ukey
    mov     rsi, rax
    inc     rsi
    mov     rdi, [rip+ef_tab]
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

.section .bss
.align 8
ef_tab:         .skip 8
ef_f1:          .skip 8
ef_f2:          .skip 8
ef_cnt:         .skip 8
ef_n:           .skip 4
.text

# sel_polys(rbx=mesh) -> rax = bytes (polygon fully selected), ecx = count
sel_polys:
    push    r12
    mov     edi, [rbx+ME_NPOLYS]
    call    fa
    test    rax, rax
    jz      9f
    mov     r12, rax
    mov     rdi, rbx
    mov     rsi, rax
    call    poly_sel
    xor     ecx, ecx
    xor     edx, edx
1:  cmp     edx, [rbx+ME_NPOLYS]
    jae     2f
    movzx   eax, byte ptr [r12+rdx]
    add     ecx, eax
    inc     edx
    jmp     1b
2:  mov     rax, r12
9:  pop     r12
    ret

# =============================================================================
#  Delete
# =============================================================================
do_delete:
    mov     edi, [rip+sel_mode]
    jmp     delete_kind
do_del_v:
    xor     edi, edi
    jmp     delete_kind
do_del_e:
    mov     edi, 1
    jmp     delete_kind
do_del_f:
    mov     edi, 2

# delete_kind(edi=0 vertices / 1 edges / 2 faces)
delete_kind:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r15d, edi
    call    need_edit
    test    rax, rax
    jz      .Ldk_drop
    mov     rbx, rax
    mov     edi, [rbx+ME_NPOLYS]
    call    fa
    test    rax, rax
    jz      .Ldk_drop
    mov     r12, rax                    # keep flags
    xor     r14d, r14d                  # removed
    xor     r13d, r13d
1:  cmp     r13d, [rbx+ME_NPOLYS]
    jae     5f
    mov     rsi, [rbx+ME_POFF]
    mov     ecx, [rsi+r13*4]
    mov     edx, [rsi+r13*4+4]
    mov     r8d, ecx                    # first
    mov     rsi, [rbx+ME_LOOPS]
    mov     r9, [rbx+ME_VSEL]
    xor     r10d, r10d                  # any selected / any edge selected
    mov     r11d, 1                     # all selected
2:  cmp     ecx, edx
    jae     3f
    mov     eax, [rsi+rcx*4]
    movzx   eax, byte ptr [r9+rax]
    or      r10d, eax
    and     r11d, eax
    cmp     r15d, 1                     # edges: this one and the next
    jne     21f
    test    eax, eax
    jz      21f
    lea     eax, [rcx+1]
    cmp     eax, edx
    jb      22f
    mov     eax, r8d
22: mov     eax, [rsi+rax*4]
    cmp     byte ptr [r9+rax], 0
    je      21f
    or      r10d, 2
21: inc     ecx
    jmp     2b
3:  xor     eax, eax                    # remove?
    cmp     r15d, 0
    jne     31f
    mov     eax, r10d
    and     eax, 1
    jmp     33f
31: cmp     r15d, 1
    jne     32f
    mov     eax, r10d
    shr     eax, 1
    jmp     33f
32: mov     eax, r11d
33: test    eax, eax
    jz      34f
    inc     r14d
    jmp     35f
34: mov     byte ptr [r12+r13], 1
35: inc     r13d
    jmp     1b
5:  test    r14d, r14d                  # vertices mode also takes loose ones
    jnz     6f
    test    r15d, r15d
    jnz     .Ldk_none
    mov     rdi, rbx                    # any selected at all?
    mov     r9, [rbx+ME_VSEL]
    xor     ecx, ecx
51: cmp     ecx, [rbx+ME_NVERTS]
    jae     .Ldk_none
    cmp     byte ptr [r9+rcx], 0
    jne     6f
    inc     ecx
    jmp     51b
6:  mov     edi, [rbx+ME_NVERTS]
    mov     esi, [rbx+ME_NLOOPS]
    mov     edx, [rbx+ME_NPOLYS]
    call    mesh_new
    test    rax, rax
    jz      .Ldk_drop
    mov     r13, rax
    mov     rdi, r13
    mov     rsi, rbx
    call    copy_verts
    mov     rdi, r13
    call    clear_vsel
    xor     r14d, r14d
7:  cmp     r14d, [rbx+ME_NPOLYS]
    jae     8f
    cmp     byte ptr [r12+r14], 0
    je      71f
    mov     rdi, r13
    mov     rsi, rbx
    mov     edx, r14d
    xor     ecx, ecx
    xor     r8d, r8d
    call    poly_copy
71: inc     r14d
    jmp     7b
8:  mov     rdi, r13
    call    mo_commit
    jmp     9f
.Ldk_none:
    lea     rdi, [rip+s_f_nothing]
    call    mo_fail
    jmp     9f
.Ldk_drop:
    call    undo_drop_last
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Extrude
# =============================================================================
do_extrude:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 32
    call    need_edit
    test    rax, rax
    jz      .Lex_drop
    mov     rbx, rax
    call    sel_polys
    test    rax, rax
    jz      .Lex_drop
    mov     r12, rax                    # selected polygons
    test    ecx, ecx
    jz      .Lex_edges
    # ---- region: new copies of the region's vertices ----
    mov     edi, [rbx+ME_NVERTS]
    mov     esi, -1
    call    fa_fill
    test    rax, rax
    jz      .Lex_drop
    mov     r13, rax                    # newv
    mov     edi, [rbx+ME_NVERTS]
    add     edi, edi
    add     edi, 8
    mov     esi, [rbx+ME_NLOOPS]
    imul    esi, esi, 5
    add     esi, 8
    mov     edx, [rbx+ME_NPOLYS]
    add     edx, [rbx+ME_NLOOPS]
    add     edx, 8
    call    mesh_new
    test    rax, rax
    jz      .Lex_drop
    mov     r14, rax
    mov     rdi, r14
    mov     rsi, rbx
    call    copy_verts
    mov     rdi, r14
    call    clear_vsel
    mov     rdi, rbx                    # newv for region vertices
    mov     rsi, r12
    mov     rdx, r13
    mov     rcx, r14
    call    dup_poly_verts
    xorps   xmm0, xmm0                  # region normal (sum of Newell normals)
    movss   [rsp], xmm0
    movss   [rsp+4], xmm0
    movss   [rsp+8], xmm0
    xor     r15d, r15d                  # polygons: region ones use the copies
1:  cmp     r15d, [rbx+ME_NPOLYS]
    jae     2f
    xor     ecx, ecx
    cmp     byte ptr [r12+r15], 0
    je      11f
    mov     rdi, rbx
    mov     esi, r15d
    call    poly_normal
    movss   xmm0, [rsp]
    addss   xmm0, [rip+nrm]
    movss   [rsp], xmm0
    movss   xmm0, [rsp+4]
    addss   xmm0, [rip+nrm+4]
    movss   [rsp+4], xmm0
    movss   xmm0, [rsp+8]
    addss   xmm0, [rip+nrm+8]
    movss   [rsp+8], xmm0
    mov     rcx, r13
11: mov     rdi, r14
    mov     rsi, rbx
    mov     edx, r15d
    xor     r8d, r8d
    call    poly_copy
    inc     r15d
    jmp     1b
2:  mov     rdi, rbx                    # side walls on the region boundary
    mov     rsi, r12
    mov     rdx, r13
    mov     rcx, r14
    call    side_walls
    mov     rdi, r14
    call    mo_commit
    lea     rdi, [rsp]
    call    normalize
    lea     rdi, [rsp]
    call    world_dir
    call    interactive
    test    eax, eax
    jz      3f
    mov     rax, [rsp]                  # move along the normal (one undo step)
    mov     [rip+tm_custom], rax
    mov     eax, [rsp+8]
    mov     [rip+tm_custom+8], eax
    mov     dword ptr [rip+tm_noundo], 1
    lea     rdi, [rip+op_m_extrude]     # the redo panel gets the distance
    mov     esi, 1
    call    lastop_pending
    mov     edi, 1
    mov     esi, 4
    xor     edx, edx
    call    tm_start
    jmp     .Lex_out
3:  movss   xmm0, [rip+mf_one]          # scripts: the argument (1 m)
    call    arg_value
    movss   [rsp+12], xmm0
    lea     rdi, [rsp]
    call    move_selected
    lea     rdi, [rip+op_m_extrude]
    lea     rsi, [rsp+12]
    mov     edx, 1
    call    lastop_set
    jmp     .Lex_out

.Lex_edges:                             # ---- edges: a strip of new faces ----
    mov     edi, [rbx+ME_NVERTS]
    mov     esi, -1
    call    fa_fill
    test    rax, rax
    jz      .Lex_drop
    mov     r13, rax                    # newv
    xor     r15d, r15d                  # selected edges
    mov     r8, [rbx+ME_EDGES]
    mov     r9, [rbx+ME_VSEL]
    xor     ecx, ecx
4:  cmp     ecx, [rbx+ME_NEDGES]
    jae     5f
    mov     eax, [r8+rcx*8]
    mov     edx, [r8+rcx*8+4]
    mov     al, [r9+rax]
    and     al, [r9+rdx]
    movzx   eax, al
    add     r15d, eax
    inc     ecx
    jmp     4b
5:  test    r15d, r15d
    jz      .Lex_nothing
    mov     edi, [rbx+ME_NVERTS]
    add     edi, edi
    add     edi, 8
    mov     esi, [rbx+ME_NLOOPS]
    lea     esi, [rsi+r15*4+8]
    mov     edx, [rbx+ME_NPOLYS]
    lea     edx, [rdx+r15+8]
    call    mesh_new
    test    rax, rax
    jz      .Lex_drop
    mov     r14, rax
    mov     rdi, r14
    mov     rsi, rbx
    call    copy_verts
    mov     rdi, r14
    call    clear_vsel
    xor     r15d, r15d                  # keep every polygon
6:  cmp     r15d, [rbx+ME_NPOLYS]
    jae     7f
    mov     rdi, r14
    mov     rsi, rbx
    mov     edx, r15d
    xor     ecx, ecx
    xor     r8d, r8d
    call    poly_copy
    inc     r15d
    jmp     6b
7:  call    edge_faces
    test    eax, eax
    jz      .Lex_drop
    xor     r15d, r15d
8:  cmp     r15d, [rbx+ME_NEDGES]
    jae     .Lex_edone
    mov     r8, [rbx+ME_EDGES]
    mov     r9, [rbx+ME_VSEL]
    mov     edi, [r8+r15*8]
    mov     esi, [r8+r15*8+4]
    mov     al, [r9+rdi]
    and     al, [r9+rsi]
    jz      81f
    mov     [rsp+16], edi
    mov     [rsp+20], esi
    mov     edx, edi                    # copies of both ends
    call    newv_of
    mov     edi, [rsp+20]
    call    newv_of
    mov     edi, [rsp+16]               # direction as in its face: reverse it
    mov     esi, [rsp+20]
    call    edge_dir_in_face            # eax = 1 if a face has a -> b
    mov     edi, [rsp+16]
    mov     esi, [rsp+20]
    test    eax, eax
    jz      82f
    xchg    edi, esi                    # quad b a a' b'
82: lea     rcx, [rip+scr]
    mov     [rcx], edi
    mov     [rcx+4], esi
    mov     eax, [r13+rsi*4]
    mov     [rcx+8], eax
    mov     eax, [r13+rdi*4]
    mov     [rcx+12], eax
    mov     rdi, r14
    mov     rsi, rcx
    mov     edx, 4
    call    mesh_add_poly
81: inc     r15d
    jmp     8b
.Lex_edone:
    mov     rdi, r14
    call    mo_commit
    call    interactive
    test    eax, eax
    jz      9f
    mov     dword ptr [rip+tm_noundo], 1    # free move of the new edges
    mov     edi, 1
    xor     esi, esi
    xor     edx, edx
    call    tm_start
    jmp     .Lex_out
9:  xorps   xmm0, xmm0                  # scripts: up by the argument
    movss   [rsp], xmm0
    movss   [rsp+8], xmm0
    movss   xmm0, [rip+mf_one]
    movss   [rsp+4], xmm0
    call    arg_value
    lea     rdi, [rsp]
    call    move_selected
    jmp     .Lex_out
.Lex_nothing:
    lea     rdi, [rip+s_f_extrude]
    call    mo_fail
    jmp     .Lex_out
.Lex_drop:
    call    undo_drop_last
.Lex_out:
    add     rsp, 32
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# newv_of(edi=vertex) - make sure r13 (newv) has a selected copy in r14
newv_of:
    cmp     dword ptr [r13+rdi*4], -1
    jne     1f
    push    rdi
    mov     edx, edi
    mov     rdi, r14
    mov     rsi, rbx
    call    copy_vert
    pop     rdi
    mov     [r13+rdi*4], eax
    mov     rcx, [r14+ME_VSEL]
    mov     byte ptr [rcx+rax], 1
1:  ret

# edge_dir_in_face(edi=a, esi=b) -> eax = 1 if some polygon of rbx runs a -> b
edge_dir_in_face:
    push    r12
    push    r13
    push    r14
    mov     r12d, edi
    mov     r13d, esi
    call    ef_find
    test    eax, eax
    js      8f
    mov     rcx, [rip+ef_f1]
    mov     r14d, [rcx+rax*4]
    test    r14d, r14d
    js      8f
    mov     rsi, [rbx+ME_POFF]
    mov     ecx, [rsi+r14*4]
    mov     edx, [rsi+r14*4+4]
    mov     r8d, ecx
    mov     rsi, [rbx+ME_LOOPS]
1:  cmp     ecx, edx
    jae     8f
    cmp     [rsi+rcx*4], r12d
    jne     2f
    lea     eax, [rcx+1]
    cmp     eax, edx
    jb      11f
    mov     eax, r8d
11: cmp     [rsi+rax*4], r13d
    je      9f
2:  inc     ecx
    jmp     1b
8:  xor     eax, eax
    jmp     10f
9:  mov     eax, 1
10: pop     r14
    pop     r13
    pop     r12
    ret

# dup_poly_verts(rdi=src, rsi=selected polys, rdx=newv, rcx=dst) - a selected
#   copy of every vertex used by a selected polygon
dup_poly_verts:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13, rdx
    mov     r14, rcx
    xor     r15d, r15d
1:  cmp     r15d, [rbx+ME_NPOLYS]
    jae     9f
    cmp     byte ptr [r12+r15], 0
    je      4f
    mov     rsi, [rbx+ME_POFF]
    mov     ecx, [rsi+r15*4]
    mov     edx, [rsi+r15*4+4]
2:  cmp     ecx, edx
    jae     4f
    mov     rsi, [rbx+ME_LOOPS]
    mov     edi, [rsi+rcx*4]
    push    rcx
    push    rdx
    call    newv_of
    pop     rdx
    pop     rcx
    inc     ecx
    jmp     2b
4:  inc     r15d
    jmp     1b
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# side_walls(rdi=src, rsi=selected polys, rdx=newv, rcx=dst) - a quad
#   a b b' a' on every region boundary edge (used by one selected polygon)
side_walls:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 24
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13, rdx
    mov     r14, rcx
    mov     edi, [rbx+ME_NLOOPS]        # count region edges
    call    eh_new
    test    rax, rax
    jz      9f
    mov     rbp, rax
    xor     r15d, r15d                  # pass 0 count, pass 1 emit
    mov     dword ptr [rsp+16], 0
.Lsw_pass:
    xor     r15d, r15d
1:  cmp     r15d, [rbx+ME_NPOLYS]
    jae     .Lsw_next
    cmp     byte ptr [r12+r15], 0
    je      5f
    mov     rsi, [rbx+ME_POFF]
    mov     ecx, [rsi+r15*4]
    mov     edx, [rsi+r15*4+4]
    mov     [rsp], ecx                  # first
    mov     [rsp+4], edx                # end
2:  cmp     ecx, [rsp+4]
    jae     5f
    mov     [rsp+8], ecx
    mov     rsi, [rbx+ME_LOOPS]
    mov     edi, [rsi+rcx*4]            # a
    lea     eax, [rcx+1]
    cmp     eax, [rsp+4]
    jb      3f
    mov     eax, [rsp]
3:  mov     esi, [rsi+rax*4]            # b
    mov     [rsp+12], esi
    mov     [rsp+20], edi
    call    ukey
    mov     rsi, rax
    mov     rdi, rbp
    call    eh_slot
    cmp     dword ptr [rsp+16], 0
    jne     4f
    test    edx, edx                    # pass 0: count uses (value = count)
    jnz     31f
    mov     dword ptr [rax], 0
31: inc     dword ptr [rax]
    jmp     41f
4:  cmp     dword ptr [rax], 1          # pass 1: boundary -> wall
    jne     41f
    mov     edi, [rsp+20]               # a
    mov     esi, [rsp+12]               # b
    lea     rcx, [rip+scr]
    mov     [rcx], edi
    mov     [rcx+4], esi
    mov     eax, [r13+rsi*4]
    mov     [rcx+8], eax
    mov     eax, [r13+rdi*4]
    mov     [rcx+12], eax
    mov     rdi, r14
    mov     rsi, rcx
    mov     edx, 4
    call    mesh_add_poly
41: mov     ecx, [rsp+8]
    inc     ecx
    jmp     2b
5:  inc     r15d
    jmp     1b
.Lsw_next:
    inc     dword ptr [rsp+16]
    cmp     dword ptr [rsp+16], 2
    jb      .Lsw_pass
9:  add     rsp, 24
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Duplicate (Shift+D in edit mode)
# =============================================================================
do_duplicate:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    call    need_edit
    test    rax, rax
    jz      .Ldu_drop
    mov     rbx, rax
    call    sel_polys
    test    rax, rax
    jz      .Ldu_drop
    mov     r12, rax
    test    ecx, ecx
    jz      .Ldu_none
    mov     edi, [rbx+ME_NVERTS]
    mov     esi, -1
    call    fa_fill
    test    rax, rax
    jz      .Ldu_drop
    mov     r13, rax
    mov     edi, [rbx+ME_NVERTS]
    add     edi, edi
    mov     esi, [rbx+ME_NLOOPS]
    add     esi, esi
    mov     edx, [rbx+ME_NPOLYS]
    add     edx, edx
    call    mesh_new
    test    rax, rax
    jz      .Ldu_drop
    mov     r14, rax
    mov     rdi, r14
    mov     rsi, rbx
    call    copy_verts
    mov     rdi, r14
    call    clear_vsel
    mov     rdi, rbx
    mov     rsi, r12
    mov     rdx, r13
    mov     rcx, r14
    call    dup_poly_verts
    xor     r15d, r15d                  # originals, then the copies
1:  cmp     r15d, [rbx+ME_NPOLYS]
    jae     2f
    mov     rdi, r14
    mov     rsi, rbx
    mov     edx, r15d
    xor     ecx, ecx
    xor     r8d, r8d
    call    poly_copy
    inc     r15d
    jmp     1b
2:  xor     r15d, r15d
3:  cmp     r15d, [rbx+ME_NPOLYS]
    jae     4f
    cmp     byte ptr [r12+r15], 0
    je      31f
    mov     rdi, r14
    mov     rsi, rbx
    mov     edx, r15d
    mov     rcx, r13
    xor     r8d, r8d
    call    poly_copy
31: inc     r15d
    jmp     3b
4:  mov     rdi, r14
    call    mo_commit
    call    interactive
    test    eax, eax
    jz      9f
    mov     dword ptr [rip+tm_noundo], 1
    mov     edi, 1
    xor     esi, esi
    xor     edx, edx
    call    tm_start
    jmp     9f
.Ldu_none:
    lea     rdi, [rip+s_f_faces]
    call    mo_fail
    jmp     9f
.Ldu_drop:
    call    undo_drop_last
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Modal value operators: inset and individual extrude rebuild from a source
# =============================================================================
do_inset:
    mov     edi, 1
    movss   xmm0, [rip+mf_tenth]
    jmp     value_op
do_extrude_ind:
    mov     edi, 2
    movss   xmm0, [rip+mf_one]

# value_op(edi=kind, xmm0=default value)
value_op:
    push    rbx
    sub     rsp, 16
    movss   [rsp], xmm0
    mov     [rsp+4], edi
    call    need_edit
    test    rax, rax
    jz      .Lvo_drop
    mov     rbx, rax
    call    sel_polys
    test    rax, rax
    jz      .Lvo_drop
    test    ecx, ecx
    jz      .Lvo_none
    mov     [rip+mo_src], rbx           # source: the current mesh (ref held)
    mov     rdi, rbx
    call    mesh_ref
    mov     eax, [rsp+4]
    mov     [rip+mo_kind], eax
    call    interactive
    test    eax, eax
    jz      1f
    call    vo_op                       # the redo panel gets the value
    mov     rdi, rax
    mov     esi, 2
    call    lastop_pending
    lea     rdi, [rip+mo_apply]
    lea     rsi, [rip+mo_cancel]
    lea     rdx, [rip+mo_confirm]
    lea     rcx, [rip+s_lbl_inset]
    cmp     dword ptr [rsp+4], 1
    je      2f
    lea     rcx, [rip+s_lbl_ext]
2:  call    tm_start_value
    jmp     9f
1:  movss   xmm0, [rsp]                 # scripts: the argument
    call    arg_value
    movss   [rsp+8], xmm0
    call    mo_apply
    call    mo_confirm
    call    vo_op
    mov     rdi, rax
    lea     rsi, [rsp+8]
    mov     edx, 1
    call    lastop_set
    jmp     9f
.Lvo_none:
    lea     rdi, [rip+s_f_faces]
    call    mo_fail
    jmp     9f
.Lvo_drop:
    call    undo_drop_last
9:  add     rsp, 16
    pop     rbx
    ret

# vo_op -> rax = the operator of value_op's kind
vo_op:
    lea     rax, [rip+op_m_inset]
    cmp     dword ptr [rip+mo_kind], 1
    je      1f
    lea     rax, [rip+op_m_extrude_ind]
1:  ret

# mo_apply(xmm0=value) - rebuild from mo_src and swap in
mo_apply:
    sub     rsp, 8
    mov     rdi, [rip+mo_src]
    test    rdi, rdi
    jz      9f
    cmp     dword ptr [rip+mo_kind], 1
    jne     1f
    call    build_inset
    jmp     2f
1:  call    build_extrude_ind
2:  test    rax, rax
    jz      9f
    mov     rdi, rax
    call    mo_commit
9:  add     rsp, 8
    ret

mo_cancel:
    sub     rsp, 8
    mov     rdi, [rip+mo_src]
    test    rdi, rdi
    jz      9f
    mov     qword ptr [rip+mo_src], 0
    call    edit_replace                # our reference goes back to the object
9:  add     rsp, 8
    ret

mo_confirm:
    sub     rsp, 8
    mov     rdi, [rip+mo_src]
    mov     qword ptr [rip+mo_src], 0
    call    mesh_unref
    add     rsp, 8
    ret

# build_inset(rdi=src, xmm0=thickness) -> rax = new mesh (not finished):
#   every selected face gets an inner copy, offset inwards by the thickness
#   from each edge, and a ring of quads
build_inset:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 104
    mov     rbx, rdi
    movss   [rsp+96], xmm0
    call    sel_polys
    test    rax, rax
    jz      .Lbi_fail
    mov     r12, rax
    mov     edi, [rbx+ME_NVERTS]
    add     edi, [rbx+ME_NLOOPS]
    add     edi, 8
    mov     esi, [rbx+ME_NLOOPS]
    imul    esi, esi, 5
    add     esi, 8
    mov     edx, [rbx+ME_NPOLYS]
    add     edx, [rbx+ME_NLOOPS]
    add     edx, 8
    call    mesh_new
    test    rax, rax
    jz      .Lbi_fail
    mov     r14, rax
    mov     rdi, r14
    mov     rsi, rbx
    call    copy_verts
    mov     rdi, r14
    call    clear_vsel
    xor     r15d, r15d
.Lbi_poly:
    cmp     r15d, [rbx+ME_NPOLYS]
    jae     .Lbi_done
    cmp     byte ptr [r12+r15], 0
    jne     1f
    mov     rdi, r14                    # unselected: as is
    mov     rsi, rbx
    mov     edx, r15d
    xor     ecx, ecx
    xor     r8d, r8d
    call    poly_copy
    jmp     .Lbi_next
1:  mov     rdi, rbx
    mov     esi, r15d
    call    poly_normal
    lea     rdi, [rip+nrm]
    call    normalize
    mov     rsi, [rbx+ME_POFF]
    mov     eax, [rsi+r15*4]
    mov     [rsp+80], eax               # first loop
    mov     ecx, [rsi+r15*4+4]
    sub     ecx, eax
    mov     [rsp+84], ecx               # n
    cmp     ecx, SCR_MAX/2
    ja      .Lbi_next
    xor     ebp, ebp                    # i: inner vertex i
2:  cmp     ebp, [rsp+84]
    jae     3f
    mov     eax, ebp                    # prev, cur, next positions
    dec     eax
    jns     21f
    mov     eax, [rsp+84]
    dec     eax
21: call    loop_pos                    # rdi -> float[3]
    mov     r8, rdi
    mov     eax, ebp
    call    loop_pos
    mov     r9, rdi
    lea     eax, [rbp+1]
    cmp     eax, [rsp+84]
    jb      22f
    xor     eax, eax
22: call    loop_pos
    mov     r10, rdi
    # in_p = N x (c - p), in_q = N x (q - c), both unit
    lea     rdi, [rsp]
    mov     rsi, r8
    mov     rdx, r9
    call    inward
    lea     rdi, [rsp+16]
    mov     rsi, r9
    mov     rdx, r10
    call    inward
    # d = normalize(in_p + in_q); len = t / max(d . in_q, 0.2)
    movss   xmm0, [rsp]
    addss   xmm0, [rsp+16]
    movss   [rsp+32], xmm0
    movss   xmm0, [rsp+4]
    addss   xmm0, [rsp+20]
    movss   [rsp+36], xmm0
    movss   xmm0, [rsp+8]
    addss   xmm0, [rsp+24]
    movss   [rsp+40], xmm0
    lea     rdi, [rsp+32]
    call    normalize
    movss   xmm0, [rsp+32]
    mulss   xmm0, [rsp+16]
    movss   xmm1, [rsp+36]
    mulss   xmm1, [rsp+20]
    addss   xmm0, xmm1
    movss   xmm1, [rsp+40]
    mulss   xmm1, [rsp+24]
    addss   xmm0, xmm1
    maxss   xmm0, [rip+mf_min_dot]
    movss   xmm1, [rsp+96]
    divss   xmm1, xmm0
    xor     ecx, ecx
23: movss   xmm0, [rsp+32+rcx*4]
    mulss   xmm0, xmm1
    addss   xmm0, [r9+rcx*4]
    movss   [rsp+48+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      23b
    mov     rdi, r14
    lea     rsi, [rsp+48]
    mov     edx, 1
    call    add_vert_at
    lea     rcx, [rip+scr]              # inner indices at scr[n + i]
    mov     edx, [rsp+84]
    add     edx, ebp
    mov     [rcx+rdx*4], eax
    inc     ebp
    jmp     2b
3:  xor     ebp, ebp                    # ring quads c_i c_i+1 c'_i+1 c'_i
4:  cmp     ebp, [rsp+84]
    jae     5f
    lea     eax, [rbp+1]
    cmp     eax, [rsp+84]
    jb      41f
    xor     eax, eax
41: mov     [rsp+88], eax
    mov     rsi, [rbx+ME_LOOPS]
    mov     ecx, [rsp+80]
    add     ecx, ebp
    mov     edi, [rsi+rcx*4]
    mov     ecx, [rsp+80]
    add     ecx, eax
    mov     r8d, [rsi+rcx*4]
    lea     rcx, [rip+scr]
    mov     edx, [rsp+84]
    add     edx, eax
    mov     r9d, [rcx+rdx*4]
    mov     edx, [rsp+84]
    add     edx, ebp
    mov     r10d, [rcx+rdx*4]
    lea     rsi, [rip+tmpv]
    mov     [rsi], edi
    mov     [rsi+4], r8d
    mov     [rsi+8], r9d
    mov     [rsi+12], r10d
    mov     rdi, r14
    mov     edx, 4
    call    mesh_add_poly
    inc     ebp
    jmp     4b
5:  mov     rdi, r14                    # the inner face
    lea     rsi, [rip+scr]
    mov     eax, [rsp+84]
    lea     rsi, [rsi+rax*4]
    mov     edx, eax
    call    mesh_add_poly
.Lbi_next:
    inc     r15d
    jmp     .Lbi_poly
.Lbi_done:
    mov     rax, r14
    jmp     9f
.Lbi_fail:
    xor     eax, eax
9:  add     rsp, 104
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# loop_pos(eax=i in the polygon at [rsp+8+80] of build_inset) -> rdi = &pos
#   (called from build_inset only: its frame is one return address up)
loop_pos:
    add     eax, [rsp+8+80]
    mov     rdi, [rbx+ME_LOOPS]
    mov     eax, [rdi+rax*4]
    lea     rax, [rax+rax*2]
    mov     rdi, [rbx+ME_POS]
    lea     rdi, [rdi+rax*4]
    ret

# inward(rdi=out, rsi=a, rdx=b) - unit nrm x (b - a): left of a -> b
inward:
    movss   xmm0, [rdx]
    subss   xmm0, [rsi]
    movss   xmm1, [rdx+4]
    subss   xmm1, [rsi+4]
    movss   xmm2, [rdx+8]
    subss   xmm2, [rsi+8]
    movss   xmm3, [rip+nrm+4]           # x = ny ez - nz ey
    mulss   xmm3, xmm2
    movss   xmm4, [rip+nrm+8]
    mulss   xmm4, xmm1
    subss   xmm3, xmm4
    movss   [rdi], xmm3
    movss   xmm3, [rip+nrm+8]           # y = nz ex - nx ez
    mulss   xmm3, xmm0
    movss   xmm4, [rip+nrm]
    mulss   xmm4, xmm2
    subss   xmm3, xmm4
    movss   [rdi+4], xmm3
    movss   xmm3, [rip+nrm]             # z = nx ey - ny ex
    mulss   xmm3, xmm1
    movss   xmm4, [rip+nrm+4]
    mulss   xmm4, xmm0
    subss   xmm3, xmm4
    movss   [rdi+8], xmm3
    jmp     normalize

# build_extrude_ind(rdi=src, xmm0=distance) -> rax = new mesh: every
#   selected face moves out along its own normal, with side walls
build_extrude_ind:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 40
    mov     rbx, rdi
    movss   [rsp+32], xmm0
    call    sel_polys
    test    rax, rax
    jz      .Lbx_fail
    mov     r12, rax
    mov     edi, [rbx+ME_NVERTS]
    add     edi, [rbx+ME_NLOOPS]
    add     edi, 8
    mov     esi, [rbx+ME_NLOOPS]
    imul    esi, esi, 5
    add     esi, 8
    mov     edx, [rbx+ME_NPOLYS]
    add     edx, [rbx+ME_NLOOPS]
    add     edx, 8
    call    mesh_new
    test    rax, rax
    jz      .Lbx_fail
    mov     r14, rax
    mov     rdi, r14
    mov     rsi, rbx
    call    copy_verts
    mov     rdi, r14
    call    clear_vsel
    xor     r15d, r15d
1:  cmp     r15d, [rbx+ME_NPOLYS]
    jae     .Lbx_done
    cmp     byte ptr [r12+r15], 0
    jne     2f
    mov     rdi, r14
    mov     rsi, rbx
    mov     edx, r15d
    xor     ecx, ecx
    xor     r8d, r8d
    call    poly_copy
    jmp     8f
2:  mov     rdi, rbx
    mov     esi, r15d
    call    poly_normal
    lea     rdi, [rip+nrm]
    call    normalize
    mov     rsi, [rbx+ME_POFF]
    mov     r13d, [rsi+r15*4]           # first loop
    mov     ebp, [rsi+r15*4+4]
    sub     ebp, r13d                   # n
    cmp     ebp, SCR_MAX/2
    ja      8f
    xor     ecx, ecx                    # moved copies at scr[n + i]
3:  cmp     ecx, ebp
    jae     4f
    mov     [rsp+24], ecx
    mov     rsi, [rbx+ME_LOOPS]
    lea     eax, [r13+rcx]
    mov     eax, [rsi+rax*4]
    lea     rax, [rax+rax*2]
    mov     rsi, [rbx+ME_POS]
    lea     rsi, [rsi+rax*4]
    xor     edx, edx
    lea     r8, [rip+nrm]
31: movss   xmm0, [r8+rdx*4]
    mulss   xmm0, [rsp+32]
    addss   xmm0, [rsi+rdx*4]
    movss   [rsp+rdx*4], xmm0
    inc     edx
    cmp     edx, 3
    jb      31b
    mov     rdi, r14
    lea     rsi, [rsp]
    mov     edx, 1
    call    add_vert_at
    mov     ecx, [rsp+24]
    lea     rdx, [rip+scr]
    lea     r8d, [rbp+rcx]
    mov     [rdx+r8*4], eax
    inc     ecx
    jmp     3b
4:  xor     ecx, ecx                    # walls a b b' a'
5:  cmp     ecx, ebp
    jae     6f
    mov     [rsp+24], ecx
    lea     eax, [rcx+1]
    cmp     eax, ebp
    jb      51f
    xor     eax, eax
51: mov     rsi, [rbx+ME_LOOPS]
    lea     edx, [r13+rcx]
    mov     edi, [rsi+rdx*4]            # a
    lea     edx, [r13+rax]
    mov     r8d, [rsi+rdx*4]            # b
    lea     rsi, [rip+scr]
    lea     edx, [rbp+rax]
    mov     r9d, [rsi+rdx*4]            # b'
    lea     edx, [rbp+rcx]
    mov     r10d, [rsi+rdx*4]           # a'
    lea     rsi, [rip+tmpv]
    mov     [rsi], edi
    mov     [rsi+4], r8d
    mov     [rsi+8], r9d
    mov     [rsi+12], r10d
    mov     rdi, r14
    mov     edx, 4
    call    mesh_add_poly
    mov     ecx, [rsp+24]
    inc     ecx
    jmp     5b
6:  mov     rdi, r14                    # the moved face
    lea     rsi, [rip+scr]
    lea     rsi, [rsi+rbp*4]
    mov     edx, ebp
    call    mesh_add_poly
8:  inc     r15d
    jmp     1b
.Lbx_done:
    mov     rax, r14
    jmp     9f
.Lbx_fail:
    xor     eax, eax
9:  add     rsp, 40
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Subdivide: quads -> 4 quads, triangles -> 4 triangles, n-gons -> n quads;
#  neighbours get the new edge midpoints in their outline
# =============================================================================
do_subdivide:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 56
    call    need_edit
    test    rax, rax
    jz      .Lsd_drop
    mov     rbx, rax
    call    sel_polys
    test    rax, rax
    jz      .Lsd_drop
    mov     r12, rax
    test    ecx, ecx
    jz      .Lsd_none
    mov     edi, [rbx+ME_NLOOPS]
    call    eh_new
    test    rax, rax
    jz      .Lsd_drop
    mov     r13, rax                    # edge -> midpoint vertex
    mov     edi, [rbx+ME_NVERTS]
    add     edi, [rbx+ME_NLOOPS]
    add     edi, [rbx+ME_NPOLYS]
    add     edi, 8
    mov     esi, [rbx+ME_NLOOPS]
    imul    esi, esi, 6
    add     esi, 8
    mov     edx, [rbx+ME_NPOLYS]
    add     edx, [rbx+ME_NLOOPS]
    add     edx, 8
    call    mesh_new
    test    rax, rax
    jz      .Lsd_drop
    mov     r14, rax
    mov     rdi, r14
    mov     rsi, rbx
    call    copy_verts
    xor     r15d, r15d                  # midpoints of the selected faces' edges
1:  cmp     r15d, [rbx+ME_NPOLYS]
    jae     2f
    cmp     byte ptr [r12+r15], 0
    je      14f
    mov     rsi, [rbx+ME_POFF]
    mov     ecx, [rsi+r15*4]
    mov     edx, [rsi+r15*4+4]
    mov     [rsp+40], ecx
    mov     [rsp+44], edx
11: cmp     ecx, [rsp+44]
    jae     14f
    mov     [rsp+48], ecx
    mov     rsi, [rbx+ME_LOOPS]
    mov     edi, [rsi+rcx*4]
    lea     eax, [rcx+1]
    cmp     eax, [rsp+44]
    jb      12f
    mov     eax, [rsp+40]
12: mov     esi, [rsi+rax*4]
    mov     [rsp+32], edi
    mov     [rsp+36], esi
    call    ukey
    mov     rsi, rax
    mov     rdi, r13
    call    eh_slot
    test    edx, edx
    jnz     13f
    mov     rbp, rax                    # new midpoint vertex
    mov     edi, [rsp+32]
    mov     esi, [rsp+36]
    lea     rdx, [rsp]
    call    midpoint
    mov     rdi, r14
    lea     rsi, [rsp]
    mov     edx, 1
    call    add_vert_at
    mov     [rbp], eax
13: mov     ecx, [rsp+48]
    inc     ecx
    jmp     11b
14: inc     r15d
    jmp     1b
2:  xor     r15d, r15d                  # polygons
.Lsd_poly:
    cmp     r15d, [rbx+ME_NPOLYS]
    jae     .Lsd_commit
    mov     rsi, [rbx+ME_POFF]
    mov     ecx, [rsi+r15*4]
    mov     edx, [rsi+r15*4+4]
    mov     [rsp+40], ecx
    mov     [rsp+44], edx
    sub     edx, ecx
    mov     [rsp+52], edx               # n
    cmp     edx, SCR_MAX/3
    ja      .Lsd_next
    # outline with midpoints (where they exist): scr = v0 [m0] v1 [m1] ...
    xor     ebp, ebp                    # outline length
    mov     ecx, [rsp+40]
3:  cmp     ecx, [rsp+44]
    jae     4f
    mov     [rsp+48], ecx
    mov     rsi, [rbx+ME_LOOPS]
    mov     edi, [rsi+rcx*4]
    lea     rdx, [rip+scr]
    mov     [rdx+rbp*4], edi
    inc     ebp
    lea     eax, [rcx+1]
    cmp     eax, [rsp+44]
    jb      31f
    mov     eax, [rsp+40]
31: mov     esi, [rsi+rax*4]
    call    mid_find                    # eax = midpoint or -1
    test    eax, eax
    js      32f
    lea     rdx, [rip+scr]
    mov     [rdx+rbp*4], eax
    inc     ebp
32: mov     ecx, [rsp+48]
    inc     ecx
    jmp     3b
4:  cmp     byte ptr [r12+r15], 0
    jne     5f
    mov     rdi, r14                    # neighbour: just the longer outline
    lea     rsi, [rip+scr]
    mov     edx, ebp
    call    mesh_add_poly
    jmp     .Lsd_next
5:  cmp     dword ptr [rsp+52], 3       # selected: outline is v0 m0 v1 m1 ...
    jne     6f
    lea     rsi, [rip+scr]              # triangle: corners + middle
    lea     rdi, [rip+tmpv]
    mov     eax, [rsi]                  # v0 m0 m2
    mov     [rdi], eax
    mov     eax, [rsi+4]
    mov     [rdi+4], eax
    mov     eax, [rsi+20]
    mov     [rdi+8], eax
    call    sd_tri
    lea     rsi, [rip+scr]              # v1 m1 m0
    lea     rdi, [rip+tmpv]
    mov     eax, [rsi+8]
    mov     [rdi], eax
    mov     eax, [rsi+12]
    mov     [rdi+4], eax
    mov     eax, [rsi+4]
    mov     [rdi+8], eax
    call    sd_tri
    lea     rsi, [rip+scr]              # v2 m2 m1
    lea     rdi, [rip+tmpv]
    mov     eax, [rsi+16]
    mov     [rdi], eax
    mov     eax, [rsi+20]
    mov     [rdi+4], eax
    mov     eax, [rsi+12]
    mov     [rdi+8], eax
    call    sd_tri
    lea     rsi, [rip+scr]              # m0 m1 m2
    lea     rdi, [rip+tmpv]
    mov     eax, [rsi+4]
    mov     [rdi], eax
    mov     eax, [rsi+12]
    mov     [rdi+4], eax
    mov     eax, [rsi+20]
    mov     [rdi+8], eax
    call    sd_tri
    jmp     .Lsd_next
6:  mov     rdi, rbx                    # centre vertex
    mov     esi, r15d
    lea     rdx, [rsp]
    call    poly_center
    mov     rdi, r14
    lea     rsi, [rsp]
    mov     edx, 1
    call    add_vert_at
    mov     [rsp+32], eax               # c
    xor     ecx, ecx                    # quads v_i m_i c m_i-1
7:  cmp     ecx, [rsp+52]
    jae     .Lsd_next
    mov     [rsp+48], ecx
    lea     rsi, [rip+scr]
    lea     rdi, [rip+tmpv]
    lea     eax, [rcx+rcx]
    mov     edx, [rsi+rax*4]            # v_i
    mov     [rdi], edx
    mov     edx, [rsi+rax*4+4]          # m_i
    mov     [rdi+4], edx
    mov     edx, [rsp+32]
    mov     [rdi+8], edx
    dec     eax                         # m_i-1 (wraps to the last)
    jns     71f
    mov     eax, ebp
    dec     eax
71: mov     edx, [rsi+rax*4]
    mov     [rdi+12], edx
    mov     rdi, r14
    lea     rsi, [rip+tmpv]
    mov     edx, 4
    call    mesh_add_poly
    mov     ecx, [rsp+48]
    inc     ecx
    jmp     7b
.Lsd_next:
    inc     r15d
    jmp     .Lsd_poly
.Lsd_commit:
    mov     rdi, r14
    call    mo_commit
    jmp     9f
.Lsd_none:
    lea     rdi, [rip+s_f_faces]
    call    mo_fail
    jmp     9f
.Lsd_drop:
    call    undo_drop_last
9:  add     rsp, 56
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# sd_tri - tmpv[0..2] as a triangle of r14
sd_tri:
    sub     rsp, 8
    mov     rdi, r14
    lea     rsi, [rip+tmpv]
    mov     edx, 3
    call    mesh_add_poly
    add     rsp, 8
    ret

# mid_find(edi=a, esi=b) -> eax = midpoint of the edge (r13 table) or -1
mid_find:
    call    ukey
    lea     rsi, [rax+1]
    mov     rdi, r13
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

# midpoint(edi=a, esi=b, rdx=out) - of two vertices of rbx
midpoint:
    mov     r8, [rbx+ME_POS]
    lea     rdi, [rdi+rdi*2]
    lea     rsi, [rsi+rsi*2]
    xor     ecx, ecx
1:  movss   xmm0, [r8+rdi*4]
    addss   xmm0, [r8+rsi*4]
    mulss   xmm0, [rip+mf_half]
    movss   [rdx+rcx*4], xmm0
    add     rdi, 1
    add     rsi, 1
    inc     ecx
    cmp     ecx, 3
    jb      1b
    ret

# poly_center(rdi=mesh, esi=polygon, rdx=out float[3])
poly_center:
    mov     r8, [rdi+ME_POFF]
    mov     ecx, [r8+rsi*4]
    mov     r9d, [r8+rsi*4+4]
    mov     r10, [rdi+ME_LOOPS]
    mov     r11, [rdi+ME_POS]
    xorps   xmm0, xmm0
    xorps   xmm1, xmm1
    xorps   xmm2, xmm2
    mov     esi, r9d
    sub     esi, ecx
1:  cmp     ecx, r9d
    jae     2f
    mov     eax, [r10+rcx*4]
    lea     rax, [rax+rax*2]
    addss   xmm0, [r11+rax*4]
    addss   xmm1, [r11+rax*4+4]
    addss   xmm2, [r11+rax*4+8]
    inc     ecx
    jmp     1b
2:  cvtsi2ss xmm3, esi
    divss   xmm0, xmm3
    divss   xmm1, xmm3
    divss   xmm2, xmm3
    movss   [rdx], xmm0
    movss   [rdx+4], xmm1
    movss   [rdx+8], xmm2
    ret

# =============================================================================
#  Flip and recalculate normals
# =============================================================================
do_flip:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    call    need_edit
    test    rax, rax
    jz      .Lfl_drop
    mov     rbx, rax
    call    sel_polys
    test    rax, rax
    jz      .Lfl_drop
    mov     r12, rax
    test    ecx, ecx
    jz      .Lfl_none
    mov     rdi, r12
    call    rebuild_flipped             # flip flags = the selection
    jmp     9f
.Lfl_none:
    lea     rdi, [rip+s_f_faces]
    call    mo_fail
    jmp     9f
.Lfl_drop:
    call    undo_drop_last
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# rebuild_flipped(rdi=flip flags per polygon) - rbx = mesh
rebuild_flipped:
    push    r12
    push    r13
    push    r14
    mov     r12, rdi
    mov     edi, [rbx+ME_NVERTS]
    mov     esi, [rbx+ME_NLOOPS]
    mov     edx, [rbx+ME_NPOLYS]
    call    mesh_new
    test    rax, rax
    jz      9f
    mov     r13, rax
    mov     rdi, r13
    mov     rsi, rbx
    call    copy_verts
    xor     r14d, r14d
1:  cmp     r14d, [rbx+ME_NPOLYS]
    jae     2f
    mov     rdi, r13
    mov     rsi, rbx
    mov     edx, r14d
    xor     ecx, ecx
    movzx   r8d, byte ptr [r12+r14]
    call    poly_copy
    inc     r14d
    jmp     1b
2:  mov     rdi, r13
    call    mo_commit
9:  pop     r14
    pop     r13
    pop     r12
    ret

# Recalculate: walk over shared edges making neighbours consistent, then
# point each connected part outwards (positive signed volume)
do_recalc:
    mov     dword ptr [rip+rc_all], 0
    jmp     recalc_common
# recalc_all - every face of the edit mesh (after spin, bridge...)
recalc_all:
    mov     dword ptr [rip+rc_all], 1
recalc_common:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 40
    call    need_edit
    test    rax, rax
    jz      .Lrc_drop
    mov     rbx, rax
    call    sel_polys                   # the set: selected faces, or all
    test    rax, rax
    jz      .Lrc_drop
    mov     r12, rax
    cmp     dword ptr [rip+rc_all], 0
    jne     0f
    test    ecx, ecx
    jnz     1f
0:
    mov     rdi, r12
    mov     ecx, [rbx+ME_NPOLYS]
    mov     al, 1
    rep     stosb
1:  call    edge_faces
    test    eax, eax
    jz      .Lrc_drop
    mov     edi, [rbx+ME_NPOLYS]
    call    fa
    test    rax, rax
    jz      .Lrc_drop
    mov     r13, rax                    # flip flags
    mov     edi, [rbx+ME_NPOLYS]
    call    fa
    test    rax, rax
    jz      .Lrc_drop
    mov     r14, rax                    # visited
    mov     edi, [rbx+ME_NPOLYS]
    shl     edi, 2
    call    fa
    test    rax, rax
    jz      .Lrc_drop
    mov     r15, rax                    # BFS queue (also the part's members)
    xor     ebp, ebp                    # seed polygon
.Lrc_seed:
    cmp     ebp, [rbx+ME_NPOLYS]
    jae     .Lrc_build
    cmp     byte ptr [r12+rbp], 0
    je      .Lrc_snext
    cmp     byte ptr [r14+rbp], 0
    jne     .Lrc_snext
    mov     byte ptr [r14+rbp], 1
    mov     [r15], ebp
    mov     dword ptr [rsp], 0          # head
    mov     dword ptr [rsp+4], 1        # tail
.Lrc_bfs:
    mov     eax, [rsp]
    cmp     eax, [rsp+4]
    jae     .Lrc_part
    mov     ecx, [r15+rax*4]            # f
    mov     [rsp+8], ecx
    inc     dword ptr [rsp]
    mov     rsi, [rbx+ME_POFF]
    mov     edx, [rsi+rcx*4]
    mov     [rsp+12], edx               # first
    mov     edx, [rsi+rcx*4+4]
    mov     [rsp+16], edx               # end
    mov     edx, [rsp+12]
.Lrc_edge:
    cmp     edx, [rsp+16]
    jae     .Lrc_bfs
    mov     [rsp+20], edx
    mov     rsi, [rbx+ME_LOOPS]
    mov     edi, [rsi+rdx*4]            # a
    lea     eax, [rdx+1]
    cmp     eax, [rsp+16]
    jb      2f
    mov     eax, [rsp+12]
2:  mov     esi, [rsi+rax*4]            # b
    mov     [rsp+24], edi
    mov     [rsp+28], esi
    call    ef_find
    test    eax, eax
    js      .Lrc_enext
    mov     rcx, [rip+ef_cnt]
    cmp     dword ptr [rcx+rax*4], 2
    jne     .Lrc_enext                  # boundary or non-manifold
    mov     rcx, [rip+ef_f1]
    mov     r8d, [rcx+rax*4]
    mov     rcx, [rip+ef_f2]
    mov     r9d, [rcx+rax*4]
    mov     ecx, [rsp+8]
    mov     r10d, r8d                   # g = the other face
    cmp     r8d, ecx
    jne     3f
    mov     r10d, r9d
3:  test    r10d, r10d
    js      .Lrc_enext
    cmp     byte ptr [r12+r10], 0
    je      .Lrc_enext
    cmp     byte ptr [r14+r10], 0
    jne     .Lrc_enext
    mov     [rsp+32], r10d
    # does g run a -> b too? then (f flipped XOR g) must differ: flip g
    mov     edi, [rsp+24]
    mov     esi, [rsp+28]
    mov     edx, r10d
    call    poly_has_dir                # eax = 1 if g has a -> b
    mov     r10d, [rsp+32]
    mov     ecx, [rsp+8]
    movzx   edx, byte ptr [r13+rcx]     # f's flip
    xor     eax, edx                    # same effective direction -> flip g
    mov     [r13+r10], al
    mov     byte ptr [r14+r10], 1
    mov     eax, [rsp+4]
    mov     [r15+rax*4], r10d
    inc     dword ptr [rsp+4]
.Lrc_enext:
    mov     edx, [rsp+20]
    inc     edx
    jmp     .Lrc_edge
.Lrc_part:                              # the part is r15[0 .. tail): outwards?
    mov     ecx, [rsp+4]
    mov     rdi, r15
    mov     rsi, r13
    call    part_volume                 # xmm0 = signed volume
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    jae     .Lrc_snext
    xor     ecx, ecx                    # inside out: flip the whole part
4:  cmp     ecx, [rsp+4]
    jae     .Lrc_snext
    mov     eax, [r15+rcx*4]
    xor     byte ptr [r13+rax], 1
    inc     ecx
    jmp     4b
.Lrc_snext:
    inc     ebp
    jmp     .Lrc_seed
.Lrc_build:
    mov     rdi, r13
    call    rebuild_flipped
    jmp     9f
.Lrc_drop:
    call    undo_drop_last
9:  add     rsp, 40
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# poly_has_dir(edi=a, esi=b, edx=polygon) -> eax = 1 if it runs a -> b
poly_has_dir:
    mov     r8, [rbx+ME_POFF]
    mov     ecx, [r8+rdx*4]
    mov     r9d, [r8+rdx*4+4]
    mov     r10d, ecx
    mov     r8, [rbx+ME_LOOPS]
1:  cmp     ecx, r9d
    jae     8f
    cmp     [r8+rcx*4], edi
    jne     2f
    lea     eax, [rcx+1]
    cmp     eax, r9d
    jb      11f
    mov     eax, r10d
11: cmp     [r8+rax*4], esi
    jne     2f
    mov     eax, 1
    ret
2:  inc     ecx
    jmp     1b
8:  xor     eax, eax
    ret

# part_volume(rdi=polygons u32[], ecx=count, rsi=flip flags) -> xmm0 =
#   sum of v0 . (v1 x v2) over the fan triangles (sign = orientation)
part_volume:
    push    r12
    push    r13
    push    r14
    push    r15
    xorps   xmm7, xmm7
    mov     r12, rdi
    mov     r13d, ecx
    mov     r14, rsi
    xor     r15d, r15d
1:  cmp     r15d, r13d
    jae     9f
    mov     edx, [r12+r15*4]
    mov     r8, [rbx+ME_POFF]
    mov     ecx, [r8+rdx*4]             # v0 = first loop
    mov     r9d, [r8+rdx*4+4]
    mov     r10, [rbx+ME_LOOPS]
    mov     r11, [rbx+ME_POS]
    mov     eax, [r10+rcx*4]
    lea     rax, [rax+rax*2]
    lea     rdi, [r11+rax*4]            # &v0
    xorps   xmm6, xmm6                  # this polygon's sum
    lea     esi, [rcx+1]
2:  lea     eax, [rsi+1]
    cmp     eax, r9d
    jae     3f
    mov     r8d, [r10+rsi*4]
    lea     r8, [r8+r8*2]
    lea     r8, [r11+r8*4]              # v1
    mov     eax, [r10+rax*4]
    lea     rax, [rax+rax*2]
    lea     rax, [r11+rax*4]            # v2
    movss   xmm0, [r8+4]                # (v1 x v2)
    mulss   xmm0, [rax+8]
    movss   xmm1, [r8+8]
    mulss   xmm1, [rax+4]
    subss   xmm0, xmm1
    mulss   xmm0, [rdi]
    movss   xmm2, [r8+8]
    mulss   xmm2, [rax]
    movss   xmm1, [r8]
    mulss   xmm1, [rax+8]
    subss   xmm2, xmm1
    mulss   xmm2, [rdi+4]
    addss   xmm0, xmm2
    movss   xmm2, [r8]
    mulss   xmm2, [rax+4]
    movss   xmm1, [r8+4]
    mulss   xmm1, [rax]
    subss   xmm2, xmm1
    mulss   xmm2, [rdi+8]
    addss   xmm0, xmm2
    addss   xmm6, xmm0
    inc     esi
    jmp     2b
3:  cmp     byte ptr [r14+rdx], 0
    je      4f
    xorps   xmm0, xmm0
    subss   xmm0, xmm6
    movss   xmm6, xmm0
4:  addss   xmm7, xmm6
    inc     r15d
    jmp     1b
9:  movss   xmm0, xmm7
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    ret

# =============================================================================
#  Merge: at center, collapse (per connected group), by distance
# =============================================================================
do_merge_c:
    xor     edi, edi
    jmp     merge_kind
do_merge_col:
    mov     edi, 1
    jmp     merge_kind
do_merge_d:
    mov     edi, 2

# merge_kind(edi=0 center / 1 collapse / 2 distance)
merge_kind:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 72
    mov     [rsp+48], edi
    call    need_edit
    test    rax, rax
    jz      .Lmg_drop
    mov     rbx, rax
    mov     edi, [rbx+ME_NVERTS]
    shl     edi, 2
    call    fa
    test    rax, rax
    jz      .Lmg_drop
    mov     r12, rax                    # target T[v]
    xor     ecx, ecx
1:  cmp     ecx, [rbx+ME_NVERTS]
    jae     2f
    mov     [r12+rcx*4], ecx
    inc     ecx
    jmp     1b
2:  mov     edi, [rbx+ME_NVERTS]        # new positions for targets
    imul    edi, edi, 12
    call    fa
    test    rax, rax
    jz      .Lmg_drop
    mov     r13, rax
    mov     rdi, r13
    mov     rsi, [rbx+ME_POS]
    mov     ecx, [rbx+ME_NVERTS]
    imul    ecx, ecx, 12
    rep     movsb
    xor     r14d, r14d                  # merged away
    cmp     dword ptr [rsp+48], 1
    je      .Lmg_collapse
    cmp     dword ptr [rsp+48], 2
    je      .Lmg_distance
    # ---- center: every selected vertex -> the first one, at the centroid
    mov     r15d, -1
    xorps   xmm3, xmm3
    xorps   xmm4, xmm4
    xorps   xmm5, xmm5
    xor     ebp, ebp                    # count
    mov     r8, [rbx+ME_VSEL]
    mov     r9, [rbx+ME_POS]
    xor     ecx, ecx
3:  cmp     ecx, [rbx+ME_NVERTS]
    jae     4f
    cmp     byte ptr [r8+rcx], 0
    je      31f
    cmp     r15d, -1
    jne     32f
    mov     r15d, ecx
32: mov     [r12+rcx*4], r15d
    lea     rax, [rcx+rcx*2]
    addss   xmm3, [r9+rax*4]
    addss   xmm4, [r9+rax*4+4]
    addss   xmm5, [r9+rax*4+8]
    inc     ebp
31: inc     ecx
    jmp     3b
4:  cmp     ebp, 2
    jb      .Lmg_few
    cvtsi2ss xmm0, ebp
    divss   xmm3, xmm0
    divss   xmm4, xmm0
    divss   xmm5, xmm0
    lea     rax, [r15+r15*2]
    movss   [r13+rax*4], xmm3
    movss   [r13+rax*4+4], xmm4
    movss   [r13+rax*4+8], xmm5
    lea     r14d, [rbp-1]
    jmp     .Lmg_build

.Lmg_collapse:                          # ---- each connected group of selected
    call    build_adj
    test    eax, eax
    jz      .Lmg_drop
    mov     edi, [rbx+ME_NVERTS]
    call    fa
    test    rax, rax
    jz      .Lmg_drop
    mov     rbp, rax                    # done flags
    mov     edi, [rbx+ME_NVERTS]
    shl     edi, 2
    call    fa
    test    rax, rax
    jz      .Lmg_drop
    mov     [rsp+40], rax               # stack / members
    xor     r15d, r15d                  # seed
5:  cmp     r15d, [rbx+ME_NVERTS]
    jae     .Lmg_cdone
    mov     r8, [rbx+ME_VSEL]
    cmp     byte ptr [r8+r15], 0
    je      59f
    cmp     byte ptr [rbp+r15], 0
    jne     59f
    mov     byte ptr [rbp+r15], 1
    mov     rdi, [rsp+40]
    mov     [rdi], r15d
    mov     dword ptr [rsp], 1          # members
    mov     dword ptr [rsp+4], 0        # cursor
51: mov     eax, [rsp+4]
    cmp     eax, [rsp]
    jae     55f
    mov     rdi, [rsp+40]
    mov     eax, [rdi+rax*4]
    inc     dword ptr [rsp+4]
    mov     r8, [rip+adj_off]
    mov     r9, [rip+adj_nb]
    mov     ecx, [r8+rax*4]
    mov     edx, [r8+rax*4+4]
52: cmp     ecx, edx
    jae     51b
    mov     r10d, [r9+rcx*4]
    mov     r11, [rbx+ME_VSEL]
    cmp     byte ptr [r11+r10], 0
    je      53f
    cmp     byte ptr [rbp+r10], 0
    jne     53f
    mov     byte ptr [rbp+r10], 1
    mov     rdi, [rsp+40]
    mov     eax, [rsp]
    mov     [rdi+rax*4], r10d
    inc     dword ptr [rsp]
53: inc     ecx
    jmp     52b
55: mov     ecx, [rsp]                  # members -> first, at their centroid
    cmp     ecx, 2
    jb      59f
    xorps   xmm3, xmm3
    xorps   xmm4, xmm4
    xorps   xmm5, xmm5
    mov     rdi, [rsp+40]
    mov     r9, [rbx+ME_POS]
    xor     edx, edx
56: cmp     edx, ecx
    jae     57f
    mov     eax, [rdi+rdx*4]
    mov     [r12+rax*4], r15d
    lea     rax, [rax+rax*2]
    addss   xmm3, [r9+rax*4]
    addss   xmm4, [r9+rax*4+4]
    addss   xmm5, [r9+rax*4+8]
    inc     edx
    jmp     56b
57: cvtsi2ss xmm0, ecx
    divss   xmm3, xmm0
    divss   xmm4, xmm0
    divss   xmm5, xmm0
    lea     rax, [r15+r15*2]
    movss   [r13+rax*4], xmm3
    movss   [r13+rax*4+4], xmm4
    movss   [r13+rax*4+8], xmm5
    lea     r14d, [r14+rcx-1]
59: inc     r15d
    jmp     5b
.Lmg_cdone:
    test    r14d, r14d
    jz      .Lmg_few
    jmp     .Lmg_build

.Lmg_distance:                          # ---- closer than the threshold
    movss   xmm0, [rip+mf_dist0]
    call    arg_value
    movss   [rsp+8], xmm0               # threshold
    mov     edi, [rbx+ME_NVERTS]
    mov     esi, -1
    call    fa_fill
    test    rax, rax
    jz      .Lmg_drop
    mov     rbp, rax                    # next in cell chain
    mov     edi, [rbx+ME_NVERTS]
    call    eh_new
    test    rax, rax
    jz      .Lmg_drop
    mov     [rip+cell_tab], rax         # cell -> first vertex
    mov     r8, [rbx+ME_VSEL]           # anything selected? else everything
    xor     ecx, ecx
    xor     eax, eax
60: cmp     ecx, [rbx+ME_NVERTS]
    jae     61f
    or      al, [r8+rcx]
    inc     ecx
    jmp     60b
61: mov     [rsp+12], eax               # 0: all vertices take part
    xor     r15d, r15d
.Lmd_v:
    cmp     r15d, [rbx+ME_NVERTS]
    jae     .Lmd_done
    cmp     dword ptr [rsp+12], 0
    je      62f
    mov     r8, [rbx+ME_VSEL]
    cmp     byte ptr [r8+r15], 0
    je      .Lmd_next
62: mov     r9, [rbx+ME_POS]            # cell coordinates
    lea     rax, [r15+r15*2]
    lea     rax, [r9+rax*4]
    mov     [rsp+56], rax               # &p
    xor     ecx, ecx
63: movss   xmm0, [rax+rcx*4]
    divss   xmm0, [rsp+8]
    roundss xmm0, xmm0, 1
    cvttss2si edx, xmm0
    mov     [rsp+20+rcx*4], edx
    inc     ecx
    cmp     ecx, 3
    jb      63b
    mov     dword ptr [rsp+32], -1      # x offset loop: -1..1 for all three
.Lmd_dx:
    mov     dword ptr [rsp+36], -1
.Lmd_dy:
    mov     dword ptr [rsp+52], -1
.Lmd_dz:
    mov     edi, [rsp+20]
    add     edi, [rsp+32]
    mov     esi, [rsp+24]
    add     esi, [rsp+36]
    mov     edx, [rsp+28]
    add     edx, [rsp+52]
    call    cell_key
    mov     rsi, rax
    call    cell_find                   # eax = first vertex or -1
.Lmd_chain:
    test    eax, eax
    js      .Lmd_cnext
    mov     ecx, eax                    # within the threshold?
    mov     r9, [rbx+ME_POS]
    lea     rax, [rcx+rcx*2]
    lea     rax, [r9+rax*4]
    mov     rdx, [rsp+56]
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
    movss   xmm1, [rsp+8]
    mulss   xmm1, xmm1
    comiss  xmm0, xmm1
    ja      64f
    mov     [r12+r15*4], ecx            # merge into it
    inc     r14d
    jmp     .Lmd_next
64: mov     eax, [rbp+rcx*4]
    jmp     .Lmd_chain
.Lmd_cnext:
    inc     dword ptr [rsp+52]
    cmp     dword ptr [rsp+52], 1
    jle     .Lmd_dz
    inc     dword ptr [rsp+36]
    cmp     dword ptr [rsp+36], 1
    jle     .Lmd_dy
    inc     dword ptr [rsp+32]
    cmp     dword ptr [rsp+32], 1
    jle     .Lmd_dx
    # not merged: becomes a candidate in its cell
    mov     edi, [rsp+20]
    mov     esi, [rsp+24]
    mov     edx, [rsp+28]
    call    cell_key
    mov     rsi, rax
    mov     rdi, [rip+cell_tab]
    call    eh_slot
    mov     ecx, [rax]
    mov     [rbp+r15*4], ecx            # chain: new head
    mov     [rax], r15d
.Lmd_next:
    inc     r15d
    jmp     .Lmd_v
.Lmd_done:
    test    r14d, r14d
    jnz     .Lmg_build
    lea     rdi, [rip+s_merged]         # nothing closer: report 0, no step
    lea     rsi, [rip+s_zero]
    call    log_pair
    call    undo_drop_last
    jmp     9f

.Lmg_build:                             # polygons through T, duplicates out
    mov     edi, [rbx+ME_NVERTS]
    mov     esi, [rbx+ME_NLOOPS]
    mov     edx, [rbx+ME_NPOLYS]
    call    mesh_new
    test    rax, rax
    jz      .Lmg_drop
    mov     r15, rax
    xor     ebp, ebp
7:  cmp     ebp, [rbx+ME_NVERTS]
    jae     8f
    lea     rax, [rbp+rbp*2]
    movss   xmm0, [r13+rax*4]
    movss   xmm1, [r13+rax*4+4]
    movss   xmm2, [r13+rax*4+8]
    mov     rdi, r15
    call    mesh_add_vert
    mov     rcx, [rbx+ME_VSEL]
    mov     dl, [rcx+rbp]
    mov     rcx, [r15+ME_VSEL]
    mov     [rcx+rax], dl
    inc     ebp
    jmp     7b
8:  xor     ebp, ebp
81: cmp     ebp, [rbx+ME_NPOLYS]
    jae     84f
    mov     rsi, [rbx+ME_POFF]
    mov     ecx, [rsi+rbp*4]
    mov     edx, [rsi+rbp*4+4]
    mov     rsi, [rbx+ME_LOOPS]
    lea     rdi, [rip+scr]
    xor     r8d, r8d                    # count
82: cmp     ecx, edx
    jae     83f
    mov     eax, [rsi+rcx*4]
    mov     eax, [r12+rax*4]
    test    r8d, r8d                    # skip repeats of the previous
    jz      821f
    cmp     [rdi+r8*4-4], eax
    je      822f
821:mov     [rdi+r8*4], eax
    inc     r8d
822:inc     ecx
    jmp     82b
83: cmp     r8d, 2                      # and of the first, at the end
    jb      831f
    mov     eax, [rdi]
    cmp     [rdi+r8*4-4], eax
    jne     831f
    dec     r8d
831:cmp     r8d, 3
    jb      832f
    mov     rsi, rdi
    mov     rdi, r15
    mov     edx, r8d
    call    mesh_add_poly
832:inc     ebp
    jmp     81b
84: mov     rdi, r15
    call    mo_commit
    cmp     dword ptr [rsp+48], 2       # by distance: the redo panel's value
    jne     85f
    lea     rdi, [rip+op_m_merge_d]
    lea     rsi, [rsp+8]
    mov     edx, 1
    call    lastop_set
85: call    fmt_reset
    lea     rdi, [rip+s_merged]
    call    fmt_str
    mov     edi, r14d
    call    fmt_int
    lea     rdi, [rip+fmt_buf]
    call    log_line
    jmp     9f
.Lmg_few:
    lea     rdi, [rip+s_f_merge]
    call    mo_fail
    jmp     9f
.Lmg_drop:
    call    undo_drop_last
9:  add     rsp, 72
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# cell_key(edi, esi, edx = cell x y z) -> rax (21 bits each)
cell_key:
    and     edi, 0x1fffff
    and     esi, 0x1fffff
    and     edx, 0x1fffff
    mov     eax, edi
    shl     rax, 21
    or      rax, rsi
    shl     rax, 21
    or      rax, rdx
    ret

# cell_find(rsi=key) -> eax = first vertex in that cell or -1
cell_find:
    mov     rdi, [rip+cell_tab]
    inc     rsi
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

# =============================================================================
#  Dissolve: merge groups of faces across dissolved edges into n-gons
# =============================================================================
do_dissolve:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 56
    call    need_edit
    test    rax, rax
    jz      .Lds_drop
    mov     rbx, rax
    call    edge_faces
    test    eax, eax
    jz      .Lds_drop
    call    sel_polys
    test    rax, rax
    jz      .Lds_drop
    mov     [rsp+40], rax               # selected polygons
    mov     edi, [rbx+ME_NPOLYS]        # union-find parents
    shl     edi, 2
    call    fa
    test    rax, rax
    jz      .Lds_drop
    mov     r12, rax
    xor     ecx, ecx
1:  cmp     ecx, [rbx+ME_NPOLYS]
    jae     2f
    mov     [r12+rcx*4], ecx
    inc     ecx
    jmp     1b
2:  mov     edi, [rip+ef_n]             # dissolved-edge flags per edge slot
    call    fa
    test    rax, rax
    jz      .Lds_drop
    mov     r13, rax
    # walk every polygon edge once more to judge its slot
    xor     r15d, r15d
3:  cmp     r15d, [rbx+ME_NPOLYS]
    jae     .Lds_union
    mov     rsi, [rbx+ME_POFF]
    mov     ecx, [rsi+r15*4]
    mov     edx, [rsi+r15*4+4]
    mov     [rsp], ecx
    mov     [rsp+4], edx
31: cmp     ecx, [rsp+4]
    jae     39f
    mov     [rsp+8], ecx
    mov     rsi, [rbx+ME_LOOPS]
    mov     edi, [rsi+rcx*4]
    lea     eax, [rcx+1]
    cmp     eax, [rsp+4]
    jb      32f
    mov     eax, [rsp]
32: mov     esi, [rsi+rax*4]
    mov     [rsp+12], edi
    mov     [rsp+16], esi
    call    ef_find
    test    eax, eax
    js      38f
    mov     ebp, eax                    # slot
    mov     rcx, [rip+ef_cnt]
    cmp     dword ptr [rcx+rbp*4], 2
    jne     38f
    mov     r8, [rbx+ME_VSEL]
    mov     edi, [rsp+12]
    mov     esi, [rsp+16]
    mov     eax, [rip+sel_mode]
    cmp     eax, 2
    je      34f
    cmp     eax, 1
    je      33f
    mov     al, [r8+rdi]                # vertices: either end selected
    or      al, [r8+rsi]
    jmp     35f
33: mov     al, [r8+rdi]                # edges: both ends
    and     al, [r8+rsi]
    jmp     35f
34: mov     rcx, [rip+ef_f1]            # faces: both neighbours selected
    mov     edx, [rcx+rbp*4]
    mov     rcx, [rip+ef_f2]
    mov     r9d, [rcx+rbp*4]
    mov     rcx, [rsp+40]
    mov     al, [rcx+rdx]
    and     al, [rcx+r9]
35: test    al, al
    jz      38f
    mov     byte ptr [r13+rbp], 1
38: mov     ecx, [rsp+8]
    inc     ecx
    jmp     31b
39: inc     r15d
    jmp     3b
.Lds_union:                             # union the faces of dissolved edges
    xor     ebp, ebp
4:  cmp     ebp, [rip+ef_n]
    jae     5f
    cmp     byte ptr [r13+rbp], 0
    je      41f
    mov     rcx, [rip+ef_f1]
    mov     edi, [rcx+rbp*4]
    call    uf_find
    mov     r14d, eax
    mov     rcx, [rip+ef_f2]
    mov     edi, [rcx+rbp*4]
    call    uf_find
    cmp     eax, r14d
    je      41f
    mov     [r12+rax*4], r14d
41: inc     ebp
    jmp     4b
5:  # group sizes; next-vertex map for boundary walks
    mov     edi, [rbx+ME_NPOLYS]
    shl     edi, 2
    call    fa
    test    rax, rax
    jz      .Lds_drop
    mov     r14, rax                    # size per root
    xor     ecx, ecx
51: cmp     ecx, [rbx+ME_NPOLYS]
    jae     52f
    mov     edi, ecx
    push    rcx
    call    uf_find
    pop     rcx
    mov     [r12+rcx*4], eax            # flatten
    inc     dword ptr [r14+rax*4]
    inc     ecx
    jmp     51b
52: mov     edi, [rbx+ME_NVERTS]
    mov     esi, -1
    call    fa_fill
    test    rax, rax
    jz      .Lds_drop
    mov     [rip+go_next], rax          # next[v] during one group's walk
    mov     [rip+go_mesh], rbx
    xor     ebp, ebp                    # pass A: which groups form one loop
55: cmp     ebp, [rbx+ME_NPOLYS]
    jae     56f
    cmp     [r12+rbp*4], ebp            # roots of real groups only
    jne     551f
    cmp     dword ptr [r14+rbp*4], 1
    jbe     551f
    mov     edi, ebp
    call    group_outline
    test    eax, eax
    jnz     551f
    mov     dword ptr [r14+rbp*4], 1    # not one simple loop: keep its faces
551:inc     ebp
    jmp     55b
56:
    mov     edi, [rbx+ME_NVERTS]
    add     edi, [rbx+ME_NLOOPS]
    mov     esi, [rbx+ME_NLOOPS]
    add     esi, 8
    mov     edx, [rbx+ME_NPOLYS]
    add     edx, 8
    call    mesh_new
    test    rax, rax
    jz      .Lds_drop
    mov     r15, rax
    mov     rdi, r15
    mov     rsi, rbx
    call    copy_verts
    mov     dword ptr [rsp+32], 0       # groups merged
    xor     ebp, ebp
.Lds_poly:
    cmp     ebp, [rbx+ME_NPOLYS]
    jae     .Lds_end
    mov     eax, [r12+rbp*4]            # root
    cmp     dword ptr [r14+rax*4], 1
    jbe     .Lds_single
    cmp     eax, ebp                    # a group is emitted at its root
    jne     .Lds_pnext
    mov     edi, ebp
    call    group_outline               # scr = outline, eax = length
    test    eax, eax
    jz      .Lds_pnext
    mov     rdi, r15
    lea     rsi, [rip+scr]
    mov     edx, eax
    call    mesh_add_poly
    inc     dword ptr [rsp+32]
    jmp     .Lds_pnext
.Lds_single:
    mov     rdi, r15
    mov     rsi, rbx
    mov     edx, ebp
    xor     ecx, ecx
    xor     r8d, r8d
    call    poly_copy
.Lds_pnext:
    inc     ebp
    jmp     .Lds_poly
.Lds_end:
    cmp     dword ptr [rsp+32], 0
    jne     7f
    mov     rdi, r15
    call    mesh_unref
    lea     rdi, [rip+s_f_dissolve]
    call    mo_fail
    jmp     9f
7:  mov     rdi, r15
    call    mo_commit
    jmp     9f
.Lds_drop:
    call    undo_drop_last
9:  add     rsp, 56
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# uf_find(edi) -> eax = root (r12 = parents), with path halving
uf_find:
    mov     eax, edi
1:  mov     ecx, [r12+rax*4]
    cmp     ecx, eax
    je      2f
    mov     edx, [r12+rcx*4]
    mov     [r12+rax*4], edx
    mov     eax, edx
    jmp     1b
2:  ret

# group_outline(edi=root) -> eax = outline length in scr (0 = not one simple
#   loop). Boundary edges of the group, directed as in their faces, chained
#   through go_next[]; r12 = flattened roots, r13 = dissolved-edge flags,
#   go_mesh = the mesh
group_outline:
    push    rbx
    push    rbp
    push    r14
    push    r15
    sub     rsp, 40
    mov     r15d, edi
    mov     r14, [rip+go_next]
    mov     rbx, [rip+go_mesh]
    xor     ebp, ebp                    # boundary edge count
    mov     dword ptr [rsp+24], -1      # a start vertex
    mov     dword ptr [rsp+28], 0       # pinch / failure flag
    xor     ecx, ecx
1:  cmp     ecx, [rbx+ME_NPOLYS]
    jae     .Lgo_walk
    cmp     [r12+rcx*4], r15d
    jne     19f
    mov     [rsp+32], ecx
    mov     rsi, [rbx+ME_POFF]
    mov     edx, [rsi+rcx*4]
    mov     [rsp], edx
    mov     edx, [rsi+rcx*4+4]
    mov     [rsp+4], edx
    mov     edx, [rsp]
11: cmp     edx, [rsp+4]
    jae     18f
    mov     [rsp+8], edx
    mov     rsi, [rbx+ME_LOOPS]
    mov     edi, [rsi+rdx*4]
    lea     eax, [rdx+1]
    cmp     eax, [rsp+4]
    jb      12f
    mov     eax, [rsp]
12: mov     esi, [rsi+rax*4]
    mov     [rsp+12], edi
    mov     [rsp+16], esi
    call    ef_find                     # internal (dissolved) edge? skip it
    test    eax, eax
    js      13f
    cmp     byte ptr [r13+rax], 0
    je      13f
    mov     rcx, [rip+ef_f1]            # dissolved between two group faces
    mov     edx, [rcx+rax*4]
    cmp     [r12+rdx*4], r15d
    jne     13f
    mov     rcx, [rip+ef_f2]
    mov     edx, [rcx+rax*4]
    cmp     [r12+rdx*4], r15d
    je      17f
13: mov     edi, [rsp+12]               # boundary a -> b
    mov     esi, [rsp+16]
    cmp     dword ptr [r14+rdi*4], -1
    je      14f
    mov     dword ptr [rsp+28], 1       # two ways out of a: not simple
14: mov     [r14+rdi*4], esi
    mov     [rsp+24], edi
    inc     ebp
17: mov     edx, [rsp+8]
    inc     edx
    jmp     11b
18: mov     ecx, [rsp+32]
19: inc     ecx
    jmp     1b
.Lgo_walk:
    xor     eax, eax
    cmp     dword ptr [rsp+28], 0
    jne     .Lgo_clear
    mov     edi, [rsp+24]
    test    edi, edi
    js      .Lgo_clear
    cmp     ebp, SCR_MAX
    ja      .Lgo_clear
    lea     rsi, [rip+scr]              # follow next[] from the start
    xor     ecx, ecx
    mov     edx, edi
2:  mov     [rsi+rcx*4], edx
    inc     ecx
    cmp     ecx, ebp
    ja      .Lgo_bad
    mov     edx, [r14+rdx*4]
    test    edx, edx
    js      .Lgo_bad
    cmp     edx, edi
    jne     2b
    cmp     ecx, ebp                    # every boundary edge in one loop
    jne     .Lgo_bad
    cmp     ecx, 3
    jb      .Lgo_bad
    mov     eax, ecx
    jmp     .Lgo_clear
.Lgo_bad:
    xor     eax, eax
.Lgo_clear:                             # reset next[] for the next group
    mov     [rsp+32], eax
    xor     ecx, ecx
3:  cmp     ecx, [rbx+ME_NPOLYS]
    jae     .Lgo_out
    cmp     [r12+rcx*4], r15d
    jne     39f
    mov     rsi, [rbx+ME_POFF]
    mov     edx, [rsi+rcx*4]
    mov     r8d, [rsi+rcx*4+4]
    mov     rsi, [rbx+ME_LOOPS]
31: cmp     edx, r8d
    jae     39f
    mov     eax, [rsi+rdx*4]
    mov     dword ptr [r14+rax*4], -1
    inc     edx
    jmp     31b
39: inc     ecx
    jmp     3b
.Lgo_out:
    mov     eax, [rsp+32]
    add     rsp, 40
    pop     r15
    pop     r14
    pop     rbp
    pop     rbx
    ret

.section .bss
.align 8
go_mesh:        .skip 8
rc_all:         .skip 4
go_next:        .skip 8
cell_tab:       .skip 8
.text

# =============================================================================
#  Fill / make face (F)
# =============================================================================
do_fill:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 72
    call    need_edit
    test    rax, rax
    jz      .Lfi_drop
    mov     rbx, rax
    mov     r8, [rbx+ME_VSEL]           # selected count
    xor     r12d, r12d
    xor     ecx, ecx
1:  cmp     ecx, [rbx+ME_NVERTS]
    jae     2f
    movzx   eax, byte ptr [r8+rcx]
    add     r12d, eax
    inc     ecx
    jmp     1b
2:  cmp     r12d, 3
    jb      .Lfi_few
    cmp     r12d, SCR_MAX/2
    ja      .Lfi_few
    call    edge_faces
    test    eax, eax
    jz      .Lfi_drop
    # 1) a hole: boundary edges between selected vertices, reversed, chained
    mov     edi, [rbx+ME_NVERTS]
    mov     esi, -1
    call    fa_fill
    test    rax, rax
    jz      .Lfi_drop
    mov     r13, rax                    # next[]
    xor     r14d, r14d                  # boundary edges used
    mov     dword ptr [rsp+64], 0       # pinched?
    mov     dword ptr [rsp+68], -1      # start
    xor     r15d, r15d
3:  cmp     r15d, [rbx+ME_NPOLYS]
    jae     .Lfi_walk
    mov     rsi, [rbx+ME_POFF]
    mov     ecx, [rsi+r15*4]
    mov     edx, [rsi+r15*4+4]
    mov     [rsp], ecx
    mov     [rsp+4], edx
31: cmp     ecx, [rsp+4]
    jae     39f
    mov     [rsp+8], ecx
    mov     rsi, [rbx+ME_LOOPS]
    mov     edi, [rsi+rcx*4]
    lea     eax, [rcx+1]
    cmp     eax, [rsp+4]
    jb      32f
    mov     eax, [rsp]
32: mov     esi, [rsi+rax*4]
    mov     r8, [rbx+ME_VSEL]
    mov     al, [r8+rdi]
    and     al, [r8+rsi]
    jz      38f
    mov     [rsp+12], edi
    mov     [rsp+16], esi
    call    ef_find
    test    eax, eax
    js      38f
    mov     rcx, [rip+ef_cnt]
    cmp     dword ptr [rcx+rax*4], 1
    jne     38f
    mov     edi, [rsp+16]               # face a -> b: the fill runs b -> a
    mov     esi, [rsp+12]
    cmp     dword ptr [r13+rdi*4], -1
    je      33f
    mov     dword ptr [rsp+64], 1
33: mov     [r13+rdi*4], esi
    mov     [rsp+68], edi
    inc     r14d
38: mov     ecx, [rsp+8]
    inc     ecx
    jmp     31b
39: inc     r15d
    jmp     3b
.Lfi_walk:
    cmp     dword ptr [rsp+64], 0
    jne     .Lfi_sort
    cmp     r14d, r12d                  # one loop through every selected vertex
    jne     .Lfi_sort
    mov     edi, [rsp+68]
    test    edi, edi
    js      .Lfi_sort
    lea     rsi, [rip+scr]
    xor     ecx, ecx
    mov     edx, edi
4:  mov     [rsi+rcx*4], edx
    inc     ecx
    cmp     ecx, r14d
    ja      .Lfi_sort
    mov     edx, [r13+rdx*4]
    test    edx, edx
    js      .Lfi_sort
    cmp     edx, edi
    jne     4b
    cmp     ecx, r14d
    jne     .Lfi_sort
    mov     ebp, ecx
    jmp     .Lfi_emit
.Lfi_sort:                              # 2) free vertices: order by angle
    lea     rsi, [rip+scr]
    mov     r8, [rbx+ME_VSEL]
    xor     ebp, ebp
    xor     ecx, ecx
5:  cmp     ecx, [rbx+ME_NVERTS]
    jae     6f
    cmp     byte ptr [r8+rcx], 0
    je      51f
    mov     [rsi+rbp*4], ecx
    inc     ebp
51: inc     ecx
    jmp     5b
6:  call    fill_order                  # sorts scr[0..ebp) around the centroid
.Lfi_emit:
    mov     edi, [rbx+ME_NVERTS]
    mov     esi, [rbx+ME_NLOOPS]
    add     esi, ebp
    mov     edx, [rbx+ME_NPOLYS]
    inc     edx
    call    mesh_new
    test    rax, rax
    jz      .Lfi_drop
    mov     r15, rax
    mov     rdi, r15
    mov     rsi, rbx
    call    copy_verts
    lea     rdi, [rip+scr]              # keep the new face for after the copies
    lea     rsi, [rip+scr+SCR_MAX*2]
    mov     ecx, ebp
7:  test    ecx, ecx
    jz      71f
    dec     ecx
    mov     eax, [rdi+rcx*4]
    mov     [rsi+rcx*4], eax
    jmp     7b
71: xor     r14d, r14d
72: cmp     r14d, [rbx+ME_NPOLYS]
    jae     73f
    mov     rdi, r15
    mov     rsi, rbx
    mov     edx, r14d
    xor     ecx, ecx
    xor     r8d, r8d
    call    poly_copy
    inc     r14d
    jmp     72b
73: mov     rdi, r15
    lea     rsi, [rip+scr+SCR_MAX*2]
    mov     edx, ebp
    call    mesh_add_poly
    mov     rdi, r15
    call    mo_commit
    jmp     9f
.Lfi_few:
    lea     rdi, [rip+s_f_fill]
    call    mo_fail
    jmp     9f
.Lfi_drop:
    call    undo_drop_last
9:  add     rsp, 72
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# fill_order(rbx=mesh, scr[0..ebp) = vertices) - sort them by angle around the
#   centroid in their best plane; face the camera
fill_order:
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 104
    mov     r12d, ebp
    mov     r13, [rbx+ME_POS]
    xorps   xmm0, xmm0                  # centroid at [rsp]
    movss   [rsp], xmm0
    movss   [rsp+4], xmm0
    movss   [rsp+8], xmm0
    lea     rsi, [rip+scr]
    xor     ecx, ecx
1:  cmp     ecx, r12d
    jae     2f
    mov     eax, [rsi+rcx*4]
    lea     rax, [rax+rax*2]
    movss   xmm0, [r13+rax*4]
    addss   xmm0, [rsp]
    movss   [rsp], xmm0
    movss   xmm0, [r13+rax*4+4]
    addss   xmm0, [rsp+4]
    movss   [rsp+4], xmm0
    movss   xmm0, [r13+rax*4+8]
    addss   xmm0, [rsp+8]
    movss   [rsp+8], xmm0
    inc     ecx
    jmp     1b
2:  cvtsi2ss xmm1, r12d
    movss   xmm0, [rsp]
    divss   xmm0, xmm1
    movss   [rsp], xmm0
    movss   xmm0, [rsp+4]
    divss   xmm0, xmm1
    movss   [rsp+4], xmm0
    movss   xmm0, [rsp+8]
    divss   xmm0, xmm1
    movss   [rsp+8], xmm0
    # plane normal: Newell over the vertices in index order is unreliable;
    # use the largest cross product of (p_i - c) x (p_j - c) with i = 0
    lea     rsi, [rip+scr]
    mov     eax, [rsi]
    lea     rax, [rax+rax*2]
    xor     ecx, ecx                    # u = p0 - c at [rsp+16]
3:  movss   xmm0, [r13+rax*4]
    subss   xmm0, [rsp+rcx*4]
    movss   [rsp+16+rcx*4], xmm0
    inc     rax
    inc     ecx
    cmp     ecx, 3
    jb      3b
    xorps   xmm0, xmm0
    movss   [rsp+48], xmm0              # best |n|^2
    mov     r14d, 1
4:  cmp     r14d, r12d
    jae     5f
    mov     eax, [rsi+r14*4]
    lea     rax, [rax+rax*2]
    movss   xmm0, [r13+rax*4]           # v = p_i - c
    subss   xmm0, [rsp]
    movss   xmm1, [r13+rax*4+4]
    subss   xmm1, [rsp+4]
    movss   xmm2, [r13+rax*4+8]
    subss   xmm2, [rsp+8]
    movss   xmm3, [rsp+20]              # u x v
    mulss   xmm3, xmm2
    movss   xmm4, [rsp+24]
    mulss   xmm4, xmm1
    subss   xmm3, xmm4
    movss   xmm4, [rsp+24]
    mulss   xmm4, xmm0
    movss   xmm5, [rsp+16]
    mulss   xmm5, xmm2
    subss   xmm4, xmm5
    movss   xmm5, [rsp+16]
    mulss   xmm5, xmm1
    movss   xmm6, [rsp+20]
    mulss   xmm6, xmm0
    subss   xmm5, xmm6
    movss   xmm6, xmm3
    mulss   xmm6, xmm3
    movss   xmm7, xmm4
    mulss   xmm7, xmm4
    addss   xmm6, xmm7
    movss   xmm7, xmm5
    mulss   xmm7, xmm5
    addss   xmm6, xmm7
    comiss  xmm6, [rsp+48]
    jbe     41f
    movss   [rsp+48], xmm6
    movss   [rsp+32], xmm3              # n
    movss   [rsp+36], xmm4
    movss   [rsp+40], xmm5
41: inc     r14d
    jmp     4b
5:  lea     rdi, [rsp+32]
    call    normalize
    lea     rdi, [rsp+16]
    call    normalize
    # w = n x u
    movss   xmm0, [rsp+36]
    mulss   xmm0, [rsp+24]
    movss   xmm1, [rsp+40]
    mulss   xmm1, [rsp+20]
    subss   xmm0, xmm1
    movss   [rsp+52], xmm0
    movss   xmm0, [rsp+40]
    mulss   xmm0, [rsp+16]
    movss   xmm1, [rsp+32]
    mulss   xmm1, [rsp+24]
    subss   xmm0, xmm1
    movss   [rsp+56], xmm0
    movss   xmm0, [rsp+32]
    mulss   xmm0, [rsp+20]
    movss   xmm1, [rsp+36]
    mulss   xmm1, [rsp+16]
    subss   xmm0, xmm1
    movss   [rsp+60], xmm0
    # angle of each vertex -> scr[SCR_MAX/2 + i] (float), insertion sort
    lea     rsi, [rip+scr]
    xor     r14d, r14d
6:  cmp     r14d, r12d
    jae     7f
    mov     eax, [rsi+r14*4]
    lea     rax, [rax+rax*2]
    movss   xmm0, [r13+rax*4]
    subss   xmm0, [rsp]
    movss   xmm1, [r13+rax*4+4]
    subss   xmm1, [rsp+4]
    movss   xmm2, [r13+rax*4+8]
    subss   xmm2, [rsp+8]
    movss   xmm3, xmm0                  # x = d . u
    mulss   xmm3, [rsp+16]
    movss   xmm4, xmm1
    mulss   xmm4, [rsp+20]
    addss   xmm3, xmm4
    movss   xmm4, xmm2
    mulss   xmm4, [rsp+24]
    addss   xmm3, xmm4
    mulss   xmm0, [rsp+52]              # y = d . w
    mulss   xmm1, [rsp+56]
    addss   xmm0, xmm1
    mulss   xmm2, [rsp+60]
    addss   xmm0, xmm2
    movss   [rsp+64], xmm0
    movss   [rsp+68], xmm3
    fld     dword ptr [rsp+64]
    fld     dword ptr [rsp+68]
    fpatan
    fstp    dword ptr [rsp+72]
    mov     eax, [rsp+72]
    lea     ecx, [r14+SCR_MAX/2]
    mov     [rsi+rcx*4], eax
    inc     r14d
    jmp     6b
7:  mov     r14d, 1                     # insertion sort by angle
71: cmp     r14d, r12d
    jae     8f
    lea     ecx, [r14+SCR_MAX/2]
    movss   xmm0, [rsi+rcx*4]           # key angle
    mov     edx, [rsi+r14*4]            # key vertex
    mov     r15d, r14d
72: test    r15d, r15d
    jz      73f
    lea     ecx, [r15+SCR_MAX/2-1]
    comiss  xmm0, [rsi+rcx*4]
    jae     73f
    mov     eax, [rsi+rcx*4]
    mov     [rsi+rcx*4+4], eax
    mov     eax, [rsi+r15*4-4]
    mov     [rsi+r15*4], eax
    dec     r15d
    jmp     72b
73: lea     ecx, [r15+SCR_MAX/2]
    movss   [rsi+rcx*4], xmm0
    mov     [rsi+r15*4], edx
    inc     r14d
    jmp     71b
8:  # face the viewer: if n points away from the camera, reverse
    call    edit_get
    test    rax, rax
    jz      9f
    lea     rdi, [rsp+32]
    call    world_dir                   # n (world)
    movss   xmm0, [rsp+32]              # facing: n . fwd < 0
    mulss   xmm0, [rip+fwd]
    movss   xmm1, [rsp+36]
    mulss   xmm1, [rip+fwd+4]
    addss   xmm0, xmm1
    movss   xmm1, [rsp+40]
    mulss   xmm1, [rip+fwd+8]
    addss   xmm0, xmm1
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    jbe     9f
    lea     rsi, [rip+scr]
    xor     ecx, ecx
    lea     edx, [r12-1]
81: cmp     ecx, edx
    jge     9f
    mov     eax, [rsi+rcx*4]
    mov     r8d, [rsi+rdx*4]
    mov     [rsi+rcx*4], r8d
    mov     [rsi+rdx*4], eax
    inc     ecx
    dec     edx
    jmp     81b
9:  add     rsp, 104
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    ret

.section .rodata
s_zero:         .asciz "0"

.section .note.GNU-stack,"",@progbits
