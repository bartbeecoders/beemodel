# =============================================================================
#  BeeModel - edit mode: the components of one mesh object.
#
#  Selection lives in the mesh (one byte per vertex, ME_VSEL); an edge or a
#  face counts as selected when all its vertices are. Geometry is never
#  edited in place while an undo step still shares the mesh: edit_cow copies
#  it first, so undo snapshots keep the old version for free.
#
#  Overlays are depth tested against the rasterizer's 1/z buffer, so hidden
#  vertices and edges are neither drawn nor picked (wireframe = x-ray).
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

# exports
.globl edit_obj
.globl edit_get
.globl edit_cow
.globl edit_exit
.globl edit_prepare
.globl edit_draw
.globl edit_click
.globl edit_psel
.globl edit_ro_obj
.globl box_armed
.globl box_on
.globl box_begin
.globl box_move
.globl box_finish
.globl edit_tm_snapshot
.globl edit_tm_restore
.globl edit_tm_grab
.globl edit_tm_rotate
.globl edit_tm_scale
.globl edit_tm_end
.globl edit_median
.globl sel_mode
.globl do_sel_all
.globl ex_setup
.globl ex_to_world
.globl ex_to_local
.globl edit_pick_edge
.globl edit_pick_vertex
.globl visible
.globl pv
.globl need_edit
.globl poly_sel
.globl build_adj
.globl adj_off
.globl adj_nb
.globl project_all
.globl proj_local
.globl dline
.globl dot

.equ KEY_TAB,   15
.equ KEY_1,     2
.equ KEY_2,     3
.equ KEY_3,     4
.equ KEY_B,     48
.equ KEY_I,     23
.equ EV_SZ,     32              # transform entry: index, world[3], local[3]
.equ PICK_PX,   14              # pick radius (physical px)

.section .bss
.align 8
edit_psel:      .skip 8             # per-frame: polygon selected flags
edit_ro_obj:    .skip 8             # the edit object (for the rasterizer)
pv:             .skip 8             # projected vertices: x, y, 1/z (0 = behind)
ev_buf:         .skip 8             # transform snapshot (mmap, grows)
ev_cap:         .skip 8
adj_off:        .skip 8             # vertex -> neighbours (CSR, frame arena)
adj_nb:         .skip 8
vp_off:         .skip 8             # vertex -> polygons (CSR)
vp_pl:          .skip 8
mtx:            .skip 48            # object matrix (3x4)
minv:           .skip 36            # inverse of its 3x3 part
cmat:           .skip 48            # view * model
edit_obj:       .skip 4
sel_mode:       .skip 4             # 0 vertex, 1 edge, 2 face
box_armed:      .skip 4
box_on:         .skip 4
box_x0:         .skip 4             # logical
box_y0:         .skip 4
box_x1:         .skip 4
box_y1:         .skip 4
ev_n:           .skip 4
.align 8
ev_pos:         .skip 8             # positions of the mesh being transformed
pick_x:         .skip 4             # physical float
pick_y:         .skip 4

.section .rodata
.align 4
ef_one:         .float 1.0
ef_tol:         .float 1.01         # depth tolerance (vertices sit on the surface)
ef_big:         .float 1.0e30
ef_eps:         .float 1.0e-12
ef_pick2:       .float 196.0        # PICK_PX^2
ef_edge2:       .float 144.0
ef_half:        .float 0.5
s_lbl_v:        .asciz "Edit Mode  |  Vertex  (1 2 3, A all, B box, Alt+click loop, Ctrl+L linked, Tab exit)"
s_lbl_e:        .asciz "Edit Mode  |  Edge  (1 2 3, A all, B box, Alt+click loop, Ctrl+L linked, Tab exit)"
s_lbl_f:        .asciz "Edit Mode  |  Face  (1 2 3, A all, B box, Alt+click loop, Ctrl+L linked, Tab exit)"
lbl_ptrs:       .quad s_lbl_v, s_lbl_e, s_lbl_f
s_not_mesh:     .asciz "  edit mode needs an active mesh object"
s_not_edit:     .asciz "  not in edit mode (Tab)"
s_box:          .asciz "  box select: drag in the viewport (Ctrl subtracts)"

OPERATOR op_edit_toggle, "mode.toggle_edit", "Edit Mode", do_toggle, chk_edit, key=KEY_TAB, doc="Switch the active mesh between object mode and edit mode"
OPERATOR op_selmode_v, "mesh.select_mode_vertex", "Vertex Select Mode", set_selmode, chk_selmode, 0, KEY_1, OPF_AI_SAFE|OPF_QUIET, doc="Edit mode: pick vertices"
OPERATOR op_selmode_e, "mesh.select_mode_edge", "Edge Select Mode", set_selmode, chk_selmode, 1, KEY_2, OPF_AI_SAFE|OPF_QUIET, doc="Edit mode: pick edges"
OPERATOR op_selmode_f, "mesh.select_mode_face", "Face Select Mode", set_selmode, chk_selmode, 2, KEY_3, OPF_AI_SAFE|OPF_QUIET, doc="Edit mode: pick faces"
OPERATOR op_mesh_all, "mesh.select_all", "Select All / None (Mesh)", do_sel_all, key=KEY_A, flags=OPF_AI_SAFE|OPF_QUIET|OPF_EDIT, doc="Edit mode: select every vertex, or none if some are selected"
OPERATOR op_mesh_inv, "mesh.select_invert", "Invert Selection", do_sel_invert, key=KEY_I|KM_CTRL, flags=OPF_AI_SAFE|OPF_QUIET, doc="Edit mode: invert the vertex selection"
OPERATOR op_mesh_linked, "mesh.select_linked", "Select Linked", do_sel_linked, key=KEY_L|KM_CTRL, flags=OPF_AI_SAFE|OPF_QUIET, doc="Edit mode: grow the selection over every connected part"
OPERATOR op_mesh_box, "mesh.select_box", "Box Select", do_box_arm, key=KEY_B, flags=OPF_QUIET, doc="Edit mode: drag a rectangle to select (Ctrl subtracts)"

.text

# -----------------------------------------------------------------------------
# State
# -----------------------------------------------------------------------------
# edit_get -> rax = the object in edit mode (0 = object mode). Leaves edit
#   mode by itself when the object went away (undo, file.new, delete).
edit_get:
    mov     edi, [rip+edit_obj]
    test    edi, edi
    jz      2f
    sub     rsp, 8
    call    obj_get
    add     rsp, 8
    test    rax, rax
    jz      1f
    cmp     dword ptr [rax+OB_TYPE], OT_MESH
    jne     1f
    ret
1:  mov     dword ptr [rip+edit_obj], 0
2:  xor     eax, eax
    ret

edit_exit:
    mov     dword ptr [rip+edit_obj], 0
    mov     dword ptr [rip+box_armed], 0
    mov     dword ptr [rip+box_on], 0
    mov     dword ptr [rip+dirty], 1
    ret

# edit_cow -> rax = the edit object's mesh, unshared (copied if an undo step
#   or another object still uses it); 0 when not in edit mode
edit_cow:
    push    rbx
    call    edit_get
    test    rax, rax
    jz      9f
    mov     rbx, rax
    mov     rdi, [rbx+OB_MESH]
    cmp     dword ptr [rdi+ME_REFS], 1
    jbe     8f
    call    mesh_copy
    test    rax, rax
    jz      8f
    mov     rdi, [rbx+OB_MESH]
    mov     [rbx+OB_MESH], rax
    call    mesh_unref
8:  mov     rax, [rbx+OB_MESH]
9:  pop     rbx
    ret

do_toggle:
    sub     rsp, 8
    cmp     dword ptr [rip+edit_obj], 0
    je      1f
    call    edit_exit
    add     rsp, 8
    ret
1:  mov     edi, [rip+active_obj]
    test    edi, edi
    jz      2f
    call    obj_get
    test    rax, rax
    jz      2f
    cmp     dword ptr [rax+OB_TYPE], OT_MESH
    jne     2f
    mov     eax, [rip+active_obj]
    mov     [rip+edit_obj], eax
    mov     dword ptr [rip+dirty], 1
    add     rsp, 8
    ret
2:  lea     rdi, [rip+s_not_mesh]
    call    log_line
    add     rsp, 8
    ret
chk_edit:
    xor     eax, eax
    cmp     dword ptr [rip+edit_obj], 0
    setne   al
    ret

set_selmode:
    mov     [rip+sel_mode], edi
    mov     dword ptr [rip+dirty], 1
    ret
chk_selmode:
    xor     eax, eax
    cmp     [rip+sel_mode], edi
    sete    al
    ret

# need_edit -> rax = mesh, or logs "not in edit mode" and returns 0
need_edit:
    sub     rsp, 8
    call    edit_get
    test    rax, rax
    jz      1f
    mov     rax, [rax+OB_MESH]
    add     rsp, 8
    ret
1:  lea     rdi, [rip+s_not_edit]
    call    log_line
    xor     eax, eax
    add     rsp, 8
    ret

# -----------------------------------------------------------------------------
# Selection operators
# -----------------------------------------------------------------------------
do_sel_all:
    sub     rsp, 8
    call    need_edit
    test    rax, rax
    jz      9f
    mov     rdi, [rax+ME_VSEL]
    mov     ecx, [rax+ME_NVERTS]
    xor     edx, edx                    # any selected -> clear, else set all
    xor     r8d, r8d
1:  cmp     r8d, ecx
    jae     2f
    or      dl, [rdi+r8]
    inc     r8d
    jmp     1b
2:  xor     eax, eax
    test    dl, dl
    jnz     3f
    mov     eax, 1
3:  rep     stosb
    mov     dword ptr [rip+dirty], 1
9:  add     rsp, 8
    ret

do_sel_invert:
    sub     rsp, 8
    call    need_edit
    test    rax, rax
    jz      9f
    mov     rdi, [rax+ME_VSEL]
    mov     ecx, [rax+ME_NVERTS]
1:  test    ecx, ecx
    jz      2f
    xor     byte ptr [rdi], 1
    inc     rdi
    dec     ecx
    jmp     1b
2:  mov     dword ptr [rip+dirty], 1
9:  add     rsp, 8
    ret

do_sel_linked:
    push    rbx
    call    need_edit
    test    rax, rax
    jz      9f
    mov     rbx, rax
    call    build_adj
    test    eax, eax
    jz      9f
    mov     rdi, rbx
    call    flood
    mov     dword ptr [rip+dirty], 1
9:  pop     rbx
    ret

do_box_arm:
    sub     rsp, 8
    call    need_edit
    test    rax, rax
    jz      9f
    mov     dword ptr [rip+box_armed], 1
    lea     rdi, [rip+s_box]
    call    log_line
9:  add     rsp, 8
    ret

# -----------------------------------------------------------------------------
# Adjacency (frame arena, rebuilt when needed)
# -----------------------------------------------------------------------------
# build_adj(rbx=mesh) -> eax = 1 ok. adj_off/adj_nb: neighbours over edges;
#   vp_off/vp_pl: polygons around each vertex
build_adj:
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    mov     r12d, [rbx+ME_NVERTS]
    lea     rdi, [rip+frame_arena]      # offsets: two arrays of n+1
    lea     esi, [r12*4+4]
    call    arena_alloc
    test    rax, rax
    jz      .Lba_fail
    mov     [rip+adj_off], rax
    lea     rdi, [rip+frame_arena]
    lea     esi, [r12*4+4]
    call    arena_alloc
    test    rax, rax
    jz      .Lba_fail
    mov     [rip+vp_off], rax
    lea     rdi, [rip+frame_arena]
    mov     esi, [rbx+ME_NEDGES]
    shl     esi, 3
    add     esi, 8
    call    arena_alloc
    test    rax, rax
    jz      .Lba_fail
    mov     [rip+adj_nb], rax
    lea     rdi, [rip+frame_arena]
    mov     esi, [rbx+ME_NLOOPS]
    shl     esi, 2
    add     esi, 8
    call    arena_alloc
    test    rax, rax
    jz      .Lba_fail
    mov     [rip+vp_pl], rax
    # counts
    mov     rdi, [rip+adj_off]
    lea     ecx, [r12+1]
    xor     eax, eax
    rep     stosd
    mov     rdi, [rip+vp_off]
    lea     ecx, [r12+1]
    rep     stosd
    mov     r13, [rip+adj_off]
    mov     rsi, [rbx+ME_EDGES]
    mov     ecx, [rbx+ME_NEDGES]
1:  test    ecx, ecx
    jz      2f
    mov     eax, [rsi]
    inc     dword ptr [r13+rax*4+4]
    mov     eax, [rsi+4]
    inc     dword ptr [r13+rax*4+4]
    add     rsi, 8
    dec     ecx
    jmp     1b
2:  mov     r14, [rip+vp_off]
    mov     rsi, [rbx+ME_LOOPS]
    mov     ecx, [rbx+ME_NLOOPS]
3:  test    ecx, ecx
    jz      4f
    mov     eax, [rsi]
    inc     dword ptr [r14+rax*4+4]
    add     rsi, 4
    dec     ecx
    jmp     3b
4:  xor     ecx, ecx                    # prefix sums
    xor     eax, eax
    xor     edx, edx
5:  cmp     ecx, r12d
    jae     6f
    add     eax, [r13+rcx*4+4]
    mov     [r13+rcx*4+4], eax
    add     edx, [r14+rcx*4+4]
    mov     [r14+rcx*4+4], edx
    inc     ecx
    jmp     5b
6:  # fill, using the offsets as cursors, then shift them back
    mov     rsi, [rbx+ME_EDGES]
    mov     r15, [rip+adj_nb]
    xor     ecx, ecx
7:  cmp     ecx, [rbx+ME_NEDGES]
    jae     8f
    mov     eax, [rsi+rcx*8]
    mov     edx, [rsi+rcx*8+4]
    mov     r8d, [r13+rax*4]
    mov     [r15+r8*4], edx
    inc     dword ptr [r13+rax*4]
    mov     r8d, [r13+rdx*4]
    mov     [r15+r8*4], eax
    inc     dword ptr [r13+rdx*4]
    inc     ecx
    jmp     7b
8:  mov     r15, [rip+vp_pl]            # polygons per vertex
    mov     rsi, [rbx+ME_POFF]
    mov     r8, [rbx+ME_LOOPS]
    xor     ecx, ecx
9:  cmp     ecx, [rbx+ME_NPOLYS]
    jae     11f
    mov     r9d, [rsi+rcx*4]
    mov     r10d, [rsi+rcx*4+4]
10: cmp     r9d, r10d
    jae     91f
    mov     eax, [r8+r9*4]
    mov     edx, [r14+rax*4]
    mov     [r15+rdx*4], ecx
    inc     dword ptr [r14+rax*4]
    inc     r9d
    jmp     10b
91: inc     ecx
    jmp     9b
11: mov     ecx, r12d                   # cursors now hold the ends: shift
12: test    ecx, ecx
    jz      13f
    mov     eax, [r13+rcx*4-4]
    mov     [r13+rcx*4], eax
    mov     eax, [r14+rcx*4-4]
    mov     [r14+rcx*4], eax
    dec     ecx
    jmp     12b
13: mov     dword ptr [r13], 0
    mov     dword ptr [r14], 0
    mov     eax, 1
    jmp     .Lba_out
.Lba_fail:
    xor     eax, eax
.Lba_out:
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    ret

# flood(rdi=mesh) - every vertex connected to a selected one gets selected
#   (iterative: a stack in the frame arena)
flood:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     rbx, rdi
    lea     rdi, [rip+frame_arena]
    mov     esi, [rbx+ME_NVERTS]
    shl     esi, 2
    add     esi, 4
    call    arena_alloc
    test    rax, rax
    jz      9f
    mov     r12, rax                    # stack
    xor     r13d, r13d                  # depth
    mov     rdx, [rbx+ME_VSEL]
    xor     ecx, ecx
1:  cmp     ecx, [rbx+ME_NVERTS]
    jae     2f
    cmp     byte ptr [rdx+rcx], 0
    je      11f
    mov     [r12+r13*4], ecx
    inc     r13d
11: inc     ecx
    jmp     1b
2:  test    r13d, r13d
    jz      9f
    dec     r13d
    mov     eax, [r12+r13*4]
    mov     r8, [rip+adj_off]
    mov     r9, [rip+adj_nb]
    mov     ecx, [r8+rax*4]
    mov     r10d, [r8+rax*4+4]
3:  cmp     ecx, r10d
    jae     2b
    mov     r11d, [r9+rcx*4]
    cmp     byte ptr [rdx+r11], 0
    jne     4f
    mov     byte ptr [rdx+r11], 1
    mov     [r12+r13*4], r11d
    inc     r13d
4:  inc     ecx
    jmp     3b
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# loop_walk(rbx=mesh, edi=u, esi=v, rdx=mark bytes) - follow an edge loop
#   through 4-valent vertices: the next edge is the one at v that shares no
#   polygon with (u, v). Marks the vertices it reaches.
loop_walk:
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    mov     r12d, edi                   # u
    mov     r13d, esi                   # v
    mov     r14, rdx
    mov     ebp, [rbx+ME_NVERTS]        # step guard
.Llw_step:
    dec     ebp
    js      .Llw_out
    mov     byte ptr [r14+r13], 1
    mov     r8, [rip+adj_off]
    mov     eax, [r8+r13*4+4]
    sub     eax, [r8+r13*4]
    cmp     eax, 4                      # only through 4-valent vertices
    jne     .Llw_out
    # candidates: neighbours w of v, w != u, not "beside" (u, v) in a polygon
    mov     r9, [rip+adj_nb]
    mov     ecx, [r8+r13*4]
    mov     r10d, [r8+r13*4+4]
    mov     r15d, -1                    # the next vertex
.Llw_cand:
    cmp     ecx, r10d
    jae     .Llw_have
    mov     r11d, [r9+rcx*4]            # w
    cmp     r11d, r12d
    je      .Llw_skip
    push    rcx
    push    r10
    push    r11
    mov     edi, r11d
    call    beside                      # eax = 1 if (v, w) shares a polygon with (u, v)
    pop     r11
    pop     r10
    pop     rcx
    mov     r9, [rip+adj_nb]
    mov     r8, [rip+adj_off]
    test    eax, eax
    jnz     .Llw_skip
    cmp     r15d, -1                    # more than one candidate: stop
    jne     .Llw_out
    mov     r15d, r11d
.Llw_skip:
    inc     ecx
    jmp     .Llw_cand
.Llw_have:
    cmp     r15d, -1
    je      .Llw_out
    cmp     byte ptr [r14+r15], 0       # closed loop
    jne     .Llw_out
    mov     r12d, r13d
    mov     r13d, r15d
    jmp     .Llw_step
.Llw_out:
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    ret

# beside(r12d=u, r13d=v, edi=w) -> eax = 1 if some polygon has u and w as the
#   two neighbours of v
beside:
    push    rbx
    mov     r8, [rip+vp_off]
    mov     r9, [rip+vp_pl]
    mov     ecx, [r8+r13*4]
    mov     r10d, [r8+r13*4+4]
1:  cmp     ecx, r10d
    jae     8f
    mov     eax, [r9+rcx*4]             # polygon p
    mov     rsi, [rbx+ME_POFF]
    mov     r11d, [rsi+rax*4]           # loops [r11, rdx)
    mov     edx, [rsi+rax*4+4]
    mov     rsi, [rbx+ME_LOOPS]
    mov     eax, r11d                   # find v
2:  cmp     eax, edx
    jae     7f
    cmp     [rsi+rax*4], r13d
    je      3f
    inc     eax
    jmp     2b
3:  push    rax                         # prev and next of v (wrapping)
    dec     eax
    cmp     eax, r11d
    jge     4f
    lea     eax, [rdx-1]
4:  mov     ebx, [rsi+rax*4]            # prev
    pop     rax
    inc     eax
    cmp     eax, edx
    jb      5f
    mov     eax, r11d
5:  mov     eax, [rsi+rax*4]            # next
    cmp     ebx, r12d
    jne     6f
    cmp     eax, edi
    je      9f
6:  cmp     eax, r12d
    jne     7f
    cmp     ebx, edi
    je      9f
7:  mov     rbx, [rsp]                  # restore the mesh pointer
    inc     ecx
    jmp     1b
8:  xor     eax, eax
    pop     rbx
    ret
9:  mov     eax, 1
    pop     rbx
    ret

# -----------------------------------------------------------------------------
# Projection: every vertex of the edit object to screen (physical) + 1/z
# -----------------------------------------------------------------------------
# project_all(rbx=object) -> rax = pv (frame arena) or 0; needs cam_setup
project_all:
    push    r12
    push    r13
    push    r14
    sub     rsp, 64
    mov     rdi, rbx
    lea     rsi, [rip+mtx]
    call    obj_matrix
    # C = [right; up; fwd] * M, translation relative to the eye
    xor     ecx, ecx
1:  lea     rax, [rip+right]
    cmp     ecx, 1
    jne     11f
    lea     rax, [rip+up]
11: cmp     ecx, 2
    jne     12f
    lea     rax, [rip+fwd]
12: lea     rdx, [rip+mtx]
    imul    r8, rcx, 16
    lea     r9, [rip+cmat]
    add     r8, r9
    xor     r9d, r9d
2:  movss   xmm0, [rax]
    mulss   xmm0, [rdx+r9*4]
    movss   xmm1, [rax+4]
    mulss   xmm1, [rdx+16+r9*4]
    addss   xmm0, xmm1
    movss   xmm1, [rax+8]
    mulss   xmm1, [rdx+32+r9*4]
    addss   xmm0, xmm1
    movss   [r8+r9*4], xmm0
    inc     r9d
    cmp     r9d, 3
    jb      2b
    movss   xmm0, [rdx+12]
    subss   xmm0, [rip+eye]
    mulss   xmm0, [rax]
    movss   xmm1, [rdx+28]
    subss   xmm1, [rip+eye+4]
    mulss   xmm1, [rax+4]
    addss   xmm0, xmm1
    movss   xmm1, [rdx+44]
    subss   xmm1, [rip+eye+8]
    mulss   xmm1, [rax+8]
    addss   xmm0, xmm1
    movss   [r8+12], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      1b
    mov     r12, [rbx+OB_MESH]
    mov     r13d, [r12+ME_NVERTS]
    lea     rdi, [rip+frame_arena]
    imul    esi, r13d, 12
    add     esi, 12
    call    arena_alloc
    test    rax, rax
    jz      9f
    mov     r14, rax
    mov     rsi, [r12+ME_POS]
    mov     rdi, r14
    lea     r8, [rip+cmat]
3:  test    r13d, r13d
    jz      8f
    movss   xmm3, [rsi]
    movss   xmm4, [rsi+4]
    movss   xmm5, [rsi+8]
    movss   xmm0, [r8+32]               # z
    mulss   xmm0, xmm3
    movss   xmm1, [r8+36]
    mulss   xmm1, xmm4
    addss   xmm0, xmm1
    movss   xmm1, [r8+40]
    mulss   xmm1, xmm5
    addss   xmm0, xmm1
    addss   xmm0, [r8+44]
    comiss  xmm0, [rip+f_near]
    jae     4f
    xorps   xmm0, xmm0                  # behind the camera
    movss   [rdi], xmm0
    movss   [rdi+4], xmm0
    movss   [rdi+8], xmm0
    jmp     5f
4:  movss   xmm6, [rip+ef_one]
    divss   xmm6, xmm0                  # 1/z
    movss   [rdi+8], xmm6
    mulss   xmm6, [rip+vp_focal]
    movss   xmm0, [r8]                  # x
    mulss   xmm0, xmm3
    movss   xmm1, [r8+4]
    mulss   xmm1, xmm4
    addss   xmm0, xmm1
    movss   xmm1, [r8+8]
    mulss   xmm1, xmm5
    addss   xmm0, xmm1
    addss   xmm0, [r8+12]
    mulss   xmm0, xmm6
    addss   xmm0, [rip+vp_cx]
    movss   [rdi], xmm0
    movss   xmm0, [r8+16]               # y
    mulss   xmm0, xmm3
    movss   xmm1, [r8+20]
    mulss   xmm1, xmm4
    addss   xmm0, xmm1
    movss   xmm1, [r8+24]
    mulss   xmm1, xmm5
    addss   xmm0, xmm1
    addss   xmm0, [r8+28]
    mulss   xmm0, xmm6
    movss   xmm1, [rip+vp_cy]
    subss   xmm1, xmm0
    movss   [rdi+4], xmm1
5:  add     rsi, 12
    add     rdi, 12
    dec     r13d
    jmp     3b
8:  mov     rax, r14
    mov     [rip+pv], rax
9:  add     rsp, 64
    pop     r14
    pop     r13
    pop     r12
    ret

# proj_local(xmm0..2 = an object-space point) -> xmm0, xmm1 = screen x, y,
#   xmm2 = 1/z (0 behind the camera); after project_all for that object
proj_local:
    lea     r8, [rip+cmat]
    movss   xmm3, xmm0
    movss   xmm4, xmm1
    movss   xmm5, xmm2
    movss   xmm0, [r8+32]               # z
    mulss   xmm0, xmm3
    movss   xmm1, [r8+36]
    mulss   xmm1, xmm4
    addss   xmm0, xmm1
    movss   xmm1, [r8+40]
    mulss   xmm1, xmm5
    addss   xmm0, xmm1
    addss   xmm0, [r8+44]
    comiss  xmm0, [rip+f_near]
    jae     1f
    xorps   xmm0, xmm0
    xorps   xmm1, xmm1
    xorps   xmm2, xmm2
    ret
1:  movss   xmm6, [rip+ef_one]
    divss   xmm6, xmm0                  # 1/z
    movss   xmm7, xmm6
    mulss   xmm7, [rip+vp_focal]
    movss   xmm0, [r8]                  # x
    mulss   xmm0, xmm3
    movss   xmm1, [r8+4]
    mulss   xmm1, xmm4
    addss   xmm0, xmm1
    movss   xmm1, [r8+8]
    mulss   xmm1, xmm5
    addss   xmm0, xmm1
    addss   xmm0, [r8+12]
    mulss   xmm0, xmm7
    addss   xmm0, [rip+vp_cx]
    movss   xmm1, [r8+16]               # y
    mulss   xmm1, xmm3
    movss   xmm2, [r8+20]
    mulss   xmm2, xmm4
    addss   xmm1, xmm2
    movss   xmm2, [r8+24]
    mulss   xmm2, xmm5
    addss   xmm1, xmm2
    addss   xmm1, [r8+28]
    mulss   xmm1, xmm7
    movss   xmm2, [rip+vp_cy]
    subss   xmm2, xmm1
    movss   xmm1, xmm2
    movss   xmm2, xmm6
    ret

# visible(xmm0=x, xmm1=y, xmm2=1/z) -> eax = 1 if not hidden by a surface
#   (wireframe shading: everything is visible)
visible:
    xor     eax, eax
    xorps   xmm3, xmm3
    comiss  xmm2, xmm3
    jbe     9f
    mov     eax, 1
    cmp     dword ptr [rip+vp_shading], 1   # wireframe: all visible
    je      9f
    cvttss2si ecx, xmm0
    cvttss2si edx, xmm1
    sub     ecx, [rip+rs_x0]
    js      8f
    cmp     ecx, [rip+rs_w]
    jge     8f
    sub     edx, [rip+rs_y0]
    js      8f
    cmp     edx, [rip+rs_h]
    jge     8f
    imul    edx, [rip+rs_w]
    add     edx, ecx
    mov     rcx, [rip+rs_depth]
    mulss   xmm2, [rip+ef_tol]
    comiss  xmm2, [rcx+rdx*4]           # in front of (or on) the surface?
    jae     9f
8:  xor     eax, eax
9:  ret

# -----------------------------------------------------------------------------
# Drawing
# -----------------------------------------------------------------------------
# edit_prepare - before rasterizing: which polygons show as selected
edit_prepare:
    push    rbx
    push    r12
    push    r13
    mov     qword ptr [rip+edit_ro_obj], 0
    call    edit_get
    test    rax, rax
    jz      9f
    mov     rbx, rax
    mov     rdi, rbx                    # modifiers change the triangles:
    call    mods_on                     # no face tint then
    test    eax, eax
    jnz     9f
    mov     r12, [rbx+OB_MESH]
    lea     rdi, [rip+frame_arena]
    mov     esi, [r12+ME_NPOLYS]
    add     esi, 8
    call    arena_alloc
    test    rax, rax
    jz      9f
    mov     [rip+edit_psel], rax
    mov     rdi, r12
    mov     rsi, rax
    call    poly_sel
    mov     [rip+edit_ro_obj], rbx
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# poly_sel(rdi=mesh, rsi=out bytes) - polygon selected = all its vertices are
poly_sel:
    mov     r8, [rdi+ME_POFF]
    mov     r9, [rdi+ME_LOOPS]
    mov     r10, [rdi+ME_VSEL]
    xor     ecx, ecx
1:  cmp     ecx, [rdi+ME_NPOLYS]
    jae     9f
    mov     edx, [r8+rcx*4]
    mov     r11d, [r8+rcx*4+4]
    mov     al, 1
2:  cmp     edx, r11d
    jae     3f
    push    rdx
    mov     edx, [r9+rdx*4]
    and     al, [r10+rdx]
    pop     rdx
    inc     edx
    jmp     2b
3:  mov     [rsi+rcx], al
    inc     ecx
    jmp     1b
9:  ret

# dline(rdi=pv a, rsi=pv b, edx=colour) - depth-tested line in physical px
dline:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 32
    mov     r12d, edx
    movss   xmm0, [rdi]
    movss   [rsp], xmm0                 # x0 y0 w0
    movss   xmm0, [rdi+4]
    movss   [rsp+4], xmm0
    movss   xmm0, [rdi+8]
    movss   [rsp+8], xmm0
    movss   xmm0, [rsi]                 # dx dy dw
    subss   xmm0, [rsp]
    movss   [rsp+12], xmm0
    movss   xmm0, [rsi+4]
    subss   xmm0, [rsp+4]
    movss   [rsp+16], xmm0
    movss   xmm0, [rsi+8]
    subss   xmm0, [rsp+8]
    movss   [rsp+20], xmm0
    movss   xmm0, [rsp+12]              # steps = max(|dx|, |dy|)
    andps   xmm0, [rip+ef_absmask]
    movss   xmm1, [rsp+16]
    andps   xmm1, [rip+ef_absmask]
    maxss   xmm0, xmm1
    cvttss2si ebx, xmm0
    inc     ebx
    cmp     ebx, 8192                   # absurdly long (near the camera): clip
    jbe     1f
    mov     ebx, 8192
1:  cvtsi2ss xmm7, ebx
    movss   xmm0, [rip+ef_one]
    divss   xmm0, xmm7
    movss   [rsp+24], xmm0              # 1 / steps
    xor     r13d, r13d
2:  cmp     r13d, ebx
    ja      9f
    cvtsi2ss xmm6, r13d
    mulss   xmm6, [rsp+24]              # t
    movss   xmm0, [rsp+12]
    mulss   xmm0, xmm6
    addss   xmm0, [rsp]
    movss   xmm1, [rsp+16]
    mulss   xmm1, xmm6
    addss   xmm1, [rsp+4]
    movss   xmm2, [rsp+20]
    mulss   xmm2, xmm6
    addss   xmm2, [rsp+8]
    cvttss2si r14d, xmm0
    cvttss2si r15d, xmm1
    call    visible
    test    eax, eax
    jz      3f
    mov     edi, r14d
    mov     esi, r15d
    mov     edx, r12d
    call    put_px
3:  inc     r13d
    jmp     2b
9:  add     rsp, 32
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# put_px(edi=x, esi=y physical, edx=colour) - clipped
put_px:
    cmp     edi, [rip+clip_x0]
    jl      9f
    cmp     edi, [rip+clip_x1]
    jge     9f
    cmp     esi, [rip+clip_y0]
    jl      9f
    cmp     esi, [rip+clip_y1]
    jge     9f
    mov     eax, esi
    imul    eax, [rip+fb_w]
    add     eax, edi
    mov     rcx, [rip+fb_ptr]
    mov     [rcx+rax*4], edx
9:  ret

# dot(xmm0=x, xmm1=y, edx=colour, ecx=size) - a square centred on the point
dot:
    push    rbx
    push    r12
    push    r13
    mov     r12d, edx
    mov     r13d, ecx
    cvttss2si edi, xmm0
    cvttss2si esi, xmm1
    mov     eax, r13d
    shr     eax, 1
    sub     edi, eax
    sub     esi, eax
    mov     edx, r13d
    mov     ecx, r13d
    mov     r8d, r12d
    call    fill_rect_px
    pop     r13
    pop     r12
    pop     rbx
    ret

# edit_draw - overlays in the viewport being drawn (cam_setup done)
edit_draw:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    call    edit_get
    test    rax, rax
    jz      .Led_out
    mov     rbx, rax
    mov     r12, [rbx+OB_MESH]
    call    project_all
    test    rax, rax
    jz      .Led_out
    mov     r13, rax
    xor     r15d, r15d                  # pass 0: unselected, 1: selected edges
.Led_pass:
    xor     r14d, r14d
1:  cmp     r14d, [r12+ME_NEDGES]
    jae     4f
    mov     rcx, [r12+ME_EDGES]
    mov     eax, [rcx+r14*8]
    mov     edx, [rcx+r14*8+4]
    mov     rcx, [r12+ME_VSEL]
    movzx   r8d, byte ptr [rcx+rax]
    and     r8b, [rcx+rdx]
    cmp     r8d, r15d
    jne     3f
    imul    rax, rax, 12
    imul    rdx, rdx, 12
    lea     rdi, [r13+rax]
    lea     rsi, [r13+rdx]
    xorps   xmm0, xmm0
    comiss  xmm0, [rdi+8]               # both in front of the camera
    jae     3f
    comiss  xmm0, [rsi+8]
    jae     3f
    mov     edx, COL_EDIT_WIRE
    test    r15d, r15d
    jz      2f
    mov     edx, COL_EDIT_SEL
2:  call    dline
3:  inc     r14d
    jmp     1b
4:  inc     r15d
    cmp     r15d, 2
    jb      .Led_pass
    cmp     dword ptr [rip+sel_mode], 2
    je      .Led_faces
    cmp     dword ptr [rip+sel_mode], 0
    jne     .Led_label
    xor     r14d, r14d                  # vertex dots
5:  cmp     r14d, [r12+ME_NVERTS]
    jae     .Led_label
    imul    rax, r14, 12
    movss   xmm0, [r13+rax]
    movss   xmm1, [r13+rax+4]
    movss   xmm2, [r13+rax+8]
    call    visible
    test    eax, eax
    jz      6f
    imul    rax, r14, 12
    movss   xmm0, [r13+rax]
    movss   xmm1, [r13+rax+4]
    mov     rcx, [r12+ME_VSEL]
    mov     edx, COL_EDIT_WIRE
    mov     ecx, 4
    mov     r8, [r12+ME_VSEL]
    cmp     byte ptr [r8+r14], 0
    je      51f
    mov     edx, COL_EDIT_SEL
    mov     ecx, 6
51: call    dot
6:  inc     r14d
    jmp     5b
.Led_faces:                             # face dots at the polygon centres
    xor     r14d, r14d
7:  cmp     r14d, [r12+ME_NPOLYS]
    jae     .Led_label
    mov     rdi, r12
    mov     esi, r14d
    call    poly_center_pv              # xmm0..2 = mean x, y, 1/z ; eax = all sel
    mov     r15d, eax
    call    visible
    test    eax, eax
    jz      8f
    mov     rdi, r12
    mov     esi, r14d
    call    poly_center_pv
    mov     edx, COL_EDIT_WIRE
    mov     ecx, 4
    test    r15d, r15d
    jz      71f
    mov     edx, COL_EDIT_SEL
    mov     ecx, 6
71: call    dot
8:  inc     r14d
    jmp     7b
.Led_label:
    cmp     dword ptr [rip+box_on], 0   # box being dragged
    je      9f
    mov     edi, [rip+box_x0]
    mov     esi, [rip+box_y0]
    mov     edx, [rip+box_x1]
    mov     ecx, [rip+box_y0]
    mov     r8d, COL_TEXT
    call    draw_line
    mov     edi, [rip+box_x0]
    mov     esi, [rip+box_y1]
    mov     edx, [rip+box_x1]
    mov     ecx, [rip+box_y1]
    mov     r8d, COL_TEXT
    call    draw_line
    mov     edi, [rip+box_x0]
    mov     esi, [rip+box_y0]
    mov     edx, [rip+box_x0]
    mov     ecx, [rip+box_y1]
    mov     r8d, COL_TEXT
    call    draw_line
    mov     edi, [rip+box_x1]
    mov     esi, [rip+box_y0]
    mov     edx, [rip+box_x1]
    mov     ecx, [rip+box_y1]
    mov     r8d, COL_TEXT
    call    draw_line
9:  mov     edi, [rip+cvs_x0]
    add     edi, 10
    mov     esi, [rip+cvs_y0]
    add     esi, 44
    mov     eax, [rip+sel_mode]
    lea     rcx, [rip+lbl_ptrs]
    mov     rdx, [rcx+rax*8]
    mov     ecx, COL_ACCENT
    call    draw_text
.Led_out:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# poly_center_pv(rdi=mesh, esi=polygon) -> xmm0..2 = mean of the projected
#   x, y, 1/z of its vertices (xmm2 = 0 if one is behind the camera);
#   eax = 1 if all its vertices are selected
poly_center_pv:
    push    rbx
    mov     r8, [rdi+ME_POFF]
    mov     r9, [rdi+ME_LOOPS]
    mov     r10, [rdi+ME_VSEL]
    mov     r11, [rip+pv]
    mov     ecx, [r8+rsi*4]
    mov     edx, [r8+rsi*4+4]
    mov     ebx, edx
    sub     ebx, ecx                    # vertex count
    xorps   xmm0, xmm0
    xorps   xmm1, xmm1
    xorps   xmm2, xmm2
    xorps   xmm4, xmm4
    xor     edi, edi                    # one behind the camera?
    mov     eax, 1
1:  cmp     ecx, edx
    jae     2f
    mov     esi, [r9+rcx*4]
    and     al, [r10+rsi]
    imul    rsi, rsi, 12
    addss   xmm0, [r11+rsi]
    addss   xmm1, [r11+rsi+4]
    movss   xmm3, [r11+rsi+8]
    comiss  xmm3, xmm4
    ja      11f
    mov     edi, 1
11: addss   xmm2, xmm3
    inc     ecx
    jmp     1b
2:  movzx   eax, al
    test    ebx, ebx
    jz      3f
    cvtsi2ss xmm3, ebx
    divss   xmm0, xmm3
    divss   xmm1, xmm3
    divss   xmm2, xmm3
3:  test    edi, edi
    jz      4f
    xorps   xmm2, xmm2
4:  pop     rbx
    ret

# -----------------------------------------------------------------------------
# Picking
# -----------------------------------------------------------------------------
# edit_click(edi=x, esi=y logical, edx=modifiers) - needs cam_setup + clip
edit_click:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 40
    mov     [rsp+32], edx
    call    to_px
    cvtsi2ss xmm0, eax
    movss   [rip+pick_x], xmm0
    mov     edi, esi
    call    to_px
    cvtsi2ss xmm0, eax
    movss   [rip+pick_y], xmm0
    call    edit_get
    test    rax, rax
    jz      .Lec_out
    mov     rbx, rax
    call    project_all
    test    rax, rax
    jz      .Lec_out
    mov     r13, rax                    # pv
    mov     r12, [rbx+OB_MESH]
    mov     rbx, r12                    # rbx = mesh from here on
    test    dword ptr [rsp+32], MOD_ALT
    jnz     .Lec_loop
    mov     eax, [rip+sel_mode]
    cmp     eax, 1
    je      .Lec_edge
    cmp     eax, 2
    je      .Lec_face
    # ---- vertex: nearest visible projected vertex ----
    call    pick_vertex                 # eax = vertex or -1
    mov     [rsp], eax
    mov     dword ptr [rsp+4], -1
    jmp     .Lec_apply
.Lec_edge:
    call    pick_edge                   # eax = a, edx = b (or -1)
    mov     [rsp], eax
    mov     [rsp+4], edx
    jmp     .Lec_apply
.Lec_face:
    call    pick_face                   # eax = polygon or -1
    test    eax, eax
    js      .Lec_none
    mov     r14d, eax                   # select the polygon's vertices
    mov     rcx, [rbx+ME_POFF]
    mov     r8d, [rcx+r14*4]
    mov     r9d, [rcx+r14*4+4]
    mov     rdx, [rbx+ME_LOOPS]
    mov     r10, [rbx+ME_VSEL]
    mov     al, 1                       # all selected already?
    mov     ecx, r8d
1:  cmp     ecx, r9d
    jae     2f
    mov     r11d, [rdx+rcx*4]
    and     al, [r10+r11]
    inc     ecx
    jmp     1b
2:  movzx   r15d, al
    test    dword ptr [rsp+32], MOD_SHIFT
    jnz     3f
    call    clear_sel
    xor     r15d, r15d
3:  xor     eax, eax                    # shift on a selected face: deselect
    test    r15d, r15d
    jnz     4f
    mov     eax, 1
4:  mov     ecx, r8d
5:  cmp     ecx, r9d
    jae     .Lec_done
    mov     r11d, [rdx+rcx*4]
    mov     [r10+r11], al
    inc     ecx
    jmp     5b

.Lec_loop:                              # Alt+click: the edge loop through the edge
    call    pick_edge
    test    eax, eax
    js      .Lec_none
    mov     r14d, eax
    mov     r15d, edx
    mov     rbx, r12
    call    build_adj
    test    eax, eax
    jz      .Lec_out
    lea     rdi, [rip+frame_arena]      # marks
    mov     esi, [rbx+ME_NVERTS]
    add     esi, 8
    call    arena_alloc
    test    rax, rax
    jz      .Lec_out
    mov     rbp, rax
    mov     rdi, rax
    mov     ecx, [rbx+ME_NVERTS]
    xor     eax, eax
    rep     stosb
    mov     edi, r14d
    mov     esi, r15d
    mov     rdx, rbp
    call    loop_walk
    mov     edi, r15d
    mov     esi, r14d
    mov     rdx, rbp
    call    loop_walk
    test    dword ptr [rsp+32], MOD_SHIFT
    jnz     6f
    call    clear_sel
6:  mov     r10, [rbx+ME_VSEL]
    xor     ecx, ecx
7:  cmp     ecx, [rbx+ME_NVERTS]
    jae     .Lec_done
    cmp     byte ptr [rbp+rcx], 0
    je      71f
    mov     byte ptr [r10+rcx], 1
71: inc     ecx
    jmp     7b

.Lec_apply:                             # [rsp] / [rsp+4]: one or two vertices
    mov     eax, [rsp]
    test    eax, eax
    js      .Lec_none
    mov     r10, [rbx+ME_VSEL]
    mov     r15b, [r10+rax]             # all selected?
    mov     ecx, [rsp+4]
    test    ecx, ecx
    js      8f
    and     r15b, [r10+rcx]
8:  test    dword ptr [rsp+32], MOD_SHIFT
    jnz     9f
    call    clear_sel
    xor     r15d, r15d
9:  xor     edx, edx
    test    r15b, r15b
    jnz     10f
    mov     edx, 1
10: mov     r10, [rbx+ME_VSEL]
    mov     eax, [rsp]
    mov     [r10+rax], dl
    mov     ecx, [rsp+4]
    test    ecx, ecx
    js      .Lec_done
    mov     [r10+rcx], dl
    jmp     .Lec_done
.Lec_none:                              # clicked nothing: deselect (unless Shift)
    test    dword ptr [rsp+32], MOD_SHIFT
    jnz     .Lec_done
    call    clear_sel
.Lec_done:
    mov     dword ptr [rip+dirty], 1
.Lec_out:
    add     rsp, 40
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

# clear_sel(rbx=mesh)
clear_sel:
    push    rdi
    push    rcx
    push    rax
    mov     rdi, [rbx+ME_VSEL]
    mov     ecx, [rbx+ME_NVERTS]
    xor     eax, eax
    rep     stosb
    pop     rax
    pop     rcx
    pop     rdi
    ret

# pick_vertex(rbx=mesh, r13=pv) -> eax = nearest visible vertex or -1
pick_vertex:
    push    r12
    push    r14
    push    r15
    sub     rsp, 16
    mov     r15d, -1
    movss   xmm7, [rip+ef_pick2]        # best distance^2
    movss   [rsp+4], xmm7
    xor     r12d, r12d
1:  cmp     r12d, [rbx+ME_NVERTS]
    jae     9f
    imul    r14, r12, 12
    add     r14, r13
    movss   xmm0, [r14]
    subss   xmm0, [rip+pick_x]
    mulss   xmm0, xmm0
    movss   xmm1, [r14+4]
    subss   xmm1, [rip+pick_y]
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    comiss  xmm0, [rsp+4]
    jae     2f
    movss   [rsp], xmm0                 # keep the distance across visible()
    movss   xmm0, [r14]
    movss   xmm1, [r14+4]
    movss   xmm2, [r14+8]
    call    visible
    test    eax, eax
    jz      2f
    movss   xmm0, [rsp]
    movss   [rsp+4], xmm0
    mov     r15d, r12d
2:  inc     r12d
    jmp     1b
9:  mov     eax, r15d
    add     rsp, 16
    pop     r15
    pop     r14
    pop     r12
    ret

# pick_edge(rbx=mesh, r13=pv) -> eax, edx = the nearest visible edge's
#   vertices, or eax = -1
pick_edge:
    push    r12
    push    r14
    push    r15
    push    rbp
    sub     rsp, 24
    mov     r15d, -1
    mov     dword ptr [rsp+16], -1
    movss   xmm0, [rip+ef_edge2]
    movss   [rsp+8], xmm0               # best distance^2
    xor     r12d, r12d
1:  cmp     r12d, [rbx+ME_NEDGES]
    jae     9f
    mov     rcx, [rbx+ME_EDGES]
    mov     eax, [rcx+r12*8]
    mov     edx, [rcx+r12*8+4]
    imul    r14, rax, 12
    add     r14, r13                    # a
    imul    rbp, rdx, 12
    add     rbp, r13                    # b
    xorps   xmm0, xmm0
    comiss  xmm0, [r14+8]
    jae     2f
    comiss  xmm0, [rbp+8]
    jae     2f
    # t = clamp(((p - a) . (b - a)) / |b - a|^2, 0, 1)
    movss   xmm2, [rbp]
    subss   xmm2, [r14]                 # dx
    movss   xmm3, [rbp+4]
    subss   xmm3, [r14+4]               # dy
    movss   xmm4, [rip+pick_x]
    subss   xmm4, [r14]
    movss   xmm5, [rip+pick_y]
    subss   xmm5, [r14+4]
    movss   xmm0, xmm4
    mulss   xmm0, xmm2
    movss   xmm1, xmm5
    mulss   xmm1, xmm3
    addss   xmm0, xmm1
    movss   xmm1, xmm2
    mulss   xmm1, xmm2
    movss   xmm6, xmm3
    mulss   xmm6, xmm3
    addss   xmm1, xmm6
    maxss   xmm1, [rip+ef_eps]
    divss   xmm0, xmm1
    xorps   xmm1, xmm1
    maxss   xmm0, xmm1
    minss   xmm0, [rip+ef_one]
    movss   [rsp+4], xmm0               # t
    mulss   xmm2, xmm0                  # closest - p
    mulss   xmm3, xmm0
    subss   xmm2, xmm4
    subss   xmm3, xmm5
    mulss   xmm2, xmm2
    mulss   xmm3, xmm3
    addss   xmm2, xmm3
    comiss  xmm2, [rsp+8]
    jae     2f
    movss   [rsp+12], xmm2
    movss   xmm6, [rsp+4]               # visible at the closest point?
    movss   xmm0, [rbp]
    subss   xmm0, [r14]
    mulss   xmm0, xmm6
    addss   xmm0, [r14]
    movss   xmm1, [rbp+4]
    subss   xmm1, [r14+4]
    mulss   xmm1, xmm6
    addss   xmm1, [r14+4]
    movss   xmm2, [rbp+8]
    subss   xmm2, [r14+8]
    mulss   xmm2, xmm6
    addss   xmm2, [r14+8]
    call    visible
    test    eax, eax
    jz      2f
    movss   xmm0, [rsp+12]
    movss   [rsp+8], xmm0
    mov     rcx, [rbx+ME_EDGES]
    mov     r15d, [rcx+r12*8]
    mov     eax, [rcx+r12*8+4]
    mov     [rsp+16], eax
2:  inc     r12d
    jmp     1b
9:  mov     eax, r15d
    mov     edx, [rsp+16]
    add     rsp, 24
    pop     rbp
    pop     r15
    pop     r14
    pop     r12
    ret

# pick_face(rbx=mesh, r13=pv) -> eax = front-most polygon under the pointer
pick_face:
    push    r12
    push    r14
    push    r15
    push    rbp
    sub     rsp, 24
    mov     r15d, -1
    xorps   xmm0, xmm0
    movss   [rsp+8], xmm0               # best 1/z (bigger = nearer)
    xor     r12d, r12d
1:  cmp     r12d, [rbx+ME_NTRIS]
    jae     9f
    mov     rcx, [rbx+ME_TRIS]
    imul    rax, r12, 12
    mov     edx, [rcx+rax]
    imul    r14, rdx, 12
    add     r14, r13                    # a
    mov     edx, [rcx+rax+4]
    imul    rbp, rdx, 12
    add     rbp, r13                    # b
    mov     edx, [rcx+rax+8]
    imul    rdx, rdx, 12
    add     rdx, r13                    # c
    xorps   xmm7, xmm7
    comiss  xmm7, [r14+8]
    jae     2f
    comiss  xmm7, [rbp+8]
    jae     2f
    comiss  xmm7, [rdx+8]
    jae     2f
    # barycentric: area = (b-a) x (c-a); u = (c-p) x ... (2D signed areas)
    movss   xmm0, [rbp]
    subss   xmm0, [r14]                 # bx - ax
    movss   xmm1, [rbp+4]
    subss   xmm1, [r14+4]               # by - ay
    movss   xmm2, [rdx]
    subss   xmm2, [r14]                 # cx - ax
    movss   xmm3, [rdx+4]
    subss   xmm3, [r14+4]               # cy - ay
    movss   xmm4, [rip+pick_x]
    subss   xmm4, [r14]                 # px - ax
    movss   xmm5, [rip+pick_y]
    subss   xmm5, [r14+4]               # py - ay
    movss   xmm6, xmm0                  # det = b x c
    mulss   xmm6, xmm3
    movss   xmm7, xmm1
    mulss   xmm7, xmm2
    subss   xmm6, xmm7
    movss   [rsp], xmm6
    andps   xmm6, [rip+ef_absmask]
    comiss  xmm6, [rip+ef_eps]
    jbe     2f
    movss   xmm6, xmm4                  # s = (p x c) / det
    mulss   xmm6, xmm3
    movss   xmm7, xmm5
    mulss   xmm7, xmm2
    subss   xmm6, xmm7
    divss   xmm6, [rsp]
    movss   xmm7, xmm0                  # t = (b x p) / det
    mulss   xmm7, xmm5
    mulss   xmm1, xmm4
    subss   xmm7, xmm1
    divss   xmm7, [rsp]
    xorps   xmm0, xmm0
    comiss  xmm6, xmm0
    jb      2f
    comiss  xmm7, xmm0
    jb      2f
    movss   xmm0, xmm6
    addss   xmm0, xmm7
    comiss  xmm0, [rip+ef_one]
    ja      2f
    # 1/z = a + s (b - a) + t (c - a)
    movss   xmm0, [rbp+8]
    subss   xmm0, [r14+8]
    mulss   xmm0, xmm6
    movss   xmm1, [rdx+8]
    subss   xmm1, [r14+8]
    mulss   xmm1, xmm7
    addss   xmm0, xmm1
    addss   xmm0, [r14+8]
    comiss  xmm0, [rsp+8]
    jbe     2f
    movss   [rsp+8], xmm0
    mov     rcx, [rbx+ME_TPOLY]
    mov     r15d, [rcx+r12*4]
2:  inc     r12d
    jmp     1b
9:  mov     eax, r15d
    add     rsp, 24
    pop     rbp
    pop     r15
    pop     r14
    pop     r12
    ret

# -----------------------------------------------------------------------------
# Box select (B, then drag)
# -----------------------------------------------------------------------------
box_begin:                              # edi, esi = logical press point
    mov     [rip+box_x0], edi
    mov     [rip+box_y0], esi
    mov     [rip+box_x1], edi
    mov     [rip+box_y1], esi
    mov     dword ptr [rip+box_on], 1
    mov     dword ptr [rip+box_armed], 0
    mov     dword ptr [rip+dirty], 1
    ret
box_move:
    mov     [rip+box_x1], edi
    mov     [rip+box_y1], esi
    mov     dword ptr [rip+dirty], 1
    ret

# box_finish(edi=modifiers) - needs cam_setup + clip of the viewport
box_finish:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 40
    mov     [rsp+32], edi
    mov     dword ptr [rip+box_on], 0
    mov     dword ptr [rip+dirty], 1
    mov     edi, [rip+box_x0]           # physical rectangle, ordered
    call    to_px
    mov     [rsp], eax
    mov     edi, [rip+box_x1]
    call    to_px
    mov     [rsp+4], eax
    mov     edi, [rip+box_y0]
    call    to_px
    mov     [rsp+8], eax
    mov     edi, [rip+box_y1]
    call    to_px
    mov     [rsp+12], eax
    mov     eax, [rsp]
    mov     ecx, [rsp+4]
    cmp     eax, ecx
    jle     1f
    mov     [rsp], ecx
    mov     [rsp+4], eax
1:  mov     eax, [rsp+8]
    mov     ecx, [rsp+12]
    cmp     eax, ecx
    jle     2f
    mov     [rsp+8], ecx
    mov     [rsp+12], eax
2:  call    edit_get
    test    rax, rax
    jz      .Lbf_out
    mov     rbx, rax
    call    project_all
    test    rax, rax
    jz      .Lbf_out
    mov     r13, rax
    mov     rbx, [rbx+OB_MESH]
    lea     rdi, [rip+frame_arena]      # inside & visible, per vertex
    mov     esi, [rbx+ME_NVERTS]
    add     esi, 8
    call    arena_alloc
    test    rax, rax
    jz      .Lbf_out
    mov     rbp, rax
    xor     r12d, r12d
3:  cmp     r12d, [rbx+ME_NVERTS]
    jae     5f
    mov     byte ptr [rbp+r12], 0
    imul    r14, r12, 12
    add     r14, r13
    cvttss2si eax, [r14]
    cmp     eax, [rsp]
    jl      4f
    cmp     eax, [rsp+4]
    jg      4f
    cvttss2si eax, [r14+4]
    cmp     eax, [rsp+8]
    jl      4f
    cmp     eax, [rsp+12]
    jg      4f
    movss   xmm0, [r14]
    movss   xmm1, [r14+4]
    movss   xmm2, [r14+8]
    call    visible
    mov     [rbp+r12], al
4:  inc     r12d
    jmp     3b
5:  mov     r15d, 1                     # value to write: Ctrl subtracts
    test    dword ptr [rsp+32], MOD_CTRL
    jz      6f
    xor     r15d, r15d
6:  cmp     dword ptr [rip+sel_mode], 0
    jne     .Lbf_polys
    mov     r10, [rbx+ME_VSEL]          # vertices inside
    xor     ecx, ecx
7:  cmp     ecx, [rbx+ME_NVERTS]
    jae     .Lbf_out
    cmp     byte ptr [rbp+rcx], 0
    je      71f
    mov     [r10+rcx], r15b
71: inc     ecx
    jmp     7b
.Lbf_polys:                             # edges / faces fully inside
    mov     r8, [rbx+ME_POFF]
    mov     r9, [rbx+ME_LOOPS]
    mov     r10, [rbx+ME_VSEL]
    cmp     dword ptr [rip+sel_mode], 1
    je      .Lbf_edges
    xor     ecx, ecx
8:  cmp     ecx, [rbx+ME_NPOLYS]
    jae     .Lbf_out
    mov     edx, [r8+rcx*4]
    mov     r11d, [r8+rcx*4+4]
    mov     al, 1
81: cmp     edx, r11d
    jae     82f
    mov     esi, [r9+rdx*4]
    and     al, [rbp+rsi]
    inc     edx
    jmp     81b
82: test    al, al
    jz      84f
    mov     edx, [r8+rcx*4]
83: cmp     edx, r11d
    jae     84f
    mov     esi, [r9+rdx*4]
    mov     [r10+rsi], r15b
    inc     edx
    jmp     83b
84: inc     ecx
    jmp     8b
.Lbf_edges:
    mov     r8, [rbx+ME_EDGES]
    xor     ecx, ecx
9:  cmp     ecx, [rbx+ME_NEDGES]
    jae     .Lbf_out
    mov     eax, [r8+rcx*8]
    mov     edx, [r8+rcx*8+4]
    mov     sil, [rbp+rax]
    and     sil, [rbp+rdx]
    jz      91f
    mov     [r10+rax], r15b
    mov     [r10+rdx], r15b
91: inc     ecx
    jmp     9b
.Lbf_out:
    add     rsp, 40
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

# -----------------------------------------------------------------------------
# Component transforms (called by transform.s)
# -----------------------------------------------------------------------------
# edit_median(rdi=out world vec3) -> eax = selected vertex count
edit_median:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 72
    mov     r14, rdi
    xorps   xmm0, xmm0
    movss   [r14], xmm0
    movss   [r14+4], xmm0
    movss   [r14+8], xmm0
    xor     r13d, r13d
    call    edit_get
    test    rax, rax
    jz      9f
    mov     rdi, rax
    mov     r12, [rax+OB_MESH]
    lea     rsi, [rsp]
    call    obj_matrix
    xor     ebx, ebx
1:  cmp     ebx, [r12+ME_NVERTS]
    jae     8f
    mov     rcx, [r12+ME_VSEL]
    cmp     byte ptr [rcx+rbx], 0
    je      2f
    imul    rsi, rbx, 12
    add     rsi, [r12+ME_POS]
    lea     rdi, [rsp]
    lea     rdx, [rsp+48]
    call    xform_point
    movss   xmm0, [rsp+48]
    addss   xmm0, [r14]
    movss   [r14], xmm0
    movss   xmm0, [rsp+52]
    addss   xmm0, [r14+4]
    movss   [r14+4], xmm0
    movss   xmm0, [rsp+56]
    addss   xmm0, [r14+8]
    movss   [r14+8], xmm0
    inc     r13d
2:  inc     ebx
    jmp     1b
8:  test    r13d, r13d
    jz      9f
    cvtsi2ss xmm1, r13d
    movss   xmm0, [r14]
    divss   xmm0, xmm1
    movss   [r14], xmm0
    movss   xmm0, [r14+4]
    divss   xmm0, xmm1
    movss   [r14+4], xmm0
    movss   xmm0, [r14+8]
    divss   xmm0, xmm1
    movss   [r14+8], xmm0
9:  mov     eax, r13d
    add     rsp, 72
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# edit_tm_snapshot(rdi=pivot out) -> eax = count. Call after undo_push: the
#   mesh is made unshared first, then the selected vertices are recorded.
edit_tm_snapshot:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r15, rdi
    mov     dword ptr [rip+ev_n], 0
    call    edit_cow
    test    rax, rax
    jz      .Lts_zero
    mov     r12, rax
    mov     rdi, r15
    call    edit_median
    test    eax, eax
    jz      .Lts_zero
    mov     r13d, eax
    imul    rax, r13, EV_SZ             # grow the snapshot buffer
    cmp     rax, [rip+ev_cap]
    jbe     1f
    add     rax, 0xffff
    and     rax, -0x10000
    mov     r14, rax
    mov     rdi, [rip+ev_buf]
    test    rdi, rdi
    jz      2f
    mov     rsi, [rip+ev_cap]
    mov     eax, SYS_MUNMAP
    syscall
2:  xor     edi, edi
    mov     rsi, r14
    mov     edx, PROT_RW
    mov     r10d, 0x22
    mov     r8d, -1
    xor     r9d, r9d
    mov     eax, SYS_MMAP
    syscall
    cmp     rax, -4096
    ja      .Lts_fail
    mov     [rip+ev_buf], rax
    mov     [rip+ev_cap], r14
1:  mov     rax, [r12+ME_POS]
    mov     [rip+ev_pos], rax
    call    edit_get                    # matrix and its inverse
    mov     rdi, rax
    lea     rsi, [rip+mtx]
    call    obj_matrix
    call    invert3
    mov     r14, [rip+ev_buf]
    xor     ebx, ebx
3:  cmp     ebx, [r12+ME_NVERTS]
    jae     8f
    mov     rcx, [r12+ME_VSEL]
    cmp     byte ptr [rcx+rbx], 0
    je      4f
    mov     [r14], ebx
    imul    rsi, rbx, 12
    add     rsi, [r12+ME_POS]
    mov     rax, [rsi]                  # local
    mov     [r14+16], rax
    mov     eax, [rsi+8]
    mov     [r14+24], eax
    lea     rdi, [rip+mtx]
    lea     rdx, [r14+4]                # world
    call    xform_point
    add     r14, EV_SZ
    inc     dword ptr [rip+ev_n]
4:  inc     ebx
    jmp     3b
8:  mov     eax, [rip+ev_n]
    jmp     9f
.Lts_fail:
    mov     qword ptr [rip+ev_cap], 0
    mov     qword ptr [rip+ev_buf], 0
.Lts_zero:
    xor     eax, eax
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# invert3 - minv = inverse of the 3x3 part of mtx (identity if singular)
invert3:
    lea     rsi, [rip+mtx]
    lea     rdi, [rip+minv]
    # cofactors (m = rows 0..2 at +0, +16, +32)
    movss   xmm0, [rsi+20]              # c00 = m11 m22 - m12 m21
    mulss   xmm0, [rsi+40]
    movss   xmm1, [rsi+24]
    mulss   xmm1, [rsi+36]
    subss   xmm0, xmm1
    movss   [rdi], xmm0
    movss   xmm0, [rsi+8]               # c01 = m02 m21 - m01 m22
    mulss   xmm0, [rsi+36]
    movss   xmm1, [rsi+4]
    mulss   xmm1, [rsi+40]
    subss   xmm0, xmm1
    movss   [rdi+4], xmm0
    movss   xmm0, [rsi+4]               # c02 = m01 m12 - m02 m11
    mulss   xmm0, [rsi+24]
    movss   xmm1, [rsi+8]
    mulss   xmm1, [rsi+20]
    subss   xmm0, xmm1
    movss   [rdi+8], xmm0
    movss   xmm0, [rsi+24]              # c10 = m12 m20 - m10 m22
    mulss   xmm0, [rsi+32]
    movss   xmm1, [rsi+16]
    mulss   xmm1, [rsi+40]
    subss   xmm0, xmm1
    movss   [rdi+12], xmm0
    movss   xmm0, [rsi]                 # c11 = m00 m22 - m02 m20
    mulss   xmm0, [rsi+40]
    movss   xmm1, [rsi+8]
    mulss   xmm1, [rsi+32]
    subss   xmm0, xmm1
    movss   [rdi+16], xmm0
    movss   xmm0, [rsi+8]               # c12 = m02 m10 - m00 m12
    mulss   xmm0, [rsi+16]
    movss   xmm1, [rsi]
    mulss   xmm1, [rsi+24]
    subss   xmm0, xmm1
    movss   [rdi+20], xmm0
    movss   xmm0, [rsi+16]              # c20 = m10 m21 - m11 m20
    mulss   xmm0, [rsi+36]
    movss   xmm1, [rsi+20]
    mulss   xmm1, [rsi+32]
    subss   xmm0, xmm1
    movss   [rdi+24], xmm0
    movss   xmm0, [rsi+4]               # c21 = m01 m20 - m00 m21
    mulss   xmm0, [rsi+32]
    movss   xmm1, [rsi]
    mulss   xmm1, [rsi+36]
    subss   xmm0, xmm1
    movss   [rdi+28], xmm0
    movss   xmm0, [rsi]                 # c22 = m00 m11 - m01 m10
    mulss   xmm0, [rsi+20]
    movss   xmm1, [rsi+4]
    mulss   xmm1, [rsi+16]
    subss   xmm0, xmm1
    movss   [rdi+32], xmm0
    movss   xmm0, [rsi]                 # det = m00 c00 + m01 c10 + m02 c20
    mulss   xmm0, [rdi]
    movss   xmm1, [rsi+4]
    mulss   xmm1, [rdi+12]
    addss   xmm0, xmm1
    movss   xmm1, [rsi+8]
    mulss   xmm1, [rdi+24]
    addss   xmm0, xmm1
    movss   xmm1, xmm0
    andps   xmm1, [rip+ef_absmask]
    comiss  xmm1, [rip+ef_eps]
    jbe     2f
    movss   xmm1, [rip+ef_one]
    divss   xmm1, xmm0
    xor     ecx, ecx
1:  movss   xmm0, [rdi+rcx*4]
    mulss   xmm0, xmm1
    movss   [rdi+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 9
    jb      1b
    ret
2:  xor     eax, eax                    # singular: identity
    mov     ecx, 9
    push    rdi
    rep     stosd
    pop     rdi
    mov     eax, 0x3f800000
    mov     [rdi], eax
    mov     [rdi+16], eax
    mov     [rdi+32], eax
    ret

# bump - the edit mesh changed in place (evaluation caches look at this)
bump:
    mov     rax, [rip+ev_pos]
    test    rax, rax
    jz      1f
    sub     rsp, 8
    call    edit_get
    add     rsp, 8
    test    rax, rax
    jz      1f
    mov     rax, [rax+OB_MESH]
    inc     dword ptr [rax+108]
1:  ret

# store_local(r14=entry, xmm0..2 = new world position) - via the inverse
store_local:
    subss   xmm0, [rip+mtx+12]
    subss   xmm1, [rip+mtx+28]
    subss   xmm2, [rip+mtx+44]
    push    rbx
    mov     rax, [rip+ev_pos]
    mov     ecx, [r14]
    lea     rcx, [rcx+rcx*2]
    lea     rax, [rax+rcx*4]
    lea     rdx, [rip+minv]
    xor     ebx, ebx
1:  movss   xmm3, [rdx]
    mulss   xmm3, xmm0
    movss   xmm4, [rdx+4]
    mulss   xmm4, xmm1
    addss   xmm3, xmm4
    movss   xmm4, [rdx+8]
    mulss   xmm4, xmm2
    addss   xmm3, xmm4
    movss   [rax+rbx*4], xmm3
    add     rdx, 12
    inc     ebx
    cmp     ebx, 3
    jb      1b
    pop     rbx
    ret

# ex_setup - mtx / minv of the edit object (for ex_to_world / ex_to_local)
ex_setup:
    sub     rsp, 8
    call    edit_get
    test    rax, rax
    jz      1f
    mov     rdi, rax
    lea     rsi, [rip+mtx]
    call    obj_matrix
    call    invert3
1:  add     rsp, 8
    ret

# ex_to_world(rsi=local float[3], rdx=out) / ex_to_local(rsi=world, rdx=out)
ex_to_world:
    lea     rdi, [rip+mtx]
    jmp     xform_point
ex_to_local:
    movss   xmm0, [rsi]
    subss   xmm0, [rip+mtx+12]
    movss   xmm1, [rsi+4]
    subss   xmm1, [rip+mtx+28]
    movss   xmm2, [rsi+8]
    subss   xmm2, [rip+mtx+44]
    lea     r8, [rip+minv]
    xor     ecx, ecx
1:  movss   xmm3, [r8]
    mulss   xmm3, xmm0
    movss   xmm4, [r8+4]
    mulss   xmm4, xmm1
    addss   xmm3, xmm4
    movss   xmm4, [r8+8]
    mulss   xmm4, xmm2
    addss   xmm3, xmm4
    movss   [rdx+rcx*4], xmm3
    add     r8, 12
    inc     ecx
    cmp     ecx, 3
    jb      1b
    ret

# edit_pick_edge(edi=x, esi=y logical) -> eax, edx = the edge under the
#   pointer (eax = -1: none). edit_pick_vertex -> eax = vertex or -1.
#   Need cam_setup + clip of the viewport.
edit_pick_edge:
    mov     eax, 1
    jmp     pick_common
edit_pick_vertex:
    xor     eax, eax
pick_common:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     r14d, eax
    call    to_px
    cvtsi2ss xmm0, eax
    movss   [rip+pick_x], xmm0
    mov     edi, esi
    call    to_px
    cvtsi2ss xmm0, eax
    movss   [rip+pick_y], xmm0
    mov     eax, -1
    mov     edx, -1
    call    edit_get
    test    rax, rax
    jz      9f
    mov     rbx, rax
    call    project_all
    test    rax, rax
    mov     eax, -1
    mov     edx, -1
    jz      9f
    mov     r13, [rip+pv]
    mov     rbx, [rbx+OB_MESH]
    test    r14d, r14d
    jz      1f
    call    pick_edge
    jmp     9f
1:  call    pick_vertex
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

edit_tm_restore:
    push    rbx
    mov     r8, [rip+ev_pos]
    test    r8, r8
    jz      9f
    mov     rsi, [rip+ev_buf]
    xor     ebx, ebx
1:  cmp     ebx, [rip+ev_n]
    jae     9f
    mov     ecx, [rsi]
    lea     rcx, [rcx+rcx*2]
    mov     rax, [rsi+16]
    mov     [r8+rcx*4], rax
    mov     eax, [rsi+24]
    mov     [r8+rcx*4+8], eax
    add     rsi, EV_SZ
    inc     ebx
    jmp     1b
9:  call    bump
    pop     rbx
    ret

# edit_tm_grab(rdi=world delta)
edit_tm_grab:
    push    rbx
    push    r14
    push    r15
    mov     r15, rdi
    mov     r14, [rip+ev_buf]
    xor     ebx, ebx
1:  cmp     ebx, [rip+ev_n]
    jae     9f
    movss   xmm0, [r14+4]
    addss   xmm0, [r15]
    movss   xmm1, [r14+8]
    addss   xmm1, [r15+4]
    movss   xmm2, [r14+12]
    addss   xmm2, [r15+8]
    call    store_local
    add     r14, EV_SZ
    inc     ebx
    jmp     1b
9:  call    bump
    pop     r15
    pop     r14
    pop     rbx
    ret

# edit_tm_rotate(edi=axis 1..3, xmm0=sin, xmm1=cos, rsi=pivot) - the two
#   other components rotate: (Y,Z) for X, (Z,X) for Y, (X,Y) for Z
edit_tm_rotate:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 32
    movss   [rsp], xmm0
    movss   [rsp+4], xmm1
    mov     r15, rsi
    mov     r12d, edi                   # a = axis (wraps 3 -> 0), b = a + 1
    cmp     r12d, 3
    jb      1f
    xor     r12d, r12d
1:  lea     r13d, [r12+1]
    cmp     r13d, 3
    jb      2f
    xor     r13d, r13d
2:  mov     r14, [rip+ev_buf]
    xor     ebx, ebx
3:  cmp     ebx, [rip+ev_n]
    jae     9f
    mov     rax, [r14+4]                # world -> [rsp+16]
    mov     [rsp+16], rax
    mov     eax, [r14+12]
    mov     [rsp+24], eax
    movss   xmm2, [rsp+16+r12*4]
    subss   xmm2, [r15+r12*4]           # da
    movss   xmm3, [rsp+16+r13*4]
    subss   xmm3, [r15+r13*4]           # db
    movss   xmm4, xmm2                  # a' = da cos - db sin
    mulss   xmm4, [rsp+4]
    movss   xmm5, xmm3
    mulss   xmm5, [rsp]
    subss   xmm4, xmm5
    addss   xmm4, [r15+r12*4]
    mulss   xmm2, [rsp]                 # b' = da sin + db cos
    mulss   xmm3, [rsp+4]
    addss   xmm2, xmm3
    addss   xmm2, [r15+r13*4]
    movss   [rsp+16+r12*4], xmm4
    movss   [rsp+16+r13*4], xmm2
    movss   xmm0, [rsp+16]
    movss   xmm1, [rsp+20]
    movss   xmm2, [rsp+24]
    call    store_local
    add     r14, EV_SZ
    inc     ebx
    jmp     3b
9:  call    bump
    add     rsp, 32
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# edit_tm_scale(xmm0=factor, edi=axis 0 all / 1..3, rsi=pivot)
edit_tm_scale:
    push    rbx
    push    r12
    push    r14
    push    r15
    sub     rsp, 24
    movss   [rsp], xmm0
    mov     r12d, edi
    mov     r15, rsi
    mov     r14, [rip+ev_buf]
    xor     ebx, ebx
1:  cmp     ebx, [rip+ev_n]
    jae     9f
    xor     ecx, ecx
2:  movss   xmm0, [r14+4+rcx*4]
    test    r12d, r12d
    jz      3f
    lea     eax, [rcx+1]
    cmp     eax, r12d
    jne     4f
3:  subss   xmm0, [r15+rcx*4]
    mulss   xmm0, [rsp]
    addss   xmm0, [r15+rcx*4]
4:  movss   [rsp+8+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      2b
    movss   xmm0, [rsp+8]
    movss   xmm1, [rsp+12]
    movss   xmm2, [rsp+16]
    call    store_local
    add     r14, EV_SZ
    inc     ebx
    jmp     1b
9:  call    bump
    add     rsp, 24
    pop     r15
    pop     r14
    pop     r12
    pop     rbx
    ret

# edit_tm_end - the bounding box follows the moved vertices
edit_tm_end:
    sub     rsp, 8
    call    edit_get
    test    rax, rax
    jz      1f
    mov     rdi, [rax+OB_MESH]
    call    mesh_bbox
1:  add     rsp, 8
    ret

.section .rodata
.align 16
ef_absmask:     .long 0x7fffffff, 0x7fffffff, 0x7fffffff, 0x7fffffff

.section .note.GNU-stack,"",@progbits
