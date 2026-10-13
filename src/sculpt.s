# =============================================================================
#  BeeModel - sculpt mode
#
#  The mesh is split into leaves of a bounding-volume hierarchy - about a
#  thousand triangles each, by spatial median splits - with each leaf's
#  triangles, its vertices (each listed once per leaf) and its box. Vertex
#  normals are kept per vertex. A brush dab finds the leaves its sphere
#  touches and changes only their vertices; their boxes and the normals
#  around them follow. Strokes record the first old position of every
#  vertex they move: the undo step carries those deltas instead of a copy
#  of the mesh, which is changed in place.
#
#  Drawing (sculpt_draw) skips the triangle rasterizer: the leaves are
#  binned into screen tiles and the tiles are drawn in parallel - a leaf
#  with two vertices or more a pixel splats them (smooth normals; every
#  k-th when there are more), a closer one rasterizes its triangles - into
#  the same colour and depth buffers as the other objects. Splats are
#  projected and shaded once into records that stay while the view does:
#  during a stroke only the leaves it changed are projected again.
#
#  A pen's pressure (wayland.s: in_pressure) scales the strength and / or
#  the radius of each dab through a curve; its eraser end inverts. The
#  stabilizer drags the stroke point behind the pointer on a string.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

.globl sc_obj
.globl sculpt_enter
.globl sculpt_exit
.globl sculpt_valid
.globl sculpt_draw
.globl sculpt_press
.globl sculpt_drag
.globl sculpt_release
.globl sculpt_hover
.globl sculpt_overlay
.globl sculpt_dab_world
.globl sculpt_after_undo
.globl sculpt_mask_op
.globl sc_brush
.globl sc_radius
.globl sc_strength
.globl sc_sym
.globl op_sculpt_mode
.globl sculpt_build
.globl sc_obj, sc_mesh, sc_nodes, sc_nnodes, sc_tri, sc_tri_b, sc_vl, sc_vl_b
.globl sc_nvl, sc_nv, sc_nt, sv_pos, sv_tris, sc_vn, sc_vn_b, sc_mask
.globl sc_mask_b, sc_masked, sc_stamp, sc_stamp_b, sc_rec, sc_rec_b, sc_acc
.globl sc_acc_b, sc_maxedge, sc_hits, sc_nh, sc_lchg, sc_stroking
.globl sc_brush_now, dab_p, salloc, sfree, smap, reach, node_box
.globl sc_d_n, sc_d_cap, sc_d_idx, sc_d_old

.include "sculpt.inc"

.section .rodata
.align 16
sf_abs:         .long 0x7fffffff, 0x7fffffff, 0x7fffffff, 0x7fffffff
sf_big:         .float 3.0e38
sf_nbig:        .float -3.0e38
sf_one:         .float 1.0
sf_half:        .float 0.5
sf_two:         .float 2.0
sf_2pi32:       .float 0.19634954               # 2 pi / 32
sf_grow:        .float 1.15
sf_shrink:      .float 0.8695652
sf_rmin:        .float 4.0
sf_rmax:        .float 600.0
sf_tenth:       .float 0.1
sf_tiny:        .float 1.0e-20
sf_amb:         .float 0.25
sf_dif:         .float 0.75
sf_255:         .float 255.0
sf_spacing:     .float 0.10                     # dabs: every 10% of the radius
sf_eps:         .float 1.0e-6
sf_mask:        .float 0.003921569              # 1/255
clay_r:         .float 0.80
clay_g:         .float 0.76
clay_b:         .float 0.70
mask_k:         .float 0.55                     # masked: darker
s_sculpt:       .asciz "Sculpt"
s_need_mesh:    .asciz "  sculpt mode: select a mesh"
s_nomem:        .asciz "  sculpt mode: out of memory"
s_entered:      .asciz "  sculpt mode: "
s_tris:         .asciz " triangles in "
s_leaves:       .asciz " leaves"
s_left:         .asciz "  sculpt mode off"
s_hud:          .asciz "Sculpt: "
s_hud_r:        .asciz "  radius "
s_hud_s:        .asciz "  strength "
s_hud_sym:      .asciz "  X symmetry"
s_hud_lazy:     .asciz "stabilizer "
s_hud_pen:      .asciz "pen:"
s_hud_pstr:     .asciz " strength"
s_hud_prad:     .asciz " radius"
s_hud_poff:     .asciz " -"
s_hud_gap:      .asciz "   "
s_hud_dyn:      .asciz "dyntopo "
s_hud_mr:       .asciz "multires level "
.align 8
curve_names:    .quad s_soft, s_linear, s_hard
s_soft:         .asciz " (soft)"
s_linear:       .asciz " (linear)"
s_hard:         .asciz " (hard)"
s_lazy_log:     .asciz "  sculpt stabilizer: "
s_px:           .asciz " px"
s_hud_keys:     .asciz "  ([ ] radius, Shift+[ ] strength, Ctrl inverts, Shift smooths)"
.align 8
brush_names:    .quad bn_draw, bn_clay, bn_crease, bn_inflate, bn_grab, bn_snake
                .quad bn_smooth, bn_flatten, bn_pinch, bn_layer, bn_mask
bn_draw:        .asciz "draw"
bn_clay:        .asciz "clay strips"
bn_crease:      .asciz "crease"
bn_inflate:     .asciz "inflate"
bn_grab:        .asciz "grab"
bn_snake:       .asciz "snake hook"
bn_smooth:      .asciz "smooth"
bn_flatten:     .asciz "flatten"
bn_pinch:       .asciz "pinch"
bn_layer:       .asciz "layer"
bn_mask:        .asciz "mask"
.globl brush_names

OPERATOR op_sculpt_mode, "object.sculpt_mode", "Sculpt Mode", do_sculpt_mode, check=sculpt_check, key=KEY_TAB|KM_CTRL, flags=OPF_AI_SAFE|OPF_QUIET, doc="Sculpt the active mesh: brushes deform it under the pointer (Ctrl+Tab toggles)"

.section .data
.align 4
sc_radius:      .float 50.0             # pixels
sc_strength:    .float 0.5
sc_brush:       .long 0
sc_sym:         .long 0                 # bit 0: X
sc_pmap:        .long 1                 # pen pressure drives: 1 strength,
                                        #  2 radius
sc_pcurve:      .long 1                 # 0 soft (sqrt), 1 linear, 2 hard (^2)
sc_lazy:        .long 0                 # stabilizer: string length (pixels)

.section .bss
.align 8
sc_obj:         .skip 4                 # the object's handle (0: off)
sc_nv:          .skip 4
sc_nt:          .skip 4
sc_nnodes:      .skip 4
sc_mesh:        .skip 8
sc_nodes:       .skip 8                 # mapped arrays, with their sizes
sc_nodes_b:     .skip 8
sc_tri:         .skip 8                 # triangle ids, by leaf
sc_tri_b:       .skip 8
sc_vl:          .skip 8                 # vertex lists, by leaf
sc_vl_b:        .skip 8
sc_nvl:         .skip 4
sc_vn:          .skip 8                 # vertex normals
sc_vn_b:        .skip 8
sc_mask:        .skip 8                 # u8 per vertex
sc_mask_b:      .skip 8
sc_masked:      .skip 4                 # 0: no vertex is masked (not read)
.align 8
sc_stamp:       .skip 8                 # u32 per vertex
sc_stamp_b:     .skip 8
sc_rec:         .skip 8                 # u8 per vertex: recorded this stroke
sc_rec_b:       .skip 8
sc_acc:         .skip 8                 # float4 per vertex (smoothing)
sc_acc_b:       .skip 8
sc_serial:      .skip 4
sc_hits:        .skip 8                 # leaves in reach: 3 lists of n
sc_hits_b:      .skip 8
sc_nh:          .skip 12                # their lengths
.align 16
sc_slots:       .skip 32*130            # per thread: w, centre, normal
sc_maxedge:     .skip 4
# the matrix and its inverse
sc_m:           .skip 48
sc_mi:          .skip 48
sc_scale:       .skip 4                 # world length -> local
# a stroke
sc_stroking:    .skip 4
sc_invert:      .skip 4
sc_brush_now:   .skip 4
sc_last:        .skip 12                # the last dab (local)
sc_lastn:       .skip 12
sc_lastr:       .skip 4                 # local radius
sc_lastsx:      .skip 4                 # screen position of the last dab
sc_lastsy:      .skip 4
sc_gplane:      .skip 4                 # grab: depth of its plane (camera z)
sc_gstart:      .skip 12
sc_d_idx:       .skip 8                 # the stroke's deltas: index, old xyz
sc_d_old:       .skip 8
sc_d_n:         .skip 4
sc_d_cap:       .skip 4
sc_g_idx:       .skip 8                 # grab: captured vertices, weights
sc_g_w:         .skip 8
sc_g_n:         .skip 4
sc_g_cap:       .skip 4
# a dab's working values
dab_p:          .skip 12
dab_n:          .skip 12                # the area normal
dab_c:          .skip 12                # the area centre
dab_r:          .skip 4
dab_s:          .skip 4                 # strength (signed)
dab_sym:        .skip 4
dab_move:       .skip 12                # grab / snake: the move
pk_o:           .skip 12                # picking ray (local)
pk_d:           .skip 12
pk_p:           .skip 12
pk_t:           .skip 4
nn_r1:          .skip 4
nd_on:          .skip 4                 # normals due in a sphere
nd_c:           .skip 12
nd_r:           .skip 4
# drawing
sd_c:           .skip 48                # local -> camera
sd_scale:       .skip 4
sd_nodes:       .skip 8                 # per leaf: x0 y0 x1 y1, mode,
                                        #  splat stride
sc_lrec:        .skip 8                 # per leaf: first splat record,
sc_lrec_b:      .skip 8                 #  room, records, their stride
sc_lchg:        .skip 8                 # per leaf: 1 = changed since drawn
sc_lchg_b:      .skip 8
sc_rbuf:        .skip 8                 # splat records: x y 1/z colour, kept
sc_rbuf_b:      .skip 8                 #  while the view stays
sc_full:        .skip 4                 # 1: project every leaf again
sc_rused:       .skip 4                 # records laid out
sc_base_s:      .skip 4                 # the stroke's strength (signed)
sc_penon:       .skip 4                 # 1: a stroke by hand (pressure counts)
lz_x:           .skip 4                 # the stabilized pointer
lz_y:           .skip 4
sd_key:         .skip 80                # the view the records were made in
sd_knew:        .skip 80
sd_nodes_b:     .skip 8
sd_toff:        .skip 8                 # tiles -> leaves (CSR)
sd_tlist:       .skip 8
sd_ntx:         .skip 4
sd_nty:         .skip 4
sd_hover:       .skip 4                 # the pointer over the canvas
sd_hx:          .skip 4
sd_hy:          .skip 4

.text

# smap(rdi=bytes) -> rax = zeroed memory or 0; sunmap(rdi, rsi)
smap:
    add     rdi, 4095
    and     rdi, -4096
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

# sfree(rdi=&pointer, rsi=&bytes)
sfree:
    push    rbx
    mov     rbx, rdi
    mov     rax, [rdi]
    test    rax, rax
    jz      9f
    mov     rdx, rsi
    mov     rsi, [rsi]
    mov     qword ptr [rdx], 0
    add     rsi, 4095
    and     rsi, -4096
    mov     rdi, rax
    mov     eax, SYS_MUNMAP
    syscall
    mov     qword ptr [rbx], 0
9:  pop     rbx
    ret

# salloc(rdi=&pointer, rsi=&bytes, rdx=size) -> rax (0: no memory)
salloc:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    mov     r12, rsi
    mov     [r12], rdx
    mov     rdi, rdx
    call    smap
    mov     [rbx], rax
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

sculpt_check:
    xor     eax, eax
    cmp     dword ptr [rip+sc_obj], 0
    setne   al
    ret

# =============================================================================
#  Entering, leaving
# =============================================================================
do_sculpt_mode:
    sub     rsp, 8
    cmp     dword ptr [rip+sc_obj], 0
    je      1f
    call    sculpt_exit
    lea     rdi, [rip+s_left]
    call    log_line
    jmp     9f
1:  mov     edi, [rip+active_obj]
    call    sculpt_enter
9:  mov     dword ptr [rip+dirty], 1
    add     rsp, 8
    ret

# sculpt_enter(edi=object handle) -> eax = 1
sculpt_enter:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 16
    mov     r12d, edi
    test    edi, edi
    jz      .Lse_need
    call    obj_get
    test    rax, rax
    jz      .Lse_need
    cmp     dword ptr [rax+OB_TYPE], OT_MESH
    jne     .Lse_need
    mov     rbx, rax
    mov     rdi, [rbx+OB_MESH]
    test    rdi, rdi
    jz      .Lse_need
    cmp     dword ptr [rdi+ME_NTRIS], 0
    je      .Lse_need
    cmp     dword ptr [rip+edit_obj], 0 # (not with edit mode)
    je      1f
    call    edit_exit
1:  cmp     dword ptr [rip+sc_obj], 0
    je      2f
    call    sculpt_exit
2:  mov     rdi, rbx                    # its own mesh: copied when another
    call    shared_mesh                 #  object shows it (undo steps may
    test    eax, eax                    #  share it: strokes undo by deltas)
    jz      3f
    mov     rdi, [rbx+OB_MESH]
    call    mesh_copy
    test    rax, rax
    jz      .Lse_mem
    mov     rdi, [rbx+OB_MESH]
    mov     [rbx+OB_MESH], rax
    call    mesh_unref
3:  mov     [rip+sc_obj], r12d
    mov     rdi, rbx
    call    sculpt_build
    test    eax, eax
    jz      .Lse_mem2
    call    fmt_reset
    lea     rdi, [rip+s_entered]
    call    fmt_str
    mov     edi, [rip+sc_nt]
    call    fmt_int
    lea     rdi, [rip+s_tris]
    call    fmt_str
    mov     edi, [rip+sc_nnodes]
    call    fmt_int
    lea     rdi, [rip+s_leaves]
    call    fmt_str
    lea     rdi, [rip+fmt_buf]
    call    log_line
    mov     eax, 1
    jmp     9f
.Lse_mem2:
    mov     dword ptr [rip+sc_obj], 0
.Lse_mem:
    lea     rdi, [rip+s_nomem]
    call    log_line
    xor     eax, eax
    jmp     9f
.Lse_need:
    lea     rdi, [rip+s_need_mesh]
    call    log_line
    xor     eax, eax
9:  mov     dword ptr [rip+dirty], 1
    add     rsp, 16
    pop     r13
    pop     r12
    pop     rbx
    ret

# shared_mesh(rdi=object) -> eax = 1 if another object uses its mesh
shared_mesh:
    push    rbx
    push    r12
    push    r13
    mov     r12, rdi
    mov     r13, [rdi+OB_MESH]
    xor     ebx, ebx
1:  cmp     ebx, [rip+obj_count]
    jae     8f
    mov     edi, ebx
    call    obj_at
    cmp     rax, r12
    je      2f
    cmp     [rax+OB_MESH], r13
    je      9f
2:  inc     ebx
    jmp     1b
8:  xor     eax, eax
    jmp     3f
9:  mov     eax, 1
3:  pop     r13
    pop     r12
    pop     rbx
    ret

# sculpt_exit - the arrays go; the mesh stays as sculpted
sculpt_exit:
    sub     rsp, 8
    call    sculpt_free
    call    mr_drop
    mov     dword ptr [rip+sc_obj], 0
    mov     qword ptr [rip+sc_mesh], 0
    mov     dword ptr [rip+sc_stroking], 0
    mov     dword ptr [rip+dirty], 1
    add     rsp, 8
    ret

sculpt_free:
    sub     rsp, 8
    call    dyn_free
    lea     rdi, [rip+sc_nodes]
    lea     rsi, [rip+sc_nodes_b]
    call    sfree
    lea     rdi, [rip+sc_tri]
    lea     rsi, [rip+sc_tri_b]
    call    sfree
    lea     rdi, [rip+sc_vl]
    lea     rsi, [rip+sc_vl_b]
    call    sfree
    lea     rdi, [rip+sc_vn]
    lea     rsi, [rip+sc_vn_b]
    call    sfree
    lea     rdi, [rip+sc_mask]
    lea     rsi, [rip+sc_mask_b]
    call    sfree
    lea     rdi, [rip+sc_stamp]
    lea     rsi, [rip+sc_stamp_b]
    call    sfree
    lea     rdi, [rip+sc_rec]
    lea     rsi, [rip+sc_rec_b]
    call    sfree
    lea     rdi, [rip+sc_acc]
    lea     rsi, [rip+sc_acc_b]
    call    sfree
    lea     rdi, [rip+sd_nodes]
    lea     rsi, [rip+sd_nodes_b]
    call    sfree
    lea     rdi, [rip+sc_lrec]
    lea     rsi, [rip+sc_lrec_b]
    call    sfree
    lea     rdi, [rip+sc_lchg]
    lea     rsi, [rip+sc_lchg_b]
    call    sfree
    lea     rdi, [rip+sc_rbuf]
    lea     rsi, [rip+sc_rbuf_b]
    call    sfree
    lea     rdi, [rip+sc_hits]
    lea     rsi, [rip+sc_hits_b]
    call    sfree
    add     rsp, 8
    ret

# sculpt_valid -> rax = the sculpt object (rebuilt when its mesh changed
#   under us - undo of another kind, a script), or 0 (sculpt mode ends)
sculpt_valid:
    push    rbx
    mov     edi, [rip+sc_obj]
    test    edi, edi
    jz      8f
    call    obj_get
    test    rax, rax
    jz      7f
    cmp     dword ptr [rax+OB_TYPE], OT_MESH
    jne     7f
    mov     rbx, rax
    mov     rdi, rax                    # what it sculpts (multires: its
    call    mr_target                   #  level, while that stays)
    mov     rcx, rax
    cmp     rcx, [rip+sc_mesh]
    je      1f
    test    rcx, rcx
    jz      7f
    mov     rdi, rbx
    call    sculpt_build
    test    eax, eax
    jz      7f
1:  mov     rdi, rbx                    # the matrix (it may have moved)
    lea     rsi, [rip+sc_m]
    call    obj_matrix
    lea     rdi, [rip+sc_m]
    lea     rsi, [rip+sc_mi]
    call    sdf_invert
    mov     rax, rbx
    pop     rbx
    ret
7:  call    sculpt_exit
8:  xor     eax, eax
    pop     rbx
    ret

# =============================================================================
#  The hierarchy
# =============================================================================
# sculpt_build(rdi=object) -> eax = 1: leaves, vertex lists, normals
sculpt_build:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 88
    mov     rbx, rdi
    call    sculpt_free
    mov     rdi, rbx                    # (multires: a copy of its level)
    call    mr_target
    mov     r12, rax
    mov     [rip+sc_mesh], r12
    mov     eax, [r12+ME_NVERTS]
    mov     [rip+sc_nv], eax
    mov     eax, [r12+ME_NTRIS]
    mov     [rip+sc_nt], eax
    mov     rax, [r12+ME_POS]
    mov     [rip+sv_pos], rax
    mov     rax, [r12+ME_TRIS]
    mov     [rip+sv_tris], rax
    call    dyn_alloc                   # dyntopo: its own copy, with room
    test    eax, eax
    jz      .Lsb_fail
    mov     rdi, rbx
    lea     rsi, [rip+sc_m]
    call    obj_matrix
    lea     rdi, [rip+sc_m]
    lea     rsi, [rip+sc_mi]
    call    sdf_invert
    # per-vertex arrays (with dyntopo's room)
    mov     edx, [rip+sc_capv]
    imul    rdx, rdx, 12
    lea     rdi, [rip+sc_vn]
    lea     rsi, [rip+sc_vn_b]
    call    salloc
    test    rax, rax
    jz      .Lsb_fail
    mov     edx, [rip+sc_capv]
    lea     rdi, [rip+sc_mask]
    lea     rsi, [rip+sc_mask_b]
    call    salloc
    test    rax, rax
    jz      .Lsb_fail
    mov     dword ptr [rip+sc_masked], 0
    mov     edx, [rip+sc_capv]
    shl     rdx, 2
    lea     rdi, [rip+sc_stamp]
    lea     rsi, [rip+sc_stamp_b]
    call    salloc
    test    rax, rax
    jz      .Lsb_fail
    mov     edx, [rip+sc_capv]
    lea     rdi, [rip+sc_rec]
    lea     rsi, [rip+sc_rec_b]
    call    salloc
    test    rax, rax
    jz      .Lsb_fail
    # triangle ids 0 .. n, then partitioned into leaves
    mov     edx, [rip+sc_capt]
    shl     rdx, 2
    lea     rdi, [rip+sc_tri]
    lea     rsi, [rip+sc_tri_b]
    call    salloc
    test    rax, rax
    jz      .Lsb_fail
    xor     ecx, ecx
1:  cmp     ecx, [rip+sc_nt]
    jae     2f
    mov     [rax+rcx*4], ecx
    inc     ecx
    jmp     1b
2:  mov     eax, [rip+sc_nt]            # leaves: at most 2 n / LEAF + 1
    xor     edx, edx
    mov     ecx, LEAF/2
    div     ecx
    add     eax, 4
    imul    rdx, rax, ND_SZ
    mov     [rsp+64], eax               # node capacity
    lea     rdi, [rip+sc_nodes]
    lea     rsi, [rip+sc_nodes_b]
    call    salloc
    test    rax, rax
    jz      .Lsb_fail
    mov     dword ptr [rip+sc_nnodes], 0
    xor     edi, edi
    mov     esi, [rip+sc_nt]
    call    split
    # vertex lists (each leaf lists its vertices once): first count with
    #   stamps, then fill
    mov     dword ptr [rip+sc_serial], 0
    xor     ebp, ebp                    # pass
.Lsb_vpass:
    xor     r13d, r13d                  # total
    xor     r14d, r14d                  # leaf
3:  cmp     r14d, [rip+sc_nnodes]
    jae     5f
    inc     dword ptr [rip+sc_serial]
    mov     r15d, [rip+sc_serial]
    imul    eax, r14d, ND_SZ
    mov     rbx, [rip+sc_nodes]
    add     rbx, rax
    mov     [rbx+ND_VOFF], r13d
    mov     dword ptr [rsp+8], 0        # sub-pass 0: vertices no leaf took
4:  mov     ecx, [rbx+ND_TOFF]          #  yet (its own), 1: the rest
    mov     edx, [rbx+ND_TN]
    add     edx, ecx
    mov     [rsp], edx
40: cmp     ecx, [rsp]
    jae     41f
    mov     rax, [rip+sc_tri]
    mov     eax, [rax+rcx*4]
    lea     rax, [rax+rax*2]
    mov     rdx, [rip+sv_tris]
    lea     r8, [rdx+rax*4]
    xor     r9d, r9d
42: mov     eax, [r8+r9*4]
    mov     rdx, [rip+sc_stamp]
    cmp     [rdx+rax*4], r15d
    je      43f
    mov     r10, [rip+sc_rec]           # (taken: by a leaf this pass)
    cmp     dword ptr [rsp+8], 0
    jne     45f
    cmp     byte ptr [r10+rax], 0
    jne     43f
    mov     byte ptr [r10+rax], 1
45: mov     [rdx+rax*4], r15d
    test    ebp, ebp
    jz      44f
    mov     rdx, [rip+sc_vl]
    mov     [rdx+r13*4], eax
44: inc     r13d
43: inc     r9d
    cmp     r9d, 3
    jb      42b
    inc     ecx
    jmp     40b
41: cmp     dword ptr [rsp+8], 0
    jne     46f
    mov     eax, r13d
    sub     eax, [rbx+ND_VOFF]
    mov     [rbx+ND_VOWN], eax
    mov     dword ptr [rsp+8], 1
    jmp     4b
46: mov     eax, r13d
    sub     eax, [rbx+ND_VOFF]
    mov     [rbx+ND_VN], eax
    inc     r14d
    jmp     3b
5:  mov     rdi, [rip+sc_rec]           # (taken marks off for each pass)
    mov     ecx, [rip+sc_nv]
    xor     eax, eax
    rep     stosb
    test    ebp, ebp
    jnz     6f
    mov     [rip+sc_nvl], r13d
    mov     edx, r13d
    cmp     dword ptr [rip+sc_dyn], 0   # (dyntopo: room for the lists to
    je      51f                         #  move as they grow)
    lea     edx, [rdx+rdx+65536]
51: shl     rdx, 2
    lea     rdi, [rip+sc_vl]
    lea     rsi, [rip+sc_vl_b]
    call    salloc
    test    rax, rax
    jz      .Lsb_fail
    mov     ebp, 1
    jmp     .Lsb_vpass
6:  call    dyn_tail                    # pool room, owners, a carried mask
    # boxes, the longest edge, all normals; drawing records
    xor     r14d, r14d
7:  cmp     r14d, [rip+sc_nnodes]
    jae     8f
    mov     edi, r14d
    call    node_box
    inc     r14d
    jmp     7b
8:  call    max_edge
    call    normals_all
    mov     edx, [rip+sc_nnodes]
    shl     rdx, 5
    lea     rdi, [rip+sd_nodes]
    lea     rsi, [rip+sd_nodes_b]
    call    salloc
    test    rax, rax
    jz      .Lsb_fail
    mov     edx, [rip+sc_nnodes]
    shl     rdx, 4
    lea     rdi, [rip+sc_lrec]
    lea     rsi, [rip+sc_lrec_b]
    call    salloc
    test    rax, rax
    jz      .Lsb_fail
    mov     edx, [rip+sc_nnodes]
    lea     rdi, [rip+sc_lchg]
    lea     rsi, [rip+sc_lchg_b]
    call    salloc
    test    rax, rax
    jz      .Lsb_fail
    mov     dword ptr [rip+sc_full], 1
    mov     edx, [rip+sc_nnodes]        # leaves in reach: three lists
    imul    rdx, rdx, 12
    lea     rdi, [rip+sc_hits]
    lea     rsi, [rip+sc_hits_b]
    call    salloc
    test    rax, rax
    jz      .Lsb_fail
    mov     eax, 1
    jmp     .Lsb_out
.Lsb_fail:
    call    sculpt_free
    xor     eax, eax
.Lsb_out:
    add     rsp, 88
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# cent(eax=triangle, ecx=axis) -> xmm0 = 3 x its centroid's coordinate
cent:
    lea     rax, [rax+rax*2]
    mov     rdx, [rip+sv_tris]
    lea     rdx, [rdx+rax*4]
    mov     r8, [rip+sv_pos]
    mov     eax, [rdx]
    lea     rax, [rax+rax*2]
    lea     rax, [r8+rax*4]
    movss   xmm0, [rax+rcx*4]
    mov     eax, [rdx+4]
    lea     rax, [rax+rax*2]
    lea     rax, [r8+rax*4]
    addss   xmm0, [rax+rcx*4]
    mov     eax, [rdx+8]
    lea     rax, [rax+rax*2]
    lea     rax, [r8+rax*4]
    addss   xmm0, [rax+rcx*4]
    ret

# split(edi=first, esi=end in sc_tri) - leaves of at most LEAF triangles:
#   halves by the middle of the centroids' box on its longest side (by
#   count when they all sit together). An explicit stack.
split:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 600                    # stack of ranges (64 deep)
    mov     [rsp], edi
    mov     [rsp+4], esi
    mov     ebp, 1                      # entries
.Lsp_pop:
    test    ebp, ebp
    jz      .Lsp_out
    dec     ebp
    mov     r12d, [rsp+rbp*8]
    mov     r13d, [rsp+rbp*8+4]
    mov     eax, r13d
    sub     eax, r12d
    cmp     eax, LEAF
    ja      .Lsp_cut
    mov     eax, [rip+sc_nnodes]        # a leaf
    imul    ecx, eax, ND_SZ
    mov     rdx, [rip+sc_nodes]
    add     rdx, rcx
    mov     [rdx+ND_TOFF], r12d
    mov     ecx, r13d
    sub     ecx, r12d
    mov     [rdx+ND_TN], ecx
    mov     dword ptr [rdx+ND_FLAGS], 0
    inc     dword ptr [rip+sc_nnodes]
    jmp     .Lsp_pop
.Lsp_cut:
    movss   xmm4, [rip+sf_big]          # the centroids' box
    movss   xmm5, xmm4
    movss   xmm6, xmm4
    movss   xmm1, [rip+sf_nbig]
    movss   [rsp+520], xmm1
    movss   [rsp+524], xmm1
    movss   [rsp+528], xmm1
    mov     r14d, r12d
1:  cmp     r14d, r13d
    jae     2f
    mov     rax, [rip+sc_tri]
    mov     ebx, [rax+r14*4]
    xor     ecx, ecx
11: mov     eax, ebx
    push    rcx
    call    cent
    pop     rcx
    cmp     ecx, 1
    je      12f
    ja      13f
    minss   xmm4, xmm0
    jmp     14f
12: minss   xmm5, xmm0
    jmp     14f
13: minss   xmm6, xmm0
14: movss   xmm1, [rsp+520+rcx*4]
    maxss   xmm1, xmm0
    movss   [rsp+520+rcx*4], xmm1
    inc     ecx
    cmp     ecx, 3
    jb      11b
    inc     r14d
    jmp     1b
2:  movss   [rsp+508], xmm4
    movss   [rsp+512], xmm5
    movss   [rsp+516], xmm6
    xor     r15d, r15d                  # the longest axis
    movss   xmm7, [rsp+520]
    subss   xmm7, [rsp+508]
    mov     ecx, 1
21: movss   xmm1, [rsp+520+rcx*4]
    subss   xmm1, [rsp+508+rcx*4]
    comiss  xmm1, xmm7
    jbe     22f
    movss   xmm7, xmm1
    mov     r15d, ecx
22: inc     ecx
    cmp     ecx, 3
    jb      21b
    movss   xmm2, [rsp+520+r15*4]       # the middle
    addss   xmm2, [rsp+508+r15*4]
    mulss   xmm2, [rip+sf_half]
    movss   [rsp+504], xmm2
    mov     r14d, r12d                  # partition: [lo, i) below the middle
    mov     ebx, r13d
3:  cmp     r14d, ebx
    jae     5f
    mov     rax, [rip+sc_tri]
    mov     eax, [rax+r14*4]
    mov     ecx, r15d
    call    cent
    comiss  xmm0, [rsp+504]
    jae     4f
    inc     r14d
    jmp     3b
4:  dec     ebx                         # swap with the end
    mov     rax, [rip+sc_tri]
    mov     ecx, [rax+r14*4]
    mov     edx, [rax+rbx*4]
    mov     [rax+r14*4], edx
    mov     [rax+rbx*4], ecx
    jmp     3b
5:  cmp     r14d, r12d                  # one side empty: by count
    je      51f
    cmp     r14d, r13d
    jne     52f
51: mov     r14d, r13d
    sub     r14d, r12d
    shr     r14d, 1
    add     r14d, r12d
52: cmp     ebp, 60                     # (the stack is deep enough for any
    jb      53f                         #  mesh this side of 2^60 triangles)
    mov     eax, [rip+sc_nnodes]        #  - else a leaf as it is
    imul    ecx, eax, ND_SZ
    mov     rdx, [rip+sc_nodes]
    add     rdx, rcx
    mov     [rdx+ND_TOFF], r12d
    mov     ecx, r13d
    sub     ecx, r12d
    mov     [rdx+ND_TN], ecx
    inc     dword ptr [rip+sc_nnodes]
    jmp     .Lsp_pop
53: mov     [rsp+rbp*8], r12d
    mov     [rsp+rbp*8+4], r14d
    inc     ebp
    mov     [rsp+rbp*8], r14d
    mov     [rsp+rbp*8+4], r13d
    inc     ebp
    jmp     .Lsp_pop
.Lsp_out:
    add     rsp, 600
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# node_box(edi=leaf) - its box from its vertices
node_box:
    imul    eax, edi, ND_SZ
    mov     rdx, [rip+sc_nodes]
    add     rdx, rax
    movss   xmm0, [rip+sf_big]
    movss   xmm1, xmm0
    movss   xmm2, xmm0
    movss   xmm3, [rip+sf_nbig]
    movss   xmm4, xmm3
    movss   xmm5, xmm3
    mov     ecx, [rdx+ND_VOFF]
    mov     r8d, [rdx+ND_VN]
    add     r8d, ecx
    mov     r9, [rip+sc_vl]
    mov     r10, [rip+sv_pos]
1:  cmp     ecx, r8d
    jae     2f
    mov     eax, [r9+rcx*4]
    lea     rax, [rax+rax*2]
    minss   xmm0, [r10+rax*4]
    maxss   xmm3, [r10+rax*4]
    minss   xmm1, [r10+rax*4+4]
    maxss   xmm4, [r10+rax*4+4]
    minss   xmm2, [r10+rax*4+8]
    maxss   xmm5, [r10+rax*4+8]
    inc     ecx
    jmp     1b
2:  movss   [rdx+ND_MIN], xmm0
    movss   [rdx+ND_MIN+4], xmm1
    movss   [rdx+ND_MIN+8], xmm2
    movss   [rdx+ND_MAX], xmm3
    movss   [rdx+ND_MAX+4], xmm4
    movss   [rdx+ND_MAX+8], xmm5
    ret

# max_edge - sc_maxedge = the longest triangle edge
max_edge:
    xorps   xmm7, xmm7
    mov     r9, [rip+sv_tris]
    mov     r10, [rip+sv_pos]
    xor     ecx, ecx
1:  cmp     ecx, [rip+sc_nt]
    jae     9f
    lea     rax, [rcx+rcx*2]
    mov     r8d, [r9+rax*4]
    mov     r11d, [r9+rax*4+4]
    call    elen2
    mov     r8d, [r9+rax*4+4]
    mov     r11d, [r9+rax*4+8]
    call    elen2
    mov     r8d, [r9+rax*4+8]
    mov     r11d, [r9+rax*4]
    call    elen2
    inc     ecx
    jmp     1b
9:  sqrtss  xmm7, xmm7
    movss   [rip+sc_maxedge], xmm7
    ret
# elen2(r8d, r11d) - xmm7 = max(xmm7, |a - b|^2) (keeps rax, rcx)
elen2:
    lea     r8, [r8+r8*2]
    lea     r11, [r11+r11*2]
    movss   xmm0, [r10+r8*4]
    subss   xmm0, [r10+r11*4]
    mulss   xmm0, xmm0
    movss   xmm1, [r10+r8*4+4]
    subss   xmm1, [r10+r11*4+4]
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    movss   xmm1, [r10+r8*4+8]
    subss   xmm1, [r10+r11*4+8]
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    maxss   xmm7, xmm0
    ret

# face_n(eax=triangle) -> xmm0..2 = (b - a) x (c - a) (twice the area)
face_n:
    lea     rax, [rax+rax*2]
    mov     rdx, [rip+sv_tris]
    lea     rdx, [rdx+rax*4]
    mov     r8, [rip+sv_pos]
    mov     eax, [rdx]
    lea     rax, [rax+rax*2]
    lea     r9, [r8+rax*4]
    mov     eax, [rdx+4]
    lea     rax, [rax+rax*2]
    lea     r10, [r8+rax*4]
    mov     eax, [rdx+8]
    lea     rax, [rax+rax*2]
    lea     r11, [r8+rax*4]
    movss   xmm3, [r10]
    subss   xmm3, [r9]
    movss   xmm4, [r10+4]
    subss   xmm4, [r9+4]
    movss   xmm5, [r10+8]
    subss   xmm5, [r9+8]
    movss   xmm6, [r11]
    subss   xmm6, [r9]
    movss   xmm7, [r11+4]
    subss   xmm7, [r9+4]
    movss   xmm8, [r11+8]
    subss   xmm8, [r9+8]
    movss   xmm0, xmm4
    mulss   xmm0, xmm8
    movss   xmm9, xmm5
    mulss   xmm9, xmm7
    subss   xmm0, xmm9
    movss   xmm1, xmm5
    mulss   xmm1, xmm6
    movss   xmm9, xmm3
    mulss   xmm9, xmm8
    subss   xmm1, xmm9
    movss   xmm2, xmm3
    mulss   xmm2, xmm7
    movss   xmm9, xmm4
    mulss   xmm9, xmm6
    subss   xmm2, xmm9
    ret

# normals_all - every vertex normal (area-weighted, unit)
normals_all:
    mov     dword ptr [rip+sc_full], 1
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rdi, [rip+sc_vn]
    mov     ecx, [rip+sc_nv]
    imul    ecx, ecx, 3
    xor     eax, eax
    rep     stosd
    xor     ebx, ebx
1:  cmp     ebx, [rip+sc_nt]
    jae     2f
    mov     eax, ebx
    call    face_n
    lea     rax, [rbx+rbx*2]
    mov     rdx, [rip+sv_tris]
    lea     r12, [rdx+rax*4]
    mov     ecx, [r12]
    call    vn_add
    mov     ecx, [r12+4]
    call    vn_add
    mov     ecx, [r12+8]
    call    vn_add
    inc     ebx
    jmp     1b
2:  xor     ecx, ecx
3:  cmp     ecx, [rip+sc_nv]
    jae     9f
    call    vn_unit
    inc     ecx
    jmp     3b
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# vn_add(ecx=vertex, xmm0..2) / vn_unit(ecx=vertex) - keep rcx
vn_add:
    lea     rax, [rcx+rcx*2]
    mov     r11, [rip+sc_vn]
    lea     r11, [r11+rax*4]
    movss   xmm3, [r11]
    addss   xmm3, xmm0
    movss   [r11], xmm3
    movss   xmm3, [r11+4]
    addss   xmm3, xmm1
    movss   [r11+4], xmm3
    movss   xmm3, [r11+8]
    addss   xmm3, xmm2
    movss   [r11+8], xmm3
    ret
vn_unit:
    lea     rax, [rcx+rcx*2]
    mov     r11, [rip+sc_vn]
    lea     r11, [r11+rax*4]
    movss   xmm0, [r11]
    mulss   xmm0, xmm0
    movss   xmm1, [r11+4]
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    movss   xmm1, [r11+8]
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    sqrtss  xmm0, xmm0
    maxss   xmm0, [rip+sf_tiny]
    movss   xmm1, [rip+sf_one]
    divss   xmm1, xmm0
    movss   xmm0, [r11]
    mulss   xmm0, xmm1
    movss   [r11], xmm0
    movss   xmm0, [r11+4]
    mulss   xmm0, xmm1
    movss   [r11+4], xmm0
    movss   xmm0, [r11+8]
    mulss   xmm0, xmm1
    movss   [r11+8], xmm0
    ret


# =============================================================================
#  Drawing
# =============================================================================
# cam_mat - sd_c = camera (right, up, fwd rows; eye at 0) x object matrix
cam_mat:
    lea     r8, [rip+sc_m]
    xor     ecx, ecx                    # row: right, up, fwd
1:  lea     rax, [rip+right]
    cmp     ecx, 1
    jne     11f
    lea     rax, [rip+up]
11: cmp     ecx, 2
    jne     12f
    lea     rax, [rip+fwd]
12: mov     edx, ecx
    shl     edx, 4
    lea     r9, [rip+sd_c]
    add     r9, rdx
    xor     r10d, r10d                  # columns 0..2: R . M[:, j]
2:  movss   xmm0, [rax]
    mulss   xmm0, [r8+r10*4]
    movss   xmm1, [rax+4]
    mulss   xmm1, [r8+16+r10*4]
    addss   xmm0, xmm1
    movss   xmm1, [rax+8]
    mulss   xmm1, [r8+32+r10*4]
    addss   xmm0, xmm1
    movss   [r9+r10*4], xmm0
    inc     r10d
    cmp     r10d, 3
    jb      2b
    movss   xmm0, [r8+12]               # R . (t - eye)
    subss   xmm0, [rip+eye]
    mulss   xmm0, [rax]
    movss   xmm1, [r8+28]
    subss   xmm1, [rip+eye+4]
    mulss   xmm1, [rax+4]
    addss   xmm0, xmm1
    movss   xmm1, [r8+44]
    subss   xmm1, [rip+eye+8]
    mulss   xmm1, [rax+8]
    addss   xmm0, xmm1
    movss   [r9+12], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      1b
    ret

# cam_scale - sd_scale = the largest column length of sd_c (local -> camera)
cam_scale:
    xorps   xmm3, xmm3
    xor     ecx, ecx
1:  lea     rax, [rip+sd_c]
    lea     rax, [rip+sd_c]
    movss   xmm0, [rax+rcx*4]
    mulss   xmm0, xmm0
    movss   xmm1, [rax+16+rcx*4]
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    movss   xmm1, [rax+32+rcx*4]
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    maxss   xmm3, xmm0
    inc     ecx
    cmp     ecx, 3
    jb      1b
    sqrtss  xmm3, xmm3
    movss   [rip+sd_scale], xmm3
    ret

# tocam(rsi=local float[3]) -> xmm0, xmm1, xmm2 = camera x, y, z
tocam:
    movss   xmm3, [rsi]
    movss   xmm4, [rsi+4]
    movss   xmm5, [rsi+8]
    movss   xmm0, [rip+sd_c]
    mulss   xmm0, xmm3
    movss   xmm6, [rip+sd_c+4]
    mulss   xmm6, xmm4
    addss   xmm0, xmm6
    movss   xmm6, [rip+sd_c+8]
    mulss   xmm6, xmm5
    addss   xmm0, xmm6
    addss   xmm0, [rip+sd_c+12]
    movss   xmm1, [rip+sd_c+16]
    mulss   xmm1, xmm3
    movss   xmm6, [rip+sd_c+20]
    mulss   xmm6, xmm4
    addss   xmm1, xmm6
    movss   xmm6, [rip+sd_c+24]
    mulss   xmm6, xmm5
    addss   xmm1, xmm6
    addss   xmm1, [rip+sd_c+28]
    movss   xmm2, [rip+sd_c+32]
    mulss   xmm2, xmm3
    movss   xmm6, [rip+sd_c+36]
    mulss   xmm6, xmm4
    addss   xmm2, xmm6
    movss   xmm6, [rip+sd_c+40]
    mulss   xmm6, xmm5
    addss   xmm2, xmm6
    addss   xmm2, [rip+sd_c+44]
    ret

# sculpt_draw - the sculpt object into the viewport being drawn (after the
#   rasterizer: its colour and depth buffers, rs_x0 / rs_y0 / rs_w / rs_h)
sculpt_draw:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 72
    cmp     dword ptr [rip+sc_obj], 0
    je      .Lsd_out
    cmp     dword ptr [rip+rs_w], 0
    jle     .Lsd_out
    cmp     dword ptr [rip+rs_h], 0
    jle     .Lsd_out
    call    sculpt_valid
    test    rax, rax
    jz      .Lsd_out
    call    normals_due
    call    cam_mat
    call    cam_scale
    call    view_key
    # each leaf: its screen rectangle (viewport pixels) and how to draw it
    lea     rdi, [rip+job_leaves]
    mov     esi, [rip+sc_nnodes]
    mov     edx, esi
    xor     esi, esi
    mov     ecx, 256
    call    parallel_for
    call    plan_records
    test    eax, eax
    jz      .Lsd_out
.Lsd_bin:
    # tiles -> leaves (CSR in the frame arena)
    mov     eax, [rip+rs_w]
    add     eax, TILE-1
    shr     eax, TILE_SH
    mov     [rip+sd_ntx], eax
    mov     ecx, [rip+rs_h]
    add     ecx, TILE-1
    shr     ecx, TILE_SH
    mov     [rip+sd_nty], ecx
    imul    eax, ecx
    mov     [rsp+32], eax               # tiles
    lea     rdi, [rip+frame_arena]
    lea     esi, [rax*4+8]
    call    arena_alloc
    test    rax, rax
    jz      .Lsd_out
    mov     [rip+sd_toff], rax
    mov     rdi, rax
    mov     ecx, [rsp+32]
    inc     ecx
    xor     eax, eax
    rep     stosd
    xor     r15d, r15d                  # pass 0: count, 1: fill
.Lsd_pass:
    xor     r12d, r12d
7:  cmp     r12d, [rip+sc_nnodes]
    jae     .Lsd_pend
    mov     r13d, r12d
    shl     r13d, 5
    add     r13, [rip+sd_nodes]
    cmp     dword ptr [r13+16], 0
    je      79f
    mov     r8d, [r13+4]                # tile rows
    shr     r8d, TILE_SH
71: mov     eax, [r13+12]
    shr     eax, TILE_SH
    cmp     r8d, eax
    ja      79f
    mov     r9d, [r13]
    shr     r9d, TILE_SH
72: mov     eax, [r13+8]
    shr     eax, TILE_SH
    cmp     r9d, eax
    ja      78f
    mov     eax, r8d
    imul    eax, [rip+sd_ntx]
    add     eax, r9d
    mov     rcx, [rip+sd_toff]
    test    r15d, r15d
    jnz     73f
    inc     dword ptr [rcx+rax*4+4]
    jmp     74f
73: mov     edx, [rcx+rax*4]
    inc     dword ptr [rcx+rax*4]
    mov     rcx, [rip+sd_tlist]
    mov     [rcx+rdx*4], r12d
74: inc     r9d
    jmp     72b
78: inc     r8d
    jmp     71b
79: inc     r12d
    jmp     7b
.Lsd_pend:
    test    r15d, r15d
    jnz     .Lsd_fix
    mov     rcx, [rip+sd_toff]          # prefix sums
    xor     eax, eax
    xor     edx, edx
8:  cmp     edx, [rsp+32]
    jae     81f
    add     eax, [rcx+rdx*4+4]
    mov     [rcx+rdx*4+4], eax
    inc     edx
    jmp     8b
81: lea     rdi, [rip+frame_arena]
    lea     esi, [rax*4+8]
    call    arena_alloc
    test    rax, rax
    jz      .Lsd_out
    mov     [rip+sd_tlist], rax
    mov     r15d, 1
    jmp     .Lsd_pass
.Lsd_fix:
    mov     rcx, [rip+sd_toff]
    mov     edx, [rsp+32]
9:  test    edx, edx
    jz      91f
    mov     eax, [rcx+rdx*4-4]
    mov     [rcx+rdx*4], eax
    dec     edx
    jmp     9b
91: mov     dword ptr [rcx], 0
    lea     rdi, [rip+job_proj]
    xor     esi, esi
    mov     edx, [rip+sc_nnodes]
    mov     ecx, 64
    call    parallel_for
    mov     dword ptr [rip+sc_full], 0
    lea     rdi, [rip+tile_job]
    xor     esi, esi
    mov     edx, [rsp+32]
    mov     ecx, 1
    call    parallel_for

.Lsd_out:
    add     rsp, 72
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# job_leaves(esi=begin, edx=end) - each leaf's screen rectangle from its
#   bounding sphere (one transform; conservative), culled when behind the
#   eye or off the viewport; splat or triangles; the splat stride
job_leaves:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 40
    mov     r12d, esi
    mov     r14d, edx
.Ljl_leaf:
    cmp     r12d, r14d
    jae     .Ljl_out
    imul    eax, r12d, ND_SZ
    mov     rbx, [rip+sc_nodes]
    add     rbx, rax
    mov     r13d, r12d
    shl     r13d, 5
    add     r13, [rip+sd_nodes]
    mov     dword ptr [r13+16], 0       # culled
    xorps   xmm6, xmm6                  # centre, radius
    xor     ecx, ecx
1:  movss   xmm0, [rbx+ND_MIN+rcx*4]
    movss   xmm1, [rbx+ND_MAX+rcx*4]
    movss   xmm2, xmm1
    subss   xmm2, xmm0
    mulss   xmm2, xmm2
    addss   xmm6, xmm2
    addss   xmm0, xmm1
    mulss   xmm0, [rip+sf_half]
    movss   [rsp+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      1b
    sqrtss  xmm6, xmm6
    mulss   xmm6, [rip+sf_half]
    mulss   xmm6, [rip+sd_scale]        # (in camera units)
    movss   [rsp+16], xmm6
    lea     rsi, [rsp]
    call    tocam
    movss   xmm3, xmm2                  # z of the sphere's front
    subss   xmm3, [rsp+16]
    movss   xmm4, xmm2
    addss   xmm4, [rsp+16]
    comiss  xmm4, [rip+f_near]          # wholly behind: culled
    jb      .Ljl_next
    comiss  xmm3, [rip+f_near]          # reaching behind: anywhere, triangles
    jae     2f
    mov     dword ptr [r13], 0
    mov     dword ptr [r13+4], 0
    mov     eax, [rip+rs_w]
    dec     eax
    mov     [r13+8], eax
    mov     eax, [rip+rs_h]
    dec     eax
    mov     [r13+12], eax
    mov     dword ptr [r13+16], 2
    jmp     .Ljl_next
2:  movss   xmm5, [rip+vp_focal]        # centre on screen, radius there (at
    divss   xmm5, xmm2                  #  the front: conservative)
    mulss   xmm0, xmm5
    addss   xmm0, [rip+vp_cx]
    mulss   xmm1, xmm5
    movss   xmm7, [rip+vp_cy]
    subss   xmm7, xmm1
    movss   xmm5, [rip+vp_focal]
    divss   xmm5, xmm3
    mulss   xmm5, [rsp+16]
    movss   xmm1, xmm0
    subss   xmm1, xmm5
    cvttss2si eax, xmm1
    sub     eax, [rip+rs_x0]
    movss   xmm1, xmm0
    addss   xmm1, xmm5
    cvttss2si ecx, xmm1
    sub     ecx, [rip+rs_x0]
    movss   xmm1, xmm7
    subss   xmm1, xmm5
    cvttss2si edx, xmm1
    sub     edx, [rip+rs_y0]
    movss   xmm1, xmm7
    addss   xmm1, xmm5
    cvttss2si r8d, xmm1
    sub     r8d, [rip+rs_y0]
    cmp     ecx, 0
    jl      .Ljl_next
    cmp     r8d, 0
    jl      .Ljl_next
    cmp     eax, [rip+rs_w]
    jge     .Ljl_next
    cmp     edx, [rip+rs_h]
    jge     .Ljl_next
    mov     r9d, ecx                    # pixels (before the clamp)
    sub     r9d, eax
    inc     r9d
    mov     r10d, r8d
    sub     r10d, edx
    inc     r10d
    imul    r9d, r10d
    test    eax, eax
    jns     61f
    xor     eax, eax
61: test    edx, edx
    jns     62f
    xor     edx, edx
62: mov     r10d, [rip+rs_w]
    dec     r10d
    cmp     ecx, r10d
    jle     63f
    mov     ecx, r10d
63: mov     r10d, [rip+rs_h]
    dec     r10d
    cmp     r8d, r10d
    jle     64f
    mov     r8d, r10d
64: mov     [r13], eax
    mov     [r13+4], edx
    mov     [r13+8], ecx
    mov     [r13+12], r8d
    mov     eax, [rbx+ND_VN]            # splat when 2 vertices or more a
    shr     eax, 1                      #  pixel (fewer leave holes)
    mov     dword ptr [r13+16], 1
    mov     dword ptr [r13+20], 1       # (every vertex)
    cmp     r9d, eax
    ja      65f
    mov     eax, [rbx+ND_VN]            # more than 2 vertices a pixel: every
    lea     ecx, [r9+r9]                #  k-th, k = vertices / (2 pixels)
    xor     edx, edx
    test    ecx, ecx
    jz      .Ljl_next
    div     ecx
    cmp     eax, 1
    jbe     .Ljl_next
    mov     [r13+20], eax
    jmp     .Ljl_next
65: mov     dword ptr [r13+16], 2
.Ljl_next:
    inc     r12d
    jmp     .Ljl_leaf
.Ljl_out:
    add     rsp, 40
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# tile_job(rdi=ctx, esi=begin, edx=end) - draw the leaves of each tile
tile_job:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 104
    mov     [rsp], esi
    mov     [rsp+4], edx
.Ltj_tile:
    mov     eax, [rsp]
    cmp     eax, [rsp+4]
    jae     .Ltj_out
    xor     edx, edx                    # its pixel box (viewport pixels)
    div     dword ptr [rip+sd_ntx]
    shl     edx, TILE_SH
    shl     eax, TILE_SH
    mov     [rsp+8], edx                # x0
    mov     [rsp+12], eax               # y0
    add     edx, TILE
    cmp     edx, [rip+rs_w]
    jle     1f
    mov     edx, [rip+rs_w]
1:  mov     [rsp+16], edx               # x1 (exclusive)
    add     eax, TILE
    cmp     eax, [rip+rs_h]
    jle     2f
    mov     eax, [rip+rs_h]
2:  mov     [rsp+20], eax               # y1
    mov     eax, [rsp]
    mov     rcx, [rip+sd_toff]
    mov     r12d, [rcx+rax*4]
    mov     r13d, [rcx+rax*4+4]
3:  cmp     r12d, r13d
    jae     .Ltj_next
    mov     rcx, [rip+sd_tlist]
    mov     r14d, [rcx+r12*4]           # leaf
    mov     eax, r14d
    shl     eax, 5
    add     rax, [rip+sd_nodes]
    lea     rdi, [rsp+8]
    mov     esi, r14d
    cmp     dword ptr [rax+16], 1
    jne     4f
    call    draw_splats
    jmp     5f
4:  call    draw_tris
5:  inc     r12d
    jmp     3b
.Ltj_next:
    inc     dword ptr [rsp]
    jmp     .Ltj_tile
.Ltj_out:
    add     rsp, 104
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# shade(xmm0..2 = local normal, any length; ecx = vertex or -1) -> eax =
#   colour
#   (two-sided headlight in camera space; masked vertices darker)
shade:
    movss   xmm3, [rip+sd_c+32]         # camera z of the normal
    mulss   xmm3, xmm0
    movss   xmm4, [rip+sd_c+36]
    mulss   xmm4, xmm1
    addss   xmm3, xmm4
    movss   xmm4, [rip+sd_c+40]
    mulss   xmm4, xmm2
    addss   xmm3, xmm4
    movss   xmm4, [rip+sd_c+32]         # |rotated n| (the scale)
    mulss   xmm4, xmm4
    movss   xmm5, [rip+sd_c+36]
    mulss   xmm5, xmm5
    addss   xmm4, xmm5
    movss   xmm5, [rip+sd_c+40]
    mulss   xmm5, xmm5
    addss   xmm4, xmm5
    movss   xmm5, xmm0                  # |n| (face normals are not unit)
    mulss   xmm5, xmm0
    movss   xmm6, xmm1
    mulss   xmm6, xmm1
    addss   xmm5, xmm6
    movss   xmm6, xmm2
    mulss   xmm6, xmm2
    addss   xmm5, xmm6
    mulss   xmm4, xmm5
    sqrtss  xmm4, xmm4
    maxss   xmm4, [rip+sf_tiny]
    divss   xmm3, xmm4
    andps   xmm3, [rip+sf_abs]
    minss   xmm3, [rip+sf_one]
    mulss   xmm3, [rip+sf_dif]
    addss   xmm3, [rip+sf_amb]
    test    ecx, ecx
    js      1f
    cmp     dword ptr [rip+sc_masked], 0
    je      1f
    mov     rax, [rip+sc_mask]
    movzx   eax, byte ptr [rax+rcx]
    test    eax, eax
    jz      1f
    cvtsi2ss xmm4, eax                  # masked: towards dark
    mulss   xmm4, [rip+sf_mask]
    mulss   xmm4, [rip+mask_k]
    movss   xmm5, [rip+sf_one]
    subss   xmm5, xmm4
    mulss   xmm3, xmm5
1:  mulss   xmm3, [rip+sf_255]
    movss   xmm4, xmm3
    mulss   xmm4, [rip+clay_r]
    cvttss2si eax, xmm4
    shl     eax, 16
    movss   xmm4, xmm3
    mulss   xmm4, [rip+clay_g]
    cvttss2si edx, xmm4
    shl     edx, 8
    or      eax, edx
    movss   xmm4, xmm3
    mulss   xmm4, [rip+clay_b]
    cvttss2si edx, xmm4
    or      eax, edx
    ret

# plot(r8d=x, r9d=y viewport, xmm7=1/z, eax=colour) - depth tested
plot:
    mov     r10d, r9d
    imul    r10d, [rip+rs_w]
    add     r10d, r8d
    mov     r11, [rip+rs_depth]
    comiss  xmm7, [r11+r10*4]
    jbe     1f
    movss   [r11+r10*4], xmm7
    mov     r10d, [rip+rs_y0]
    add     r10d, r9d
    imul    r10d, [rip+fb_w]
    add     r10d, [rip+rs_x0]
    add     r10d, r8d
    mov     r11, [rip+fb_ptr]
    mov     [r11+r10*4], eax
1:  ret

# view_key - the view the splat records depend on; another one: all again
view_key:
    lea     rdi, [rip+sd_knew]
    lea     rsi, [rip+sd_c]
    mov     ecx, 12
    rep     movsd
    mov     eax, [rip+rs_x0]
    mov     [rdi], eax
    mov     eax, [rip+rs_y0]
    mov     [rdi+4], eax
    mov     eax, [rip+rs_w]
    mov     [rdi+8], eax
    mov     eax, [rip+rs_h]
    mov     [rdi+12], eax
    mov     eax, [rip+vp_focal]
    mov     [rdi+16], eax
    mov     eax, [rip+vp_cx]
    mov     [rdi+20], eax
    mov     eax, [rip+vp_cy]
    mov     [rdi+24], eax
    mov     eax, [rip+f_near]
    mov     [rdi+28], eax
    lea     rsi, [rip+sd_knew]
    lea     rdi, [rip+sd_key]
    mov     ecx, 20
    repe    cmpsd
    je      9f
    lea     rsi, [rip+sd_knew]
    lea     rdi, [rip+sd_key]
    mov     ecx, 20
    rep     movsd
    mov     dword ptr [rip+sc_full], 1
9:  ret

# plan_records -> eax = 0: no memory. Each splat leaf's room in the records:
#   kept while the view stays (a leaf that changed and needs more goes to the
#   end, into the quarter kept spare), else all laid out again
plan_records:
    push    rbx
    push    r12
    push    r13
    cmp     dword ptr [rip+sc_full], 0
    jne     .Lpr_all
    xor     ebx, ebx
1:  cmp     ebx, [rip+sc_nnodes]
    jae     .Lpr_ok
    mov     r12d, ebx
    shl     r12d, 5
    add     r12, [rip+sd_nodes]
    mov     r13d, ebx
    shl     r13d, 4
    add     r13, [rip+sc_lrec]
    cmp     dword ptr [r12+16], 1
    je      2f
    mov     dword ptr [r13+12], 0       # not splats: no records to keep
    jmp     3f
2:  mov     eax, [r12+20]
    cmp     eax, [r13+12]
    jne     22f
    mov     rcx, [rip+sc_lchg]          # the same stride and unchanged: the
    cmp     byte ptr [rcx+rbx], 0       #  same room (changed: dyntopo may
    je      3f                          #  have given it more vertices)
22:     imul    ecx, ebx, ND_SZ             # changed (grown, shrunk, now splats):
    add     rcx, [rip+sc_nodes]         #  its room, if it fits, else at the
    mov     eax, [rcx+ND_VN]            #  end, else everything again
    xor     edx, edx
    div     dword ptr [r12+20]
    inc     eax
    cmp     eax, [r13+4]
    jbe     21f
    mov     ecx, [rip+sc_rused]
    lea     edx, [rcx+rax]
    mov     rsi, [rip+sc_rbuf_b]
    shr     rsi, 4
    cmp     rdx, rsi
    ja      .Lpr_all
    mov     [r13], ecx
    mov     [r13+4], eax
    mov     [rip+sc_rused], edx
21: mov     eax, [r12+20]
    mov     [r13+12], eax
    mov     rcx, [rip+sc_lchg]
    mov     byte ptr [rcx+rbx], 1
3:  inc     ebx
    jmp     1b
.Lpr_all:
    mov     dword ptr [rip+sc_full], 1
    xor     ebx, ebx
    xor     r8d, r8d                    # records
1:  cmp     ebx, [rip+sc_nnodes]
    jae     4f
    mov     r12d, ebx
    shl     r12d, 5
    add     r12, [rip+sd_nodes]
    mov     r13d, ebx
    shl     r13d, 4
    add     r13, [rip+sc_lrec]
    mov     dword ptr [r13+12], 0
    mov     dword ptr [r13+8], 0
    mov     dword ptr [r13+4], 0
    cmp     dword ptr [r12+16], 1
    jne     3f
    imul    eax, ebx, ND_SZ
    add     rax, [rip+sc_nodes]
    mov     eax, [rax+ND_VN]
    xor     edx, edx
    div     dword ptr [r12+20]
    inc     eax
    mov     [r13], r8d
    mov     [r13+4], eax
    add     r8d, eax
    mov     eax, [r12+20]
    mov     [r13+12], eax
3:  inc     ebx
    jmp     1b
4:  mov     [rip+sc_rused], r8d
    shl     r8, 4
    cmp     r8, [rip+sc_rbuf_b]
    jbe     .Lpr_ok
    push    r8
    lea     rdi, [rip+sc_rbuf]
    lea     rsi, [rip+sc_rbuf_b]
    call    sfree
    pop     rdx
    mov     rax, rdx                    # (a quarter more: room to grow)
    shr     rax, 2
    add     rdx, rax
    lea     rdi, [rip+sc_rbuf]
    lea     rsi, [rip+sc_rbuf_b]
    call    salloc
    test    rax, rax
    jz      .Lpr_fail
.Lpr_ok:
    mov     eax, 1
    pop     r13
    pop     r12
    pop     rbx
    ret
.Lpr_fail:
    mov     qword ptr [rip+sc_rbuf_b], 0
    xor     eax, eax
    pop     r13
    pop     r12
    pop     rbx
    ret

# job_proj(esi=begin, edx=end) - each splat leaf's sampled vertices projected
#   and shaded once into its records (the tiles it covers only depth-test
#   them); while the view stays, only the leaves that changed
job_proj:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 40
    mov     [rsp+16], esi
    mov     [rsp+20], edx
.Ljp_leaf:
    mov     eax, [rsp+16]
    cmp     eax, [rsp+20]
    jae     .Ljp_out
    mov     rcx, [rip+sc_lchg]          # (changed: drawn from now on)
    movzx   edx, byte ptr [rcx+rax]
    mov     byte ptr [rcx+rax], 0
    or      edx, [rip+sc_full]
    jz      .Ljp_next
    mov     ebp, eax
    shl     ebp, 5
    add     rbp, [rip+sd_nodes]
    cmp     dword ptr [rbp+16], 1
    jne     .Ljp_next
    mov     ecx, eax
    shl     ecx, 4
    add     rcx, [rip+sc_lrec]
    mov     [rsp+24], rcx
    imul    eax, ND_SZ
    mov     rdx, [rip+sc_nodes]
    add     rdx, rax
    mov     r12d, [rdx+ND_VOFF]
    mov     r13d, [rdx+ND_VN]
    add     r13d, r12d
    mov     ebx, [rcx]
    shl     rbx, 4
    add     rbx, [rip+sc_rbuf]
    mov     [rsp+8], rbx
1:  cmp     r12d, r13d
    jae     9f
    mov     rax, [rip+sc_vl]
    mov     r14d, [rax+r12*4]           # vertex
    lea     rax, [r14+r14*2]
    shl     rax, 2
    mov     rsi, [rip+sv_pos]
    add     rsi, rax
    mov     r15, rax
    call    tocam
    comiss  xmm2, [rip+f_near]
    jb      8f
    movss   xmm7, [rip+sf_one]
    divss   xmm7, xmm2                  # 1/z
    movss   xmm3, xmm7
    mulss   xmm3, [rip+vp_focal]
    mulss   xmm0, xmm3
    addss   xmm0, [rip+vp_cx]
    mulss   xmm1, xmm3
    movss   xmm4, [rip+vp_cy]
    subss   xmm4, xmm1
    cvttss2si r8d, xmm0
    cvttss2si r9d, xmm4
    sub     r8d, [rip+rs_x0]
    sub     r9d, [rip+rs_y0]
    cmp     r8d, [rbp]                  # (inside the leaf's clamped box)
    jl      8f
    cmp     r8d, [rbp+8]
    jg      8f
    cmp     r9d, [rbp+4]
    jl      8f
    cmp     r9d, [rbp+12]
    jg      8f
    mov     [rbx], r8d
    mov     [rbx+4], r9d
    movss   [rbx+8], xmm7
    mov     rax, [rip+sc_vn]
    movss   xmm0, [rax+r15]
    movss   xmm1, [rax+r15+4]
    movss   xmm2, [rax+r15+8]
    mov     ecx, r14d
    call    shade
    mov     [rbx+12], eax
    add     rbx, 16
8:  add     r12d, [rbp+20]
    jmp     1b
9:  sub     rbx, [rsp+8]
    shr     rbx, 4
    mov     rcx, [rsp+24]
    mov     [rcx+8], ebx
.Ljp_next:
    inc     dword ptr [rsp+16]
    jmp     .Ljp_leaf
.Ljp_out:
    add     rsp, 40
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# draw_splats(rdi=tile box x0 y0 x1 y1, esi=leaf) - its records in the tile
draw_splats:
    mov     eax, esi
    shl     eax, 4
    add     rax, [rip+sc_lrec]
    mov     ecx, [rax+8]
    mov     esi, [rax]
    shl     rsi, 4
    add     rsi, [rip+sc_rbuf]
    shl     rcx, 4
    add     rcx, rsi
    mov     r11, [rip+rs_depth]
1:  cmp     rsi, rcx
    jae     9f
    mov     r8d, [rsi]
    mov     r9d, [rsi+4]
    cmp     r8d, [rdi]
    jl      8f
    cmp     r8d, [rdi+8]
    jge     8f
    cmp     r9d, [rdi+4]
    jl      8f
    cmp     r9d, [rdi+12]
    jge     8f
    mov     r10d, r9d
    imul    r10d, [rip+rs_w]
    add     r10d, r8d
    movss   xmm7, [rsi+8]
    comiss  xmm7, [r11+r10*4]
    jbe     8f
    movss   [r11+r10*4], xmm7
    mov     r10d, [rip+rs_y0]
    add     r10d, r9d
    imul    r10d, [rip+fb_w]
    add     r10d, [rip+rs_x0]
    add     r10d, r8d
    mov     rdx, [rip+fb_ptr]
    mov     eax, [rsi+12]
    mov     [rdx+r10*4], eax
8:  add     rsi, 16
    jmp     1b
9:  ret

# draw_tris(rdi=tile box, esi=leaf) - its triangles, flat shaded, clipped to
#   the tile (triangles reaching behind the eye are skipped)
draw_tris:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 104
    mov     rbx, rdi
    imul    eax, esi, ND_SZ
    mov     rdx, [rip+sc_nodes]
    add     rdx, rax
    mov     r12d, [rdx+ND_TOFF]
    mov     r13d, [rdx+ND_TN]
    add     r13d, r12d
.Ldt_tri:
    cmp     r12d, r13d
    jae     .Ldt_out
    mov     rax, [rip+sc_tri]
    mov     r14d, [rax+r12*4]           # triangle
    xor     r15d, r15d                  # corners: screen x, y, 1/z
.Ldt_corner:
    lea     rax, [r14+r14*2]
    add     rax, r15
    mov     rdx, [rip+sv_tris]
    mov     eax, [rdx+rax*4]
    lea     rax, [rax+rax*2]
    shl     rax, 2
    mov     rsi, [rip+sv_pos]
    add     rsi, rax
    call    tocam
    comiss  xmm2, [rip+f_near]
    jb      .Ldt_next
    movss   xmm7, [rip+sf_one]
    divss   xmm7, xmm2
    movss   xmm3, xmm7
    mulss   xmm3, [rip+vp_focal]
    mulss   xmm0, xmm3
    addss   xmm0, [rip+vp_cx]
    cvtsi2ss xmm5, dword ptr [rip+rs_x0]
    subss   xmm0, xmm5
    mulss   xmm1, xmm3
    movss   xmm4, [rip+vp_cy]
    subss   xmm4, xmm1
    cvtsi2ss xmm5, dword ptr [rip+rs_y0]
    subss   xmm4, xmm5
    imul    eax, r15d, 12
    movss   [rsp+rax], xmm0
    movss   [rsp+rax+4], xmm4
    movss   [rsp+rax+8], xmm7
    inc     r15d
    cmp     r15d, 3
    jb      .Ldt_corner
    # area (signed, either side drawn)
    movss   xmm0, [rsp+12]
    subss   xmm0, [rsp]
    movss   xmm1, [rsp+28]
    subss   xmm1, [rsp+4]
    mulss   xmm0, xmm1
    movss   xmm1, [rsp+16]
    subss   xmm1, [rsp+4]
    movss   xmm2, [rsp+24]
    subss   xmm2, [rsp]
    mulss   xmm1, xmm2
    subss   xmm0, xmm1
    movss   [rsp+36], xmm0
    andps   xmm0, [rip+sf_abs]
    comiss  xmm0, [rip+sf_tiny]
    jbe     .Ldt_next
    mov     eax, r14d                   # its colour
    call    face_n
    mov     ecx, -1
    call    shade
    mov     [rsp+40], eax
    # the box, within the tile
    movss   xmm0, [rsp]
    minss   xmm0, [rsp+12]
    minss   xmm0, [rsp+24]
    cvttss2si eax, xmm0
    cmp     eax, [rbx]
    jge     1f
    mov     eax, [rbx]
1:  mov     [rsp+44], eax
    movss   xmm0, [rsp]
    maxss   xmm0, [rsp+12]
    maxss   xmm0, [rsp+24]
    cvttss2si eax, xmm0
    inc     eax
    cmp     eax, [rbx+8]
    jle     2f
    mov     eax, [rbx+8]
2:  mov     [rsp+48], eax
    movss   xmm0, [rsp+4]
    minss   xmm0, [rsp+16]
    minss   xmm0, [rsp+28]
    cvttss2si eax, xmm0
    cmp     eax, [rbx+4]
    jge     3f
    mov     eax, [rbx+4]
3:  mov     [rsp+52], eax
    movss   xmm0, [rsp+4]
    maxss   xmm0, [rsp+16]
    maxss   xmm0, [rsp+28]
    cvttss2si eax, xmm0
    inc     eax
    cmp     eax, [rbx+12]
    jle     4f
    mov     eax, [rbx+12]
4:  mov     [rsp+56], eax
    mov     r9d, [rsp+52]               # y
.Ldt_row:
    cmp     r9d, [rsp+56]
    jge     .Ldt_next
    mov     r8d, [rsp+44]               # x
.Ldt_px:
    cmp     r8d, [rsp+48]
    jge     .Ldt_rnext
    cvtsi2ss xmm6, r8d
    addss   xmm6, [rip+sf_half]
    cvtsi2ss xmm7, r9d
    addss   xmm7, [rip+sf_half]
    lea     rdi, [rsp+12]               # weights: edge (b c) for a, (c a)
    lea     rsi, [rsp+24]               #  for b, (a b) for c, over the area
    call    edge2
    divss   xmm0, [rsp+36]
    movss   [rsp+60], xmm0
    lea     rdi, [rsp+24]
    lea     rsi, [rsp]
    call    edge2
    divss   xmm0, [rsp+36]
    movss   [rsp+64], xmm0
    lea     rdi, [rsp]
    lea     rsi, [rsp+12]
    call    edge2
    divss   xmm0, [rsp+36]
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    jb      .Ldt_pnext
    movss   xmm2, [rsp+60]
    comiss  xmm2, xmm1
    jb      .Ldt_pnext
    movss   xmm2, [rsp+64]
    comiss  xmm2, xmm1
    jb      .Ldt_pnext
    mulss   xmm0, [rsp+32]              # 1/z interpolated
    movss   xmm7, [rsp+60]
    mulss   xmm7, [rsp+8]
    addss   xmm7, xmm0
    movss   xmm0, [rsp+64]
    mulss   xmm0, [rsp+20]
    addss   xmm7, xmm0
    mov     eax, [rsp+40]
    push    r8
    push    r9
    call    plot
    pop     r9
    pop     r8
.Ldt_pnext:
    inc     r8d
    jmp     .Ldt_px
.Ldt_rnext:
    inc     r9d
    jmp     .Ldt_row
.Ldt_next:
    inc     r12d
    jmp     .Ldt_tri
.Ldt_out:
    add     rsp, 104
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# edge2(rdi=p, rsi=q (x, y floats); xmm6, xmm7 = point) -> xmm0
edge2:
    movss   xmm0, [rsi]
    subss   xmm0, [rdi]
    movss   xmm1, xmm7
    subss   xmm1, [rdi+4]
    mulss   xmm0, xmm1
    movss   xmm1, [rsi+4]
    subss   xmm1, [rdi+4]
    movss   xmm2, xmm6
    subss   xmm2, [rdi]
    mulss   xmm1, xmm2
    subss   xmm0, xmm1
    ret


# =============================================================================
#  Picking: the pointer's ray against the leaves' triangles (local space)
# =============================================================================
# pick(edi, esi = logical pointer) -> eax = 1: pk_p (hit, local), pk_t
pick:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 88
    mov     ebx, esi
    call    to_px
    cvtsi2ss xmm0, eax
    mov     edi, ebx
    call    to_px
    cvtsi2ss xmm1, eax
    subss   xmm0, [rip+vp_cx]           # world direction: right u + up v + fwd
    divss   xmm0, [rip+vp_focal]
    movss   xmm2, [rip+vp_cy]
    subss   xmm2, xmm1
    divss   xmm2, [rip+vp_focal]
    xor     ecx, ecx
1:  lea     rax, [rip+right]
    movss   xmm3, [rax+rcx*4]
    mulss   xmm3, xmm0
    lea     rax, [rip+up]
    movss   xmm4, [rax+rcx*4]
    mulss   xmm4, xmm2
    addss   xmm3, xmm4
    lea     rax, [rip+fwd]
    addss   xmm3, [rax+rcx*4]
    movss   [rsp+rcx*4], xmm3           # world direction
    inc     ecx
    cmp     ecx, 3
    jb      1b
    lea     rdi, [rip+sc_mi]            # local origin and direction
    lea     rsi, [rip+eye]
    lea     rdx, [rip+pk_o]
    call    xform_point
    lea     rsi, [rsp]
    lea     rdx, [rip+pk_d]
    call    xform_vec
    movss   xmm0, [rip+sf_big]
    movss   [rip+pk_t], xmm0
    xor     ebp, ebp                    # hit?
    # the leaves the ray enters (into list 0, their entry t in sd_nodes'
    # spare slot), then nearest first until the best hit is nearer than the
    # next one's entry
    mov     r15, [rip+sc_hits]
    xor     r14d, r14d                  # count
    xor     r12d, r12d
.Lpk_leaf:
    cmp     r12d, [rip+sc_nnodes]
    jae     .Lpk_near
    imul    eax, r12d, ND_SZ
    mov     rbx, [rip+sc_nodes]
    add     rbx, rax
    call    slab                        # xmm0 = entry t or big
    comiss  xmm0, [rip+sf_big]
    jae     .Lpk_next
    mov     [r15+r14*4], r12d
    mov     eax, r12d
    shl     eax, 5
    add     rax, [rip+sd_nodes]
    movss   [rax+24], xmm0
    inc     r14d
.Lpk_next:
    inc     r12d
    jmp     .Lpk_leaf
.Lpk_near:
    test    r14d, r14d                  # the nearest entry left
    jz      .Lpk_done
    movss   xmm7, [rip+sf_big]
    mov     r13d, -1
    xor     ecx, ecx
5:  cmp     ecx, r14d
    jae     6f
    mov     eax, [r15+rcx*4]
    shl     eax, 5
    add     rax, [rip+sd_nodes]
    movss   xmm0, [rax+24]
    comiss  xmm0, xmm7
    jae     51f
    movss   xmm7, xmm0
    mov     r13d, ecx
51: inc     ecx
    jmp     5b
6:  comiss  xmm7, [rip+pk_t]            # nothing nearer can come
    jae     .Lpk_done
    mov     eax, [r15+r13*4]            # take it out (the last moves in)
    dec     r14d
    mov     ecx, [r15+r14*4]
    mov     [r15+r13*4], ecx
    imul    eax, eax, ND_SZ
    mov     rbx, [rip+sc_nodes]
    add     rbx, rax
    mov     r12d, [rbx+ND_TOFF]
    mov     r13d, [rbx+ND_TN]
    add     r13d, r12d
2:  cmp     r12d, r13d
    jae     .Lpk_near
    mov     rax, [rip+sc_tri]
    mov     edi, [rax+r12*4]
    call    ray_tri
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    jbe     3f
    comiss  xmm0, [rip+pk_t]
    jae     3f
    movss   [rip+pk_t], xmm0
    mov     ebp, 1
3:  inc     r12d
    jmp     2b
.Lpk_done:
    test    ebp, ebp
    jz      9f
    xor     ecx, ecx
4:  lea     rax, [rip+pk_d]
    movss   xmm0, [rax+rcx*4]
    mulss   xmm0, [rip+pk_t]
    lea     rax, [rip+pk_o]
    addss   xmm0, [rax+rcx*4]
    lea     rax, [rip+pk_p]
    movss   [rax+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      4b
9:  mov     eax, ebp
    add     rsp, 88
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# xform_vec(rdi=m[12], rsi=v, rdx=out) - the 3x3 part only
xform_vec:
    xor     ecx, ecx
1:  mov     eax, ecx
    shl     eax, 4
    movss   xmm0, [rdi+rax]
    mulss   xmm0, [rsi]
    movss   xmm1, [rdi+rax+4]
    mulss   xmm1, [rsi+4]
    addss   xmm0, xmm1
    movss   xmm1, [rdi+rax+8]
    mulss   xmm1, [rsi+8]
    addss   xmm0, xmm1
    movss   [rdx+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      1b
    ret

# slab(rbx=leaf; pk_o, pk_d) -> xmm0 = where the ray enters its box (big:
#   it misses)
slab:
    xorps   xmm4, xmm4                  # t0, t1
    movss   xmm5, [rip+sf_big]
    xor     ecx, ecx
1:  lea     rax, [rip+pk_d]
    movss   xmm1, [rax+rcx*4]
    lea     rax, [rip+pk_o]
    movss   xmm0, [rax+rcx*4]
    movss   xmm2, xmm1
    andps   xmm2, [rip+sf_abs]
    comiss  xmm2, [rip+sf_tiny]
    ja      2f
    comiss  xmm0, [rbx+ND_MIN+rcx*4]    # parallel: within the slab or never
    jb      8f
    comiss  xmm0, [rbx+ND_MAX+rcx*4]
    ja      8f
    jmp     3f
2:  movss   xmm2, [rbx+ND_MIN+rcx*4]
    subss   xmm2, xmm0
    divss   xmm2, xmm1
    movss   xmm3, [rbx+ND_MAX+rcx*4]
    subss   xmm3, xmm0
    divss   xmm3, xmm1
    movss   xmm6, xmm2
    minss   xmm6, xmm3
    maxss   xmm2, xmm3
    maxss   xmm4, xmm6
    minss   xmm5, xmm2
3:  inc     ecx
    cmp     ecx, 3
    jb      1b
    comiss  xmm4, xmm5
    ja      8f
    movss   xmm0, xmm4
    ret
8:  movss   xmm0, [rip+sf_big]
    ret

# ray_tri(edi=triangle; pk_o, pk_d) -> xmm0 = t, or -1 (Moller-Trumbore)
ray_tri:
    sub     rsp, 56
    lea     rax, [rdi+rdi*2]
    mov     rdx, [rip+sv_tris]
    lea     rdx, [rdx+rax*4]
    mov     r8, [rip+sv_pos]
    mov     eax, [rdx]
    lea     rax, [rax+rax*2]
    lea     r9, [r8+rax*4]
    mov     eax, [rdx+4]
    lea     rax, [rax+rax*2]
    lea     r10, [r8+rax*4]
    mov     eax, [rdx+8]
    lea     rax, [rax+rax*2]
    lea     r11, [r8+rax*4]
    xor     ecx, ecx
1:  movss   xmm0, [r10+rcx*4]           # e1, e2, s
    subss   xmm0, [r9+rcx*4]
    movss   [rsp+rcx*4], xmm0
    movss   xmm0, [r11+rcx*4]
    subss   xmm0, [r9+rcx*4]
    movss   [rsp+12+rcx*4], xmm0
    lea     rax, [rip+pk_o]
    movss   xmm0, [rax+rcx*4]
    subss   xmm0, [r9+rcx*4]
    movss   [rsp+24+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      1b
    lea     rdi, [rip+pk_d]             # p = d x e2
    lea     rsi, [rsp+12]
    lea     rdx, [rsp+36]
    call    crs
    lea     rdi, [rsp]
    lea     rsi, [rsp+36]
    call    dt
    movss   xmm7, xmm0                  # det
    movss   xmm1, xmm0
    andps   xmm1, [rip+sf_abs]
    comiss  xmm1, [rip+sf_tiny]
    jbe     8f
    lea     rdi, [rsp+24]
    lea     rsi, [rsp+36]
    call    dt
    divss   xmm0, xmm7                  # u
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    jb      8f
    comiss  xmm0, [rip+sf_one]
    ja      8f
    movss   [rsp+48], xmm0
    lea     rdi, [rsp+24]               # q = s x e1
    lea     rsi, [rsp]
    lea     rdx, [rsp+36]
    call    crs
    lea     rdi, [rip+pk_d]
    lea     rsi, [rsp+36]
    call    dt
    divss   xmm0, xmm7                  # v
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    jb      8f
    addss   xmm0, [rsp+48]
    comiss  xmm0, [rip+sf_one]
    ja      8f
    lea     rdi, [rsp+12]
    lea     rsi, [rsp+36]
    call    dt
    divss   xmm0, xmm7
    add     rsp, 56
    ret
8:  xorps   xmm0, xmm0
    subss   xmm0, [rip+sf_one]
    add     rsp, 56
    ret
crs:
    movss   xmm0, [rdi+4]
    mulss   xmm0, [rsi+8]
    movss   xmm1, [rdi+8]
    mulss   xmm1, [rsi+4]
    subss   xmm0, xmm1
    movss   [rdx], xmm0
    movss   xmm0, [rdi+8]
    mulss   xmm0, [rsi]
    movss   xmm1, [rdi]
    mulss   xmm1, [rsi+8]
    subss   xmm0, xmm1
    movss   [rdx+4], xmm0
    movss   xmm0, [rdi]
    mulss   xmm0, [rsi+4]
    movss   xmm1, [rdi+4]
    mulss   xmm1, [rsi]
    subss   xmm0, xmm1
    movss   [rdx+8], xmm0
    ret
dt:
    movss   xmm0, [rdi]
    mulss   xmm0, [rsi]
    movss   xmm1, [rdi+4]
    mulss   xmm1, [rsi+4]
    addss   xmm0, xmm1
    movss   xmm1, [rdi+8]
    mulss   xmm1, [rsi+8]
    addss   xmm0, xmm1
    ret

# local_radius(rsi=local point) -> xmm0 = sc_radius pixels there, in local
#   units (camera depth / focal, through the object's scale)
local_radius:
    sub     rsp, 8
    call    tocam
    maxss   xmm2, [rip+f_near]
    movss   xmm0, [rip+sc_radius]
    mulss   xmm0, xmm2
    divss   xmm0, [rip+vp_focal]
    movss   [rsp], xmm0
    movss   xmm1, [rip+sc_m]            # the scale: |first column|
    mulss   xmm1, xmm1
    movss   xmm2, [rip+sc_m+16]
    mulss   xmm2, xmm2
    addss   xmm1, xmm2
    movss   xmm2, [rip+sc_m+32]
    mulss   xmm2, xmm2
    addss   xmm1, xmm2
    sqrtss  xmm1, xmm1
    maxss   xmm1, [rip+sf_tiny]
    movss   xmm0, [rsp]
    divss   xmm0, xmm1
    add     rsp, 8
    ret

# =============================================================================
#  Brush dabs
# =============================================================================
# hits(rbx=leaf, xmm0=radius around dab_p) -> eax = 1 if its box touches
#   that sphere
hits:
    xorps   xmm1, xmm1                  # squared distance from the box
    xor     ecx, ecx
    lea     rax, [rip+dab_p]
1:  movss   xmm2, [rax+rcx*4]
    movss   xmm3, [rbx+ND_MIN+rcx*4]
    subss   xmm3, xmm2
    xorps   xmm4, xmm4
    maxss   xmm3, xmm4
    movss   xmm4, xmm2
    subss   xmm4, [rbx+ND_MAX+rcx*4]
    xorps   xmm5, xmm5
    maxss   xmm4, xmm5
    addss   xmm3, xmm4
    mulss   xmm3, xmm3
    addss   xmm1, xmm3
    inc     ecx
    cmp     ecx, 3
    jb      1b
    mulss   xmm0, xmm0
    xor     eax, eax
    comiss  xmm1, xmm0
    setbe   al
    ret

# falloff(ecx=vertex) -> xmm0 = its weight in the dab (0 outside): smooth
#   (1 - t^2)^2 with t = distance / radius, less where masked (the mask
#   brush itself ignores the mask)
falloff:
    lea     rax, [rcx+rcx*2]
    mov     rdx, [rip+sv_pos]
    lea     rdx, [rdx+rax*4]
    movss   xmm0, [rdx]
    subss   xmm0, [rip+dab_p]
    mulss   xmm0, xmm0
    movss   xmm1, [rdx+4]
    subss   xmm1, [rip+dab_p+4]
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    movss   xmm1, [rdx+8]
    subss   xmm1, [rip+dab_p+8]
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    movss   xmm1, [rip+dab_r]
    mulss   xmm1, xmm1
    comiss  xmm0, xmm1
    jae     8f
    divss   xmm0, xmm1                  # t^2
    movss   xmm1, [rip+sf_one]
    subss   xmm1, xmm0
    mulss   xmm1, xmm1
    movss   xmm0, xmm1
    cmp     dword ptr [rip+sc_brush_now], B_MASK
    je      9f
    cmp     dword ptr [rip+sc_masked], 0
    je      9f
    mov     rax, [rip+sc_mask]
    movzx   eax, byte ptr [rax+rcx]
    test    eax, eax
    jz      9f
    cvtsi2ss xmm1, eax
    mulss   xmm1, [rip+sf_mask]
    movss   xmm2, [rip+sf_one]
    subss   xmm2, xmm1
    mulss   xmm0, xmm2
9:  ret
8:  xorps   xmm0, xmm0
    ret

# record(ecx=vertex) - its old position into the stroke's deltas, once
#   (any thread: the room is made before a pass, a slot taken atomically)
record:
    mov     rax, [rip+sc_rec]
    cmp     byte ptr [rax+rcx], 0
    jne     9f
    mov     byte ptr [rax+rcx], 1
    mov     eax, 1
    lock xadd [rip+sc_d_n], eax
    cmp     eax, [rip+sc_d_cap]
    jae     9f
    mov     rdx, [rip+sc_d_idx]
    mov     [rdx+rax*4], ecx
    lea     r8, [rcx+rcx*2]
    mov     r9, [rip+sv_pos]
    lea     r9, [r9+r8*4]
    lea     rdx, [rax+rax*2]
    mov     r10, [rip+sc_d_old]
    lea     r10, [r10+rdx*4]
    mov     r8, [r9]
    mov     [r10], r8
    mov     r8d, [r9+8]
    mov     [r10+8], r8d
9:  ret

# room(edi=more) - the deltas can take that many more
room:
    push    rbx
    mov     ebx, edi
1:  mov     eax, [rip+sc_d_n]
    add     eax, ebx
    cmp     eax, [rip+sc_d_cap]
    jbe     9f
    call    grow_deltas
    mov     eax, [rip+sc_d_cap]
    test    eax, eax
    jz      9f
    jmp     1b
9:  pop     rbx
    ret

# grow_deltas - twice the room (at least 64k)
grow_deltas:
    push    rbx
    push    r12
    push    r13
    mov     ebx, [rip+sc_d_cap]
    lea     r12d, [rbx+rbx]
    cmp     r12d, 65536
    jae     1f
    mov     r12d, 65536
1:  mov     edi, r12d
    shl     rdi, 2
    call    smap
    test    rax, rax
    jz      9f
    mov     r13, rax
    mov     edi, r12d
    imul    rdi, rdi, 12
    call    smap
    test    rax, rax
    jz      8f
    push    rax
    mov     rdi, r13                    # copy, free the old
    mov     rsi, [rip+sc_d_idx]
    mov     ecx, [rip+sc_d_n]
    shl     rcx, 2
    test    rsi, rsi
    jz      2f
    rep     movsb
2:  mov     rdi, [rsp]
    mov     rsi, [rip+sc_d_old]
    mov     ecx, [rip+sc_d_n]
    imul    rcx, rcx, 12
    test    rsi, rsi
    jz      3f
    rep     movsb
3:  call    free_deltas
    pop     rax
    mov     [rip+sc_d_old], rax
    mov     [rip+sc_d_idx], r13
    mov     [rip+sc_d_cap], r12d
    jmp     9f
8:  mov     rdi, r13
    mov     esi, r12d
    shl     rsi, 2
    mov     eax, SYS_MUNMAP
    syscall
9:  pop     r13
    pop     r12
    pop     rbx
    ret
free_deltas:
    mov     rdi, [rip+sc_d_idx]
    test    rdi, rdi
    jz      1f
    mov     esi, [rip+sc_d_cap]
    shl     rsi, 2
    add     rsi, 4095
    and     rsi, -4096
    mov     eax, SYS_MUNMAP
    syscall
1:  mov     rdi, [rip+sc_d_old]
    test    rdi, rdi
    jz      2f
    mov     esi, [rip+sc_d_cap]
    imul    rsi, rsi, 12
    add     rsi, 4095
    and     rsi, -4096
    mov     eax, SYS_MUNMAP
    syscall
2:  mov     qword ptr [rip+sc_d_idx], 0
    mov     qword ptr [rip+sc_d_old], 0
    mov     dword ptr [rip+sc_d_cap], 0
    ret

# reach(edi=list 0..2, xmm0=radius around dab_p) -> eax = the leaves it
#   touches, into that list
reach:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    movss   [rsp], xmm0
    mov     r13d, edi
    mov     eax, edi                    # the list
    imul    eax, [rip+sc_nnodes]
    shl     rax, 2
    mov     r14, [rip+sc_hits]
    add     r14, rax
    xor     r12d, r12d                  # leaf
    xor     edx, edx                    # count
1:  cmp     r12d, [rip+sc_nnodes]
    jae     9f
    imul    eax, r12d, ND_SZ
    mov     rbx, [rip+sc_nodes]
    add     rbx, rax
    push    rdx
    push    rdx
    movss   xmm0, [rsp+16]
    call    hits
    pop     rdx
    pop     rdx
    test    eax, eax
    jz      2f
    mov     [r14+rdx*4], r12d
    inc     edx
2:  inc     r12d
    jmp     1b
9:  lea     rax, [rip+sc_nh]
    mov     [rax+r13*4], edx
    mov     eax, edx
    add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# leaf_of(edi=list, esi=i) -> rbx = the leaf record (keeps others)
.macro LEAF_OF list
    mov     eax, \list
    imul    eax, [rip+sc_nnodes]
    add     eax, esi
    mov     rbx, [rip+sc_hits]
    mov     eax, [rbx+rax*4]
    imul    eax, eax, ND_SZ
    mov     rbx, [rip+sc_nodes]
    add     rbx, rax
.endm

# pfor(rdi=job, edi count from esi) - parallel over esi items, grain 2
pfor:
    mov     edx, esi
    mov     rsi, 0
    mov     ecx, 2
    jmp     parallel_for

# fadd(rdi=address, xmm0=value) - an atomic float add
fadd:
1:  mov     eax, [rdi]
    movd    xmm3, eax
    addss   xmm3, xmm0
    movd    edx, xmm3
    lock cmpxchg [rdi], edx
    jne     1b
    ret

# dab(xmm0=radius (local); dab_p, dab_s, sc_brush_now, dab_move) - one dab:
#   the area's normal and centre, then each vertex in reach, then the
#   leaves' boxes and the normals around - each pass over the leaves in
#   reach in parallel (a vertex belongs to one leaf: no two threads meet)
dab:
    push    rbx
    push    r12
    sub     rsp, 40
    movss   [rip+dab_r], xmm0
    xor     edi, edi
    call    reach
    test    eax, eax
    jz      .Ldb_out
    lea     rdi, [rip+sc_slots]         # the area: per-thread sums
    xor     eax, eax
    mov     ecx, 32*130/4
    rep     stosd
    lea     rdi, [rip+job_area]
    mov     esi, [rip+sc_nh]
    call    pfor
    xorps   xmm0, xmm0                  # reduce: w, centre, normal
    movss   [rsp], xmm0
    movss   [rsp+4], xmm0
    movss   [rsp+8], xmm0
    movss   [rsp+12], xmm0
    movss   [rsp+16], xmm0
    movss   [rsp+20], xmm0
    movss   [rsp+24], xmm0
    lea     rax, [rip+sc_slots]
    xor     ecx, ecx
1:  cmp     ecx, 130
    jae     2f
    xor     edx, edx
11: movss   xmm0, [rax+rdx*4]
    addss   xmm0, [rsp+rdx*4]
    movss   [rsp+rdx*4], xmm0
    inc     edx
    cmp     edx, 7
    jb      11b
    add     rax, 32
    inc     ecx
    jmp     1b
2:  movss   xmm0, [rsp]
    comiss  xmm0, [rip+sf_tiny]
    jbe     .Ldb_out                    # nothing in reach
    xor     eax, eax
3:  movss   xmm1, [rsp+4+rax*4]
    divss   xmm1, [rsp]
    lea     rcx, [rip+dab_c]
    movss   [rcx+rax*4], xmm1
    inc     eax
    cmp     eax, 3
    jb      3b
    lea     rdi, [rsp+16]
    call    unit3
    mov     rax, [rsp+16]
    mov     [rip+dab_n], rax
    mov     eax, [rsp+24]
    mov     [rip+dab_n+8], eax
    cmp     dword ptr [rip+sc_brush_now], B_SMOOTH
    jne     4f
    call    smooth_gather               # neighbour sums into sc_acc
    test    eax, eax
    jz      .Ldb_out
4:  cmp     dword ptr [rip+sc_brush_now], B_MASK
    je      5f
    xor     ebx, ebx                    # room for every own vertex in reach
    xor     ecx, ecx
41: cmp     ecx, [rip+sc_nh]
    jae     42f
    mov     rax, [rip+sc_hits]
    mov     eax, [rax+rcx*4]
    imul    eax, eax, ND_SZ
    mov     rdx, [rip+sc_nodes]
    add     ebx, [rdx+rax+ND_VOWN]
    inc     ecx
    jmp     41b
42: mov     edi, ebx
    call    room
5:  lea     rdi, [rip+job_apply]        # each vertex in reach
    mov     esi, [rip+sc_nh]
    call    pfor
    lea     rdi, [rip+job_box]          # the boxes
    mov     esi, [rip+sc_nh]
    call    pfor
    call    dirty_grow                  # normals: once a frame, before drawing
    mov     dword ptr [rip+dirty], 1
.Ldb_out:
    add     rsp, 40
    pop     r12
    pop     rbx
    ret

# dirty_grow - the sphere whose normals are due takes in this dab's
#   (dab_p, dab_r): the smallest sphere around both
dirty_grow:
    movss   xmm0, [rip+dab_r]
    cmp     dword ptr [rip+nd_on], 0
    jne     1f
    mov     rax, [rip+dab_p]
    mov     [rip+nd_c], rax
    mov     eax, [rip+dab_p+8]
    mov     [rip+nd_c+8], eax
    movss   [rip+nd_r], xmm0
    mov     dword ptr [rip+nd_on], 1
    ret
1:  xorps   xmm1, xmm1                  # d = |p - c|
    xor     ecx, ecx
2:  lea     rax, [rip+dab_p]
    movss   xmm2, [rax+rcx*4]
    lea     rax, [rip+nd_c]
    subss   xmm2, [rax+rcx*4]
    mulss   xmm2, xmm2
    addss   xmm1, xmm2
    inc     ecx
    cmp     ecx, 3
    jb      2b
    sqrtss  xmm1, xmm1
    movss   xmm2, xmm1                  # inside the old one: as it is
    addss   xmm2, xmm0
    comiss  xmm2, [rip+nd_r]
    jbe     9f
    movss   xmm2, xmm1                  # the old inside the new: the new
    addss   xmm2, [rip+nd_r]
    comiss  xmm2, xmm0
    ja      3f
    mov     rax, [rip+dab_p]
    mov     [rip+nd_c], rax
    mov     eax, [rip+dab_p+8]
    mov     [rip+nd_c+8], eax
    movss   [rip+nd_r], xmm0
    ret
3:  movss   xmm3, xmm1                  # R = (d + r1 + r2) / 2, the centre
    addss   xmm3, [rip+nd_r]            #  moves (R - r1) / d towards p
    addss   xmm3, xmm0
    mulss   xmm3, [rip+sf_half]
    movss   xmm4, xmm3
    subss   xmm4, [rip+nd_r]
    divss   xmm4, xmm1
    movss   [rip+nd_r], xmm3
    xor     ecx, ecx
4:  lea     rax, [rip+dab_p]
    movss   xmm2, [rax+rcx*4]
    lea     rax, [rip+nd_c]
    subss   xmm2, [rax+rcx*4]
    mulss   xmm2, xmm4
    addss   xmm2, [rax+rcx*4]
    movss   [rax+rcx*4], xmm2
    inc     ecx
    cmp     ecx, 3
    jb      4b
9:  ret

# normals_due - the normals in the dirty sphere again (before drawing, at a
#   stroke's end)
normals_due:
    cmp     dword ptr [rip+nd_on], 0
    je      9f
    sub     rsp, 24
    mov     dword ptr [rip+nd_on], 0
    mov     rax, [rip+dab_p]            # (dab_p is the sphere's meanwhile)
    mov     [rsp], rax
    mov     eax, [rip+dab_p+8]
    mov     [rsp+8], eax
    mov     rax, [rip+nd_c]
    mov     [rip+dab_p], rax
    mov     eax, [rip+nd_c+8]
    mov     [rip+dab_p+8], eax
    movss   xmm0, [rip+nd_r]
    call    normals_near
    mov     rax, [rsp]
    mov     [rip+dab_p], rax
    mov     eax, [rsp+8]
    mov     [rip+dab_p+8], eax
    add     rsp, 24
9:  ret

# job_area(esi=begin, edx=end, ecx=thread) - weights, centre, normal sums
job_area:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 8
    mov     r12d, esi
    mov     r13d, edx
    lea     eax, [rcx+1]                # this thread's slot
    and     eax, 127
    shl     eax, 5
    lea     rbp, [rip+sc_slots]
    add     rbp, rax
1:  cmp     r12d, r13d
    jae     9f
    mov     esi, r12d
    LEAF_OF 0
    mov     r14d, [rbx+ND_VOFF]
    mov     r15d, [rbx+ND_VOWN]
    add     r15d, r14d
2:  cmp     r14d, r15d
    jae     8f
    mov     rax, [rip+sc_vl]
    mov     ecx, [rax+r14*4]
    call    falloff
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    jbe     7f
    movss   xmm1, [rbp]
    addss   xmm1, xmm0
    movss   [rbp], xmm1
    lea     rax, [rcx+rcx*2]
    mov     rdx, [rip+sv_pos]
    lea     rdx, [rdx+rax*4]
    mov     r8, [rip+sc_vn]
    lea     r8, [r8+rax*4]
    xor     eax, eax
3:  movss   xmm1, [rdx+rax*4]
    mulss   xmm1, xmm0
    addss   xmm1, [rbp+4+rax*4]
    movss   [rbp+4+rax*4], xmm1
    movss   xmm1, [r8+rax*4]
    mulss   xmm1, xmm0
    addss   xmm1, [rbp+16+rax*4]
    movss   [rbp+16+rax*4], xmm1
    inc     eax
    cmp     eax, 3
    jb      3b
7:  inc     r14d
    jmp     2b
8:  inc     r12d
    jmp     1b
9:  add     rsp, 8
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# job_apply(esi=begin, edx=end) - the brush on each own vertex in reach;
#   the old positions of the leaf's first-touched vertices go to slots taken
#   with one atomic add per leaf
job_apply:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 24
    mov     r12d, esi
    mov     r13d, edx
1:  cmp     r12d, r13d
    jae     9f
    mov     esi, r12d
    LEAF_OF 0
    mov     r14d, [rbx+ND_VOFF]
    mov     r15d, [rbx+ND_VOWN]
    add     r15d, r14d
    xor     ebp, ebp                    # first: how many are new
    cmp     dword ptr [rip+sc_brush_now], B_MASK
    je      4f
    mov     [rsp+8], r14d
2:  cmp     r14d, r15d
    jae     3f
    mov     rax, [rip+sc_vl]
    mov     ecx, [rax+r14*4]
    mov     rax, [rip+sc_rec]
    cmp     byte ptr [rax+rcx], 0
    jne     21f
    call    falloff
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    jbe     21f
    inc     ebp
21: inc     r14d
    jmp     2b
3:  mov     r14d, [rsp+8]
    mov     eax, ebp                    # their slots
    lock xadd [rip+sc_d_n], eax
    mov     ebp, eax
4:  cmp     r14d, r15d
    jae     8f
    mov     rax, [rip+sc_vl]
    mov     ecx, [rax+r14*4]
    call    falloff
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    jbe     7f
    movss   [rsp], xmm0
    mov     [rsp+4], ecx
    cmp     dword ptr [rip+sc_brush_now], B_MASK
    je      6f
    mov     rax, [rip+sc_rec]           # first touch: its old position
    cmp     byte ptr [rax+rcx], 0
    jne     6f
    mov     byte ptr [rax+rcx], 1
    cmp     ebp, [rip+sc_d_cap]
    jae     5f
    mov     rdx, [rip+sc_d_idx]
    mov     [rdx+rbp*4], ecx
    lea     r8, [rcx+rcx*2]
    mov     r9, [rip+sv_pos]
    lea     r9, [r9+r8*4]
    lea     rdx, [rbp+rbp*2]
    mov     r10, [rip+sc_d_old]
    lea     r10, [r10+rdx*4]
    mov     r8, [r9]
    mov     [r10], r8
    mov     r8d, [r9+8]
    mov     [r10+8], r8d
5:  inc     ebp
6:  mov     ecx, [rsp+4]
    movss   xmm0, [rsp]
    call    move_vertex
7:  inc     r14d
    jmp     4b
8:  inc     r12d
    jmp     1b
9:  add     rsp, 24
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# job_box(esi=begin, edx=end) - the boxes of the leaves in reach (list 0)
job_box:
    push    rbx
    push    r12
    push    r13
    mov     r12d, esi
    mov     r13d, edx
1:  cmp     r12d, r13d
    jae     9f
    mov     eax, r12d
    mov     rcx, [rip+sc_hits]
    mov     edi, [rcx+rax*4]
    call    node_box
    inc     r12d
    jmp     1b
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# unit3(rdi=float[3]) - unit length (kept when ~0)
unit3:
    movss   xmm0, [rdi]
    mulss   xmm0, xmm0
    movss   xmm1, [rdi+4]
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    movss   xmm1, [rdi+8]
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    sqrtss  xmm0, xmm0
    comiss  xmm0, [rip+sf_tiny]
    jbe     1f
    movss   xmm1, [rip+sf_one]
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

# move_vertex(ecx=vertex, xmm0=weight) - the brush's change
move_vertex:
    sub     rsp, 40
    movss   [rsp], xmm0
    lea     rax, [rcx+rcx*2]
    mov     r8, [rip+sv_pos]
    lea     r8, [r8+rax*4]              # its position
    mov     r9, [rip+sc_vn]
    lea     r9, [r9+rax*4]              # its normal
    movss   xmm7, [rip+dab_s]           # strength x weight
    mulss   xmm7, xmm0
    mov     eax, [rip+sc_brush_now]
    cmp     eax, B_DRAW
    je      .Lmv_draw
    cmp     eax, B_CREASE
    je      .Lmv_crease
    cmp     eax, B_INFLATE
    je      .Lmv_inflate
    cmp     eax, B_CLAY
    je      .Lmv_clay
    cmp     eax, B_FLATTEN
    je      .Lmv_flat
    cmp     eax, B_PINCH
    je      .Lmv_pinch
    cmp     eax, B_SMOOTH
    je      .Lmv_smooth
    cmp     eax, B_SNAKE
    je      .Lmv_snake
    cmp     eax, B_LAYER
    je      .Lmv_layer
    cmp     eax, B_MASK
    je      .Lmv_mask
    jmp     .Lmv_out
.Lmv_draw:                              # along the area normal, r / 10
    movss   xmm1, [rip+dab_r]
    mulss   xmm1, [rip+sf_tenth]
    mulss   xmm1, xmm7
    lea     rsi, [rip+dab_n]
    call    add_dir
    jmp     .Lmv_out
.Lmv_inflate:                           # along its own normal
    movss   xmm1, [rip+dab_r]
    mulss   xmm1, [rip+sf_tenth]
    mulss   xmm1, xmm7
    mov     rsi, r9
    call    add_dir
    jmp     .Lmv_out
.Lmv_crease:                            # in along the normal, and pinched
    movss   xmm1, [rip+dab_r]
    mulss   xmm1, [rip+sf_tenth]
    mulss   xmm1, xmm7
    xorps   xmm2, xmm2
    subss   xmm2, xmm1
    movss   xmm1, xmm2
    lea     rsi, [rip+dab_n]
    call    add_dir
    movss   xmm7, [rsp]
    mulss   xmm7, [rip+sf_half]
    andps   xmm7, [rip+sf_abs]
    jmp     .Lmv_pinch2
.Lmv_pinch:
    andps   xmm7, [rip+sf_abs]          # (towards the centre; Ctrl: away)
    mov     eax, [rip+sc_invert]
    test    eax, eax
    jz      .Lmv_pinch2
    xorps   xmm1, xmm1
    subss   xmm1, xmm7
    movss   xmm7, xmm1
.Lmv_pinch2:                            # towards the dab point, in the plane
    mulss   xmm7, [rip+sf_half]
    xor     ecx, ecx
1:  lea     rax, [rip+dab_p]
    movss   xmm0, [rax+rcx*4]
    subss   xmm0, [r8+rcx*4]
    movss   [rsp+8+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      1b
    lea     rdi, [rsp+8]                # minus its normal part
    lea     rsi, [rip+dab_n]
    call    dt
    xor     ecx, ecx
2:  lea     rax, [rip+dab_n]
    movss   xmm1, [rax+rcx*4]
    mulss   xmm1, xmm0
    movss   xmm2, [rsp+8+rcx*4]
    subss   xmm2, xmm1
    mulss   xmm2, xmm7
    addss   xmm2, [r8+rcx*4]
    movss   [r8+rcx*4], xmm2
    inc     ecx
    cmp     ecx, 3
    jb      2b
    jmp     .Lmv_out
.Lmv_clay:                              # up to a plane above the centre
    movss   xmm6, [rip+dab_r]
    mulss   xmm6, [rip+sf_tenth]
    mulss   xmm6, [rip+dab_s]           # its height (signed)
    jmp     .Lmv_plane
.Lmv_flat:
    xorps   xmm6, xmm6                  # the plane through the centre
    andps   xmm7, [rip+sf_abs]
.Lmv_plane:
    xor     ecx, ecx                    # d = (v - c) . n - h
1:  movss   xmm0, [r8+rcx*4]
    lea     rax, [rip+dab_c]
    subss   xmm0, [rax+rcx*4]
    movss   [rsp+8+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      1b
    lea     rdi, [rsp+8]
    lea     rsi, [rip+dab_n]
    call    dt
    subss   xmm0, xmm6
    cmp     dword ptr [rip+sc_brush_now], B_CLAY
    jne     2f
    xorps   xmm1, xmm1                  # clay: only what is below the plane
    comiss  xmm0, xmm1                  #  (above, for a negative height)
    movss   xmm2, [rip+dab_s]
    jae     3f
    comiss  xmm2, xmm1
    jb      .Lmv_out
    jmp     2f
3:  comiss  xmm2, xmm1
    jae     .Lmv_out
2:  movss   xmm1, [rsp]                 # v -= d n w
    andps   xmm1, [rip+sf_abs]
    mulss   xmm0, xmm1
    movss   xmm1, [rip+dab_s]
    andps   xmm1, [rip+sf_abs]
    minss   xmm1, [rip+sf_one]
    mulss   xmm0, xmm1
    xorps   xmm1, xmm1
    subss   xmm1, xmm0
    lea     rsi, [rip+dab_n]
    call    add_dir
    jmp     .Lmv_out
.Lmv_smooth:                            # towards its neighbours' average
    andps   xmm7, [rip+sf_abs]
    minss   xmm7, [rip+sf_one]
    lea     rax, [rcx+rcx]              # sc_acc: float4 (sum xyz, count)
    shl     rax, 3
    add     rax, [rip+sc_acc]
    movss   xmm3, [rax+12]
    comiss  xmm3, [rip+sf_tiny]
    jbe     .Lmv_out
    xor     edx, edx
1:  movss   xmm0, [rax+rdx*4]
    divss   xmm0, xmm3
    subss   xmm0, [r8+rdx*4]
    mulss   xmm0, xmm7
    addss   xmm0, [r8+rdx*4]
    movss   [r8+rdx*4], xmm0
    inc     edx
    cmp     edx, 3
    jb      1b
    jmp     .Lmv_out
.Lmv_snake:                             # with the pointer's move
    movss   xmm7, [rsp]
    xor     ecx, ecx
1:  lea     rax, [rip+dab_move]
    movss   xmm0, [rax+rcx*4]
    mulss   xmm0, xmm7
    addss   xmm0, [r8+rcx*4]
    movss   [r8+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      1b
    jmp     .Lmv_out
.Lmv_layer:                             # draw, but no further than r / 10
    movss   xmm1, [rip+dab_r]           #  from where the stroke found it
    mulss   xmm1, [rip+sf_tenth]
    mulss   xmm1, xmm7
    lea     rsi, [rip+dab_n]
    call    add_dir
    jmp     .Lmv_out
.Lmv_mask:
    mov     dword ptr [rip+sc_masked], 1
    mov     dword ptr [rip+sc_full], 1
    mov     rax, [rip+sc_mask]
    movzx   edx, byte ptr [rax+rcx]
    cvtsi2ss xmm0, edx
    mulss   xmm7, [rip+sf_255]
    addss   xmm0, xmm7
    xorps   xmm1, xmm1
    maxss   xmm0, xmm1
    minss   xmm0, [rip+sf_255]
    cvttss2si edx, xmm0
    mov     [rax+rcx], dl
.Lmv_out:
    add     rsp, 40
    ret

# add_dir(r8=position, rsi=direction, xmm1=amount) - position += dir amount
add_dir:
    xor     eax, eax
1:  movss   xmm0, [rsi+rax*4]
    mulss   xmm0, xmm1
    addss   xmm0, [r8+rax*4]
    movss   [r8+rax*4], xmm0
    inc     eax
    cmp     eax, 3
    jb      1b
    ret

# smooth_gather -> eax = 1: sc_acc (sum of neighbours, count) for the
#   vertices in reach, from the triangles of the leaves around them
smooth_gather:
    sub     rsp, 8
    cmp     qword ptr [rip+sc_acc], 0
    jne     1f
    mov     edx, [rip+sc_capv]
    shl     rdx, 4
    lea     rdi, [rip+sc_acc]
    lea     rsi, [rip+sc_acc_b]
    call    salloc
    test    rax, rax
    jz      8f
1:  movss   xmm0, [rip+dab_r]           # leaves within r + L: their own
    addss   xmm0, [rip+sc_maxedge]      #  vertices cleared, their triangles
    mov     edi, 1                      #  added up
    call    reach
    lea     rdi, [rip+job_acc_clear]
    mov     esi, [rip+sc_nh+4]
    call    pfor
    lea     rdi, [rip+job_acc_add]
    mov     esi, [rip+sc_nh+4]
    call    pfor
    mov     eax, 1
    add     rsp, 8
    ret
8:  xor     eax, eax
    add     rsp, 8
    ret

job_acc_clear:
    push    rbx
    push    r12
    push    r13
    mov     r12d, esi
    mov     r13d, edx
1:  cmp     r12d, r13d
    jae     9f
    mov     esi, r12d
    LEAF_OF 1
    mov     ecx, [rbx+ND_VOFF]
    mov     edx, [rbx+ND_VOWN]
    add     edx, ecx
2:  cmp     ecx, edx
    jae     3f
    mov     rax, [rip+sc_vl]
    mov     eax, [rax+rcx*4]
    shl     rax, 4
    add     rax, [rip+sc_acc]
    xorps   xmm0, xmm0
    movups  [rax], xmm0
    inc     ecx
    jmp     2b
3:  inc     r12d
    jmp     1b
9:  pop     r13
    pop     r12
    pop     rbx
    ret

job_acc_add:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 8
    mov     r12d, esi
    mov     r13d, edx
1:  cmp     r12d, r13d
    jae     9f
    mov     esi, r12d
    LEAF_OF 1
    mov     r14d, [rbx+ND_TOFF]
    mov     r15d, [rbx+ND_TN]
    add     r15d, r14d
2:  cmp     r14d, r15d
    jae     8f
    mov     rax, [rip+sc_tri]
    mov     eax, [rax+r14*4]
    lea     rax, [rax+rax*2]
    mov     rdx, [rip+sv_tris]
    lea     rbp, [rdx+rax*4]
    xor     r8d, r8d                    # corner: += the other two
3:  lea     r9d, [r8+1]
    cmp     r9d, 3
    jb      31f
    xor     r9d, r9d
31: lea     r10d, [r9+1]
    cmp     r10d, 3
    jb      32f
    xor     r10d, r10d
32: mov     r9d, [rbp+r9*4]
    mov     r10d, [rbp+r10*4]
    lea     r9, [r9+r9*2]
    lea     r10, [r10+r10*2]
    mov     rdx, [rip+sv_pos]
    mov     eax, [rbp+r8*4]
    shl     rax, 4
    add     rax, [rip+sc_acc]
    mov     rdi, rax
    xor     ecx, ecx
33: movss   xmm0, [rdx+r9*4]
    addss   xmm0, [rdx+r10*4]
    push    rdx
    push    rcx
    call    fadd
    pop     rcx
    pop     rdx
    add     rdx, 4
    add     rdi, 4
    inc     ecx
    cmp     ecx, 3
    jb      33b
    movss   xmm0, [rip+sf_two]
    call    fadd
    inc     r8d
    cmp     r8d, 3
    jb      3b
    inc     r14d
    jmp     2b
8:  inc     r12d
    jmp     1b
9:  add     rsp, 8
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# normals_near(xmm0=dab radius) - vertex normals again within radius + the
#   longest edge of the dab point (list 1, cleared and stamped), from every
#   triangle within radius + 2 edges (list 2; atomic adds), then unit
normals_near:
    sub     rsp, 24
    addss   xmm0, [rip+sc_maxedge]
    movss   [rip+nn_r1], xmm0
    movss   [rsp], xmm0
    addss   xmm0, [rip+sc_maxedge]
    movss   [rsp+4], xmm0
    inc     dword ptr [rip+sc_serial]
    movss   xmm0, [rsp]
    mov     edi, 1
    call    reach
    movss   xmm0, [rsp+4]
    mov     edi, 2
    call    reach
    lea     rdi, [rip+job_n_clear]
    mov     esi, [rip+sc_nh+4]
    call    pfor
    lea     rdi, [rip+job_n_add]
    mov     esi, [rip+sc_nh+8]
    call    pfor
    lea     rdi, [rip+job_n_unit]
    mov     esi, [rip+sc_nh+4]
    call    pfor
    mov     ecx, [rip+sc_nh+4]          # their splats are drawn again
    mov     esi, [rip+sc_nnodes]
    mov     rdx, [rip+sc_hits]
    lea     rdx, [rdx+rsi*4]
    mov     rsi, [rip+sc_lchg]
1:  test    ecx, ecx
    jz      2f
    dec     ecx
    mov     eax, [rdx+rcx*4]
    mov     byte ptr [rsi+rax], 1
    jmp     1b
2:  add     rsp, 24
    ret

# near_v(ecx=vertex) -> CF clear... eax = 1 when within nn_r1 of dab_p
near_v:
    lea     rax, [rcx+rcx*2]
    mov     rdx, [rip+sv_pos]
    lea     rdx, [rdx+rax*4]
    movss   xmm0, [rdx]
    subss   xmm0, [rip+dab_p]
    mulss   xmm0, xmm0
    movss   xmm1, [rdx+4]
    subss   xmm1, [rip+dab_p+4]
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    movss   xmm1, [rdx+8]
    subss   xmm1, [rip+dab_p+8]
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    movss   xmm1, [rip+nn_r1]
    mulss   xmm1, xmm1
    xor     eax, eax
    comiss  xmm0, xmm1
    setb    al
    ret

job_n_clear:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r12d, esi
    mov     r13d, edx
    mov     r15d, [rip+sc_serial]
1:  cmp     r12d, r13d
    jae     9f
    mov     esi, r12d
    LEAF_OF 1
    mov     r14d, [rbx+ND_VOFF]
    mov     r8d, [rbx+ND_VOWN]
    add     r8d, r14d
    push    r8
2:  cmp     r14d, [rsp]
    jae     3f
    mov     rax, [rip+sc_vl]
    mov     ecx, [rax+r14*4]
    call    near_v
    test    eax, eax
    jz      21f
    mov     rax, [rip+sc_stamp]
    mov     [rax+rcx*4], r15d
    lea     rax, [rcx+rcx*2]
    mov     rdx, [rip+sc_vn]
    lea     rdx, [rdx+rax*4]
    mov     dword ptr [rdx], 0
    mov     dword ptr [rdx+4], 0
    mov     dword ptr [rdx+8], 0
21: inc     r14d
    jmp     2b
3:  pop     r8
    inc     r12d
    jmp     1b
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

job_n_add:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 24
    mov     r12d, esi
    mov     r13d, edx
    mov     r15d, [rip+sc_serial]
1:  cmp     r12d, r13d
    jae     9f
    mov     esi, r12d
    LEAF_OF 2
    mov     r14d, [rbx+ND_TOFF]
    mov     eax, [rbx+ND_TN]
    add     eax, r14d
    mov     [rsp+16], eax
2:  cmp     r14d, [rsp+16]
    jae     8f
    mov     rax, [rip+sc_tri]
    mov     eax, [rax+r14*4]
    mov     [rsp+12], eax
    call    face_n
    movss   [rsp], xmm0
    movss   [rsp+4], xmm1
    movss   [rsp+8], xmm2
    mov     eax, [rsp+12]
    lea     rax, [rax+rax*2]
    mov     rdx, [rip+sv_tris]
    lea     rbp, [rdx+rax*4]
    xor     r8d, r8d
3:  mov     ecx, [rbp+r8*4]
    mov     rax, [rip+sc_stamp]
    cmp     [rax+rcx*4], r15d
    jne     4f
    lea     rax, [rcx+rcx*2]
    mov     rdi, [rip+sc_vn]
    lea     rdi, [rdi+rax*4]
    movss   xmm0, [rsp]
    call    fadd
    add     rdi, 4
    movss   xmm0, [rsp+4]
    call    fadd
    add     rdi, 4
    movss   xmm0, [rsp+8]
    call    fadd
4:  inc     r8d
    cmp     r8d, 3
    jb      3b
    inc     r14d
    jmp     2b
8:  inc     r12d
    jmp     1b
9:  add     rsp, 24
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

job_n_unit:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r12d, esi
    mov     r13d, edx
    mov     r15d, [rip+sc_serial]
1:  cmp     r12d, r13d
    jae     9f
    mov     esi, r12d
    LEAF_OF 1
    mov     r14d, [rbx+ND_VOFF]
    mov     r8d, [rbx+ND_VOWN]
    add     r8d, r14d
    push    r8
2:  cmp     r14d, [rsp]
    jae     3f
    mov     rax, [rip+sc_vl]
    mov     ecx, [rax+r14*4]
    mov     rax, [rip+sc_stamp]
    cmp     [rax+rcx*4], r15d
    jne     21f
    call    vn_unit
21: inc     r14d
    jmp     2b
3:  pop     r8
    inc     r12d
    jmp     1b
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Strokes
# =============================================================================
# do_dab(xmm0=radius) - a dab at dab_p, and its mirror with X symmetry
do_dab:
    sub     rsp, 24
    movss   [rsp], xmm0
    call    pen_factor                  # pressure: strength and / or radius
    movss   xmm1, [rip+sc_base_s]
    test    dword ptr [rip+sc_pmap], 1
    jz      1f
    mulss   xmm1, xmm0
1:  movss   [rip+dab_s], xmm1
    test    dword ptr [rip+sc_pmap], 2
    jz      2f
    maxss   xmm0, [rip+sf_tenth]
    mulss   xmm0, [rsp]
    movss   [rsp], xmm0
2:  movss   xmm0, [rsp]
    call    dab
    movss   xmm0, [rsp]                 # dyntopo: the detail there
    xor     edi, edi
    call    dyn_after_dab
    test    dword ptr [rip+sc_sym], 1
    jz      9f
    mov     rax, [rip+dab_p]            # mirrored: x -> -x (and the move)
    mov     [rsp+8], rax
    mov     eax, [rip+dab_p+8]
    mov     [rsp+16], eax
    movss   xmm0, [rip+dab_p]
    xorps   xmm1, xmm1
    subss   xmm1, xmm0
    movss   [rip+dab_p], xmm1
    movss   xmm0, [rip+dab_move]
    xorps   xmm1, xmm1
    subss   xmm1, xmm0
    movss   [rip+dab_move], xmm1
    movss   xmm0, [rsp]
    call    dab
    movss   xmm0, [rsp]
    mov     edi, 1
    call    dyn_after_dab
    mov     rax, [rsp+8]
    mov     [rip+dab_p], rax
    mov     eax, [rsp+16]
    mov     [rip+dab_p+8], eax
    movss   xmm0, [rip+dab_move]
    xorps   xmm1, xmm1
    subss   xmm1, xmm0
    movss   [rip+dab_move], xmm1
9:  add     rsp, 24
    ret

# pen_factor -> xmm0 = the pen's pressure through the curve (1 for the mouse
#   and for scripts)
pen_factor:
    movss   xmm0, [rip+sf_one]
    cmp     dword ptr [rip+sc_penon], 0
    je      9f
    movss   xmm0, [rip+in_pressure]
    xorps   xmm1, xmm1
    maxss   xmm0, xmm1
    minss   xmm0, [rip+sf_one]
    mov     eax, [rip+sc_pcurve]
    cmp     eax, 1
    je      9f
    jb      1f
    mulss   xmm0, xmm0                  # hard
    ret
1:  sqrtss  xmm0, xmm0                  # soft
9:  ret

# stroke_begin(edi=modifiers) - the brush (Shift: smooth), its sign (Ctrl:
#   inverted), an undo step, empty deltas
stroke_begin:
    push    rbx
    mov     ebx, edi
    mov     eax, [rip+sc_brush]
    test    ebx, MOD_SHIFT
    jz      1f
    mov     eax, B_SMOOTH
1:  mov     [rip+sc_brush_now], eax
    xor     eax, eax
    test    ebx, MOD_CTRL
    setnz   al
    or      eax, [rip+in_eraser]        # (a pen's eraser end inverts too)
    mov     [rip+sc_invert], eax
    mov     dword ptr [rip+sc_penon], 0
    movss   xmm0, [rip+sc_strength]
    test    eax, eax
    jz      2f
    xorps   xmm1, xmm1
    subss   xmm1, xmm0
    movss   xmm0, xmm1
2:  movss   [rip+dab_s], xmm0
    movss   [rip+sc_base_s], xmm0
    xorps   xmm0, xmm0
    movss   [rip+dab_move], xmm0
    movss   [rip+dab_move+4], xmm0
    movss   [rip+dab_move+8], xmm0
    mov     dword ptr [rip+sc_d_n], 0
    mov     dword ptr [rip+sc_g_n], 0
    mov     dword ptr [rip+sc_stroking], 1
    call    dyn_reset
    lea     rdi, [rip+s_sculpt]
    call    undo_push
    pop     rbx
    ret

# stroke_end - the deltas to the undo step (old and new positions), the
#   mesh's box and caches
stroke_end:
    push    rbx
    push    r12
    push    r13
    cmp     dword ptr [rip+sc_stroking], 0
    je      9f
    call    normals_due
    mov     dword ptr [rip+sc_stroking], 0
    mov     ebx, [rip+sc_d_n]
    test    ebx, ebx
    jz      8f
    cmp     dword ptr [rip+sc_dyn], 0   # dyntopo: the mesh is replaced (the
    jne     8f                          #  undo step keeps the old one)
    mov     rdi, [rip+sc_mesh]          # multires: the moves go to the
    call    mr_owns                     #  displacements (a new block)
    test    eax, eax
    jz      71f
    call    mr_stroke_end
    jmp     8f
71:
    mov     edi, ebx                    # block: header 32, idx, old, new
    imul    rdi, rdi, 28
    add     rdi, 32
    mov     r12, rdi
    call    smap
    test    rax, rax
    jz      8f
    mov     r13, rax
    mov     rax, [rip+sc_mesh]
    mov     [r13], rax                  # +0 mesh
    mov     [r13+8], ebx                # +8 count
    mov     dword ptr [r13+12], 0       # +12 direction (0: undo -> old)
    mov     [r13+16], r12               # +16 bytes
    lea     rdi, [r13+32]               # indices
    mov     rsi, [rip+sc_d_idx]
    mov     ecx, ebx
    shl     ecx, 2
    rep     movsb
    mov     rsi, [rip+sc_d_old]         # old positions
    imul    ecx, ebx, 12
    rep     movsb
    xor     ecx, ecx                    # new: now
1:  cmp     ecx, ebx
    jae     2f
    mov     rax, [rip+sc_d_idx]
    mov     eax, [rax+rcx*4]
    lea     rax, [rax+rax*2]
    mov     rdx, [rip+sv_pos]
    lea     rdx, [rdx+rax*4]
    mov     rax, [rdx]
    mov     [rdi], rax
    mov     eax, [rdx+8]
    mov     [rdi+8], eax
    add     rdi, 12
    inc     ecx
    jmp     1b
2:  mov     rdi, r13
    call    undo_attach_delta
8:  xor     ecx, ecx                    # recorded flags off
3:  cmp     ecx, [rip+sc_d_n]
    jae     4f
    mov     rax, [rip+sc_d_idx]
    mov     eax, [rax+rcx*4]
    mov     rdx, [rip+sc_rec]
    mov     byte ptr [rdx+rax], 0
    inc     ecx
    jmp     3b
4:  mov     dword ptr [rip+sc_d_n], 0
    cmp     dword ptr [rip+sc_dyn], 0
    je      5f
    call    dyn_commit
    jmp     9f
5:  call    mesh_box_leaves
    mov     rdi, [rip+sc_mesh]
    call    mesh_forget
    mov     dword ptr [rip+dirty], 1
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# mesh_box_leaves - the mesh's box: the union of the leaves' (no pass over
#   every vertex)
mesh_box_leaves:
    movss   xmm0, [rip+sf_big]
    movss   xmm1, xmm0
    movss   xmm2, xmm0
    movss   xmm3, [rip+sf_nbig]
    movss   xmm4, xmm3
    movss   xmm5, xmm3
    mov     rdx, [rip+sc_nodes]
    xor     ecx, ecx
1:  cmp     ecx, [rip+sc_nnodes]
    jae     2f
    minss   xmm0, [rdx+ND_MIN]
    minss   xmm1, [rdx+ND_MIN+4]
    minss   xmm2, [rdx+ND_MIN+8]
    maxss   xmm3, [rdx+ND_MAX]
    maxss   xmm4, [rdx+ND_MAX+4]
    maxss   xmm5, [rdx+ND_MAX+8]
    add     rdx, ND_SZ
    inc     ecx
    jmp     1b
2:  mov     rax, [rip+sc_mesh]
    movss   [rax+ME_BMIN], xmm0
    movss   [rax+ME_BMIN+4], xmm1
    movss   [rax+ME_BMIN+8], xmm2
    movss   [rax+ME_BMAX], xmm3
    movss   [rax+ME_BMAX+4], xmm4
    movss   [rax+ME_BMAX+8], xmm5
    ret

# sculpt_press(edi, esi = logical pointer) -> eax = 1 when the stroke started
#   (on the mesh), 0: the click is the viewport's (orbit, select)
sculpt_press:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     ebx, edi
    mov     r12d, esi
    call    sculpt_valid
    test    rax, rax
    jz      8f
    call    cam_mat
    mov     edi, ebx
    mov     esi, r12d
    call    pick
    test    eax, eax
    jz      8f
    mov     edi, [rip+key_mods]
    call    stroke_begin
    mov     dword ptr [rip+sc_penon], 1
    cvtsi2ss xmm0, ebx
    movss   [rip+lz_x], xmm0
    cvtsi2ss xmm0, r12d
    movss   [rip+lz_y], xmm0
    mov     rax, [rip+pk_p]
    mov     [rip+dab_p], rax
    mov     eax, [rip+pk_p+8]
    mov     [rip+dab_p+8], eax
    lea     rsi, [rip+dab_p]
    call    local_radius
    movss   [rip+sc_lastr], xmm0
    mov     [rip+sc_lastsx], ebx
    mov     [rip+sc_lastsy], r12d
    lea     rsi, [rip+dab_p]            # the grab plane: camera depth there
    call    tocam
    movss   [rip+sc_gplane], xmm2
    mov     rax, [rip+dab_p]
    mov     [rip+sc_last], rax
    mov     eax, [rip+dab_p+8]
    mov     [rip+sc_last+8], eax
    cmp     dword ptr [rip+sc_brush_now], B_GRAB
    jne     1f
    call    grab_capture
    jmp     2f
1:  cmp     dword ptr [rip+sc_brush_now], B_SNAKE
    je      2f
    movss   xmm0, [rip+sc_lastr]
    call    do_dab
2:  mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# plane_point(edi, esi = logical pointer) -> pk_p = the point under it at
#   the grab plane's depth (local)
plane_point:
    push    rbx
    sub     rsp, 32
    mov     ebx, esi
    call    to_px
    cvtsi2ss xmm0, eax
    mov     edi, ebx
    call    to_px
    cvtsi2ss xmm1, eax
    subss   xmm0, [rip+vp_cx]           # camera point: (u z, v z, z)
    divss   xmm0, [rip+vp_focal]
    movss   xmm2, [rip+vp_cy]
    subss   xmm2, xmm1
    divss   xmm2, [rip+vp_focal]
    movss   xmm3, [rip+sc_gplane]
    mulss   xmm0, xmm3
    mulss   xmm2, xmm3
    xor     ecx, ecx                    # world = eye + right x + up y + fwd z
1:  lea     rax, [rip+right]
    movss   xmm4, [rax+rcx*4]
    mulss   xmm4, xmm0
    lea     rax, [rip+up]
    movss   xmm5, [rax+rcx*4]
    mulss   xmm5, xmm2
    addss   xmm4, xmm5
    lea     rax, [rip+fwd]
    movss   xmm5, [rax+rcx*4]
    mulss   xmm5, xmm3
    addss   xmm4, xmm5
    lea     rax, [rip+eye]
    addss   xmm4, [rax+rcx*4]
    movss   [rsp+rcx*4], xmm4
    inc     ecx
    cmp     ecx, 3
    jb      1b
    lea     rdi, [rip+sc_mi]
    lea     rsi, [rsp]
    lea     rdx, [rip+pk_p]
    call    xform_point
    add     rsp, 32
    pop     rbx
    ret

# sculpt_drag(edi, esi = logical pointer) - dabs along the way (every 10%
#   of the radius)
sculpt_drag:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 40

    cmp     dword ptr [rip+sc_stroking], 0
    je      9f
    mov     ebx, edi
    mov     r12d, esi
    call    sculpt_valid
    test    rax, rax
    jz      9f
    call    cam_mat
    mov     eax, [rip+sc_brush_now]
    cmp     eax, B_GRAB
    je      .Lsg_grab
    mov     eax, [rip+sc_lazy]          # stabilizer: the stroke follows on a
    test    eax, eax                    #  string of that length
    jz      5f
    cvtsi2ss xmm2, eax
    cvtsi2ss xmm0, ebx
    subss   xmm0, [rip+lz_x]
    cvtsi2ss xmm1, r12d
    subss   xmm1, [rip+lz_y]
    movss   xmm3, xmm0
    mulss   xmm3, xmm0
    movss   xmm4, xmm1
    mulss   xmm4, xmm1
    addss   xmm3, xmm4
    sqrtss  xmm3, xmm3
    comiss  xmm3, xmm2
    jbe     9f                          # (within the string: nothing yet)
    movss   xmm4, xmm3
    subss   xmm4, xmm2
    divss   xmm4, xmm3
    mulss   xmm0, xmm4
    mulss   xmm1, xmm4
    addss   xmm0, [rip+lz_x]
    movss   [rip+lz_x], xmm0
    addss   xmm1, [rip+lz_y]
    movss   [rip+lz_y], xmm1
    cvtss2si ebx, xmm0
    cvtss2si r12d, xmm1
5:  cmp     dword ptr [rip+sc_brush_now], B_SNAKE
    je      .Lsg_snake
    # spacing: a dab every 10% of the radius (in pixels) along the path
    mov     eax, ebx
    sub     eax, [rip+sc_lastsx]
    cvtsi2ss xmm0, eax
    mov     eax, r12d
    sub     eax, [rip+sc_lastsy]
    cvtsi2ss xmm1, eax
    mulss   xmm0, xmm0
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    sqrtss  xmm0, xmm0
    movss   xmm1, [rip+sc_radius]
    mulss   xmm1, [rip+sf_spacing]
    maxss   xmm1, [rip+sf_one]
    divss   xmm0, xmm1
    cvttss2si r13d, xmm0                # dabs to place
    test    r13d, r13d
    jz      9f
    cmp     r13d, 64
    jle     1f
    mov     r13d, 64
1:  mov     r14d, 1
2:  cmp     r14d, r13d
    jg      3f
    cvtsi2ss xmm0, r14d                 # the k-th point on the way
    cvtsi2ss xmm1, r13d
    divss   xmm0, xmm1
    mov     eax, ebx
    sub     eax, [rip+sc_lastsx]
    cvtsi2ss xmm1, eax
    mulss   xmm1, xmm0
    cvttss2si edi, xmm1
    add     edi, [rip+sc_lastsx]
    mov     eax, r12d
    sub     eax, [rip+sc_lastsy]
    cvtsi2ss xmm1, eax
    mulss   xmm1, xmm0
    cvttss2si esi, xmm1
    add     esi, [rip+sc_lastsy]
    call    pick
    test    eax, eax
    jz      21f
    mov     rax, [rip+pk_p]
    mov     [rip+dab_p], rax
    mov     eax, [rip+pk_p+8]
    mov     [rip+dab_p+8], eax
    lea     rsi, [rip+dab_p]
    call    local_radius
    call    do_dab
21: inc     r14d
    jmp     2b
3:  mov     [rip+sc_lastsx], ebx
    mov     [rip+sc_lastsy], r12d
    jmp     9f
.Lsg_grab:                              # the captured vertices follow
    mov     edi, ebx
    mov     esi, r12d
    call    plane_point
    call    grab_move
    jmp     9f
.Lsg_snake:                             # pull what is under the brush along
    mov     edi, ebx
    mov     esi, r12d
    call    plane_point
    xor     ecx, ecx
4:  lea     rax, [rip+pk_p]
    movss   xmm0, [rax+rcx*4]
    lea     rax, [rip+sc_last]
    subss   xmm0, [rax+rcx*4]
    lea     rax, [rip+dab_move]
    movss   [rax+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      4b
    mov     rax, [rip+sc_last]
    mov     [rip+dab_p], rax
    mov     eax, [rip+sc_last+8]
    mov     [rip+dab_p+8], eax
    movss   xmm0, [rip+sc_lastr]
    call    do_dab
    mov     rax, [rip+pk_p]
    mov     [rip+sc_last], rax
    mov     eax, [rip+pk_p+8]
    mov     [rip+sc_last+8], eax
9:  add     rsp, 40
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

sculpt_release:
    sub     rsp, 8
    call    stroke_end
    add     rsp, 8
    ret

# grab_capture - the vertices in reach at the start, with their weights
#   (and their mirrors' with X symmetry)
grab_capture:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    movss   xmm0, [rip+sc_lastr]
    movss   [rip+dab_r], xmm0
    mov     rax, [rip+dab_p]            # (where it started)
    mov     [rip+sc_gstart], rax
    mov     eax, [rip+dab_p+8]
    mov     [rip+sc_gstart+8], eax
    mov     dword ptr [rsp], 0          # pass: 0 as is, 1 mirrored
.Lgc_pass:
    movss   xmm0, [rip+dab_r]           # room for every vertex in reach
    xor     edi, edi
    call    reach
    xor     ebx, ebx
    xor     ecx, ecx
105:cmp     ecx, [rip+sc_nh]
    jae     106f
    mov     rax, [rip+sc_hits]
    mov     eax, [rax+rcx*4]
    imul    eax, eax, ND_SZ
    mov     rdx, [rip+sc_nodes]
    add     ebx, [rdx+rax+ND_VOWN]
    inc     ecx
    jmp     105b
106:mov     edi, ebx
    call    room
    inc     dword ptr [rip+sc_serial]
    mov     r15d, [rip+sc_serial]
    xor     r12d, r12d
1:  cmp     r12d, [rip+sc_nnodes]
    jae     .Lgc_pnext
    imul    eax, r12d, ND_SZ
    mov     rbx, [rip+sc_nodes]
    add     rbx, rax
    movss   xmm0, [rip+dab_r]
    call    hits
    test    eax, eax
    jz      19f
    mov     r13d, [rbx+ND_VOFF]
    mov     r14d, [rbx+ND_VN]
    add     r14d, r13d
11: cmp     r13d, r14d
    jae     19f
    mov     rax, [rip+sc_vl]
    mov     ecx, [rax+r13*4]
    mov     rax, [rip+sc_stamp]
    cmp     [rax+rcx*4], r15d
    je      12f
    mov     [rax+rcx*4], r15d
    call    falloff
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    jbe     12f
    movss   [rsp+4], xmm0
    mov     [rsp+8], ecx
    call    record
    mov     eax, [rip+sc_g_n]
    cmp     eax, [rip+sc_g_cap]
    jb      13f
    call    grow_grab
    mov     eax, [rip+sc_g_n]
    cmp     eax, [rip+sc_g_cap]
    jae     12f
13: mov     ecx, [rsp+8]
    mov     rdx, [rip+sc_g_idx]
    mov     [rdx+rax*4], ecx
    movss   xmm0, [rsp+4]
    cmp     dword ptr [rsp], 0          # (mirrored: a negative weight marks
    je      14f                         #  the x flip)
    xorps   xmm1, xmm1
    subss   xmm1, xmm0
    movss   xmm0, xmm1
14: mov     rdx, [rip+sc_g_w]
    movss   [rdx+rax*4], xmm0
    inc     dword ptr [rip+sc_g_n]
12: inc     r13d
    jmp     11b
19: inc     r12d
    jmp     1b
.Lgc_pnext:
    test    dword ptr [rip+sc_sym], 1
    jz      9f
    cmp     dword ptr [rsp], 0
    jne     8f
    mov     dword ptr [rsp], 1
    movss   xmm0, [rip+dab_p]
    xorps   xmm1, xmm1
    subss   xmm1, xmm0
    movss   [rip+dab_p], xmm1
    jmp     .Lgc_pass
8:  movss   xmm0, [rip+dab_p]
    xorps   xmm1, xmm1
    subss   xmm1, xmm0
    movss   [rip+dab_p], xmm1
9:  add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

grow_grab:
    push    rbx
    push    r12
    push    r13
    mov     ebx, [rip+sc_g_cap]
    lea     r12d, [rbx+rbx]
    cmp     r12d, 65536
    jae     1f
    mov     r12d, 65536
1:  mov     edi, r12d
    shl     rdi, 3
    call    smap
    test    rax, rax
    jz      9f
    mov     r13, rax
    mov     rdi, rax
    mov     rsi, [rip+sc_g_idx]
    mov     ecx, [rip+sc_g_n]
    shl     ecx, 2
    test    rsi, rsi
    jz      2f
    rep     movsb
2:  mov     edi, r12d
    lea     rdi, [r13+rdi*4]
    mov     rsi, [rip+sc_g_w]
    mov     ecx, [rip+sc_g_n]
    shl     ecx, 2
    test    rsi, rsi
    jz      3f
    rep     movsb
3:  mov     rdi, [rip+sc_g_idx]
    test    rdi, rdi
    jz      4f
    mov     esi, [rip+sc_g_cap]
    shl     rsi, 3
    add     rsi, 4095
    and     rsi, -4096
    mov     eax, SYS_MUNMAP
    syscall
4:  mov     [rip+sc_g_idx], r13
    mov     eax, r12d
    lea     rax, [r13+rax*4]
    mov     [rip+sc_g_w], rax
    mov     [rip+sc_g_cap], r12d
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# grab_move(pk_p = the pointer on the grab plane) - the captured vertices
#   move with it, by their weights; boxes and normals follow
grab_move:
    push    rbx
    push    r12
    sub     rsp, 24
    xor     ecx, ecx                    # the move since the last
1:  lea     rax, [rip+pk_p]
    movss   xmm0, [rax+rcx*4]
    lea     rax, [rip+sc_last]
    subss   xmm0, [rax+rcx*4]
    movss   [rsp+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      1b
    xor     ebx, ebx
2:  cmp     ebx, [rip+sc_g_n]
    jae     3f
    mov     rax, [rip+sc_g_idx]
    mov     ecx, [rax+rbx*4]
    mov     rax, [rip+sc_g_w]
    movss   xmm7, [rax+rbx*4]
    lea     rax, [rcx+rcx*2]
    mov     rdx, [rip+sv_pos]
    lea     rdx, [rdx+rax*4]
    movss   xmm0, [rsp]                 # x flips for mirrored captures
    xorps   xmm1, xmm1
    comiss  xmm7, xmm1
    jae     21f
    subss   xmm1, xmm0
    movss   xmm0, xmm1
    andps   xmm7, [rip+sf_abs]
21: mulss   xmm0, xmm7
    addss   xmm0, [rdx]
    movss   [rdx], xmm0
    movss   xmm0, [rsp+4]
    mulss   xmm0, xmm7
    addss   xmm0, [rdx+4]
    movss   [rdx+4], xmm0
    movss   xmm0, [rsp+8]
    mulss   xmm0, xmm7
    addss   xmm0, [rdx+8]
    movss   [rdx+8], xmm0
    inc     ebx
    jmp     2b
3:  mov     rax, [rip+pk_p]
    mov     [rip+sc_last], rax
    mov     eax, [rip+pk_p+8]
    mov     [rip+sc_last+8], eax
    # the region: the start's sphere grown by how far it went (and its
    # mirror): boxes and normals again
    xorps   xmm1, xmm1
    xor     ecx, ecx
4:  lea     rax, [rip+pk_p]
    movss   xmm0, [rax+rcx*4]
    lea     rax, [rip+sc_gstart]
    subss   xmm0, [rax+rcx*4]
    mulss   xmm0, xmm0
    addss   xmm1, xmm0
    inc     ecx
    cmp     ecx, 3
    jb      4b
    sqrtss  xmm1, xmm1
    addss   xmm1, [rip+sc_lastr]
    movss   [rsp+12], xmm1
    mov     rax, [rip+sc_gstart]
    mov     [rip+dab_p], rax
    mov     eax, [rip+sc_gstart+8]
    mov     [rip+dab_p+8], eax
    call    grab_region
    test    dword ptr [rip+sc_sym], 1
    jz      5f
    movss   xmm0, [rip+dab_p]
    xorps   xmm1, xmm1
    subss   xmm1, xmm0
    movss   [rip+dab_p], xmm1
    movss   xmm1, [rsp+12]
    call    grab_region
5:  mov     dword ptr [rip+dirty], 1
    add     rsp, 24
    pop     r12
    pop     rbx
    ret

# grab_region(xmm1=radius around dab_p) - boxes and normals there
grab_region:
    sub     rsp, 24
    movss   [rsp], xmm1
    movss   xmm0, xmm1
    xor     edi, edi
    call    reach
    lea     rdi, [rip+job_box]
    mov     esi, [rip+sc_nh]
    call    pfor
    movss   xmm0, [rsp]
    call    normals_near
    add     rsp, 24
    ret

# refresh_all - every leaf box and normal again (undo)
refresh_all:
    push    rbx
    xor     ebx, ebx
1:  cmp     ebx, [rip+sc_nnodes]
    jae     2f
    mov     edi, ebx
    call    node_box
    inc     ebx
    jmp     1b
2:  call    normals_all
    mov     dword ptr [rip+dirty], 1
    pop     rbx
    ret

# sculpt_after_undo(rdi=mesh) - its positions changed under us
sculpt_after_undo:
    cmp     dword ptr [rip+sc_obj], 0
    je      1f
    cmp     rdi, [rip+sc_mesh]
    jne     1f
    jmp     refresh_all
1:  ret

# sculpt_mask_op(edi=0 clear, 1 invert, 2 fill)
sculpt_mask_op:
    cmp     dword ptr [rip+sc_obj], 0
    je      9f
    mov     rax, [rip+sc_mask]
    test    rax, rax
    jz      9f
    xor     ecx, ecx
    test    edi, edi                    # (anything masked from now on?)
    setnz   cl
    mov     [rip+sc_masked], ecx
    xor     ecx, ecx
1:  cmp     ecx, [rip+sc_nv]
    jae     8f
    movzx   edx, byte ptr [rax+rcx]
    test    edi, edi
    jnz     2f
    xor     edx, edx
    jmp     3f
2:  cmp     edi, 1
    jne     21f
    xor     edx, 255
    jmp     3f
21: mov     edx, 255
3:  mov     [rax+rcx], dl
    inc     ecx
    jmp     1b
8:  mov     dword ptr [rip+sc_full], 1
    mov     dword ptr [rip+dirty], 1
9:  ret

# sculpt_dab_world(edi=brush, rsi=from world float[3], rdx=to world, xmm0=
#   radius (world), xmm1=strength) -> eax = 1: a stroke of dabs from one
#   point to the other (scripts and agents; the object must be in sculpt
#   mode), one undo step
sculpt_dab_world:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 72
    mov     ebx, edi
    mov     r12, rsi
    mov     r13, rdx
    movss   [rsp], xmm0
    movss   [rsp+4], xmm1
    call    sculpt_valid
    test    rax, rax
    jz      8f
    mov     eax, [rip+sc_brush]         # this brush, this strength
    mov     [rsp+8], eax
    mov     [rip+sc_brush], ebx
    mov     eax, [rip+sc_strength]
    mov     [rsp+12], eax
    movss   xmm0, [rsp+4]
    xorps   xmm1, xmm1                  # (negative: inverted)
    xor     edi, edi
    comiss  xmm0, xmm1
    jae     1f
    mov     edi, MOD_CTRL
    andps   xmm0, [rip+sf_abs]
1:  movss   [rip+sc_strength], xmm0
    call    stroke_begin
    lea     rdi, [rip+sc_mi]            # the ends, local
    mov     rsi, r12
    lea     rdx, [rsp+16]
    call    xform_point
    lea     rdi, [rip+sc_mi]
    mov     rsi, r13
    lea     rdx, [rsp+28]
    call    xform_point
    movss   xmm0, [rsp]                 # the radius, local
    movss   xmm1, [rip+sc_m]
    mulss   xmm1, xmm1
    movss   xmm2, [rip+sc_m+16]
    mulss   xmm2, xmm2
    addss   xmm1, xmm2
    movss   xmm2, [rip+sc_m+32]
    mulss   xmm2, xmm2
    addss   xmm1, xmm2
    sqrtss  xmm1, xmm1
    maxss   xmm1, [rip+sf_tiny]
    divss   xmm0, xmm1
    movss   [rsp+40], xmm0
    xor     ecx, ecx                    # length / (10% of the radius) dabs
    xorps   xmm2, xmm2
2:  movss   xmm0, [rsp+28+rcx*4]
    subss   xmm0, [rsp+16+rcx*4]
    movss   [rsp+44+rcx*4], xmm0        # the way
    mulss   xmm0, xmm0
    addss   xmm2, xmm0
    inc     ecx
    cmp     ecx, 3
    jb      2b
    sqrtss  xmm2, xmm2
    movss   xmm0, [rsp+40]
    mulss   xmm0, [rip+sf_spacing]
    maxss   xmm0, [rip+sf_tiny]
    divss   xmm2, xmm0
    cvttss2si r14d, xmm2
    cmp     r14d, 4096
    jle     3f
    mov     r14d, 4096
3:  test    r14d, r14d
    jnz     31f
    mov     r14d, 1
31: cmp     ebx, B_GRAB                 # grab: capture at the start, move to
    jne     4f                          #  the end
    mov     rax, [rsp+16]
    mov     [rip+dab_p], rax
    mov     eax, [rsp+24]
    mov     [rip+dab_p+8], eax
    movss   xmm0, [rsp+40]
    movss   [rip+sc_lastr], xmm0
    mov     rax, [rsp+16]
    mov     [rip+sc_last], rax
    mov     eax, [rsp+24]
    mov     [rip+sc_last+8], eax
    call    grab_capture
    mov     rax, [rsp+28]
    mov     [rip+pk_p], rax
    mov     eax, [rsp+36]
    mov     [rip+pk_p+8], eax
    call    grab_move
    jmp     7f
4:  xor     r13d, r13d                  # dabs k = 0 .. n
5:  cmp     r13d, r14d
    jg      7f
    cvtsi2ss xmm0, r13d
    cvtsi2ss xmm1, r14d
    divss   xmm0, xmm1
    xor     ecx, ecx
6:  movss   xmm1, [rsp+44+rcx*4]
    mulss   xmm1, xmm0
    addss   xmm1, [rsp+16+rcx*4]
    lea     rax, [rip+dab_p]
    movss   [rax+rcx*4], xmm1
    inc     ecx
    cmp     ecx, 3
    jb      6b
    cmp     ebx, B_SNAKE                # snake: each dab moves by a step
    jne     61f
    xor     ecx, ecx
62: movss   xmm1, [rsp+44+rcx*4]
    cvtsi2ss xmm2, r14d
    divss   xmm1, xmm2
    lea     rax, [rip+dab_move]
    movss   [rax+rcx*4], xmm1
    inc     ecx
    cmp     ecx, 3
    jb      62b
61: movss   xmm0, [rsp+40]
    call    do_dab
    inc     r13d
    jmp     5b
7:  call    stroke_end
    mov     eax, [rsp+8]
    mov     [rip+sc_brush], eax
    mov     eax, [rsp+12]
    mov     [rip+sc_strength], eax
    mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 72
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  The overlay: the brush circle at the pointer, the settings
# =============================================================================
sculpt_hover:
    mov     [rip+sd_hx], edi
    mov     [rip+sd_hy], esi
    mov     dword ptr [rip+sd_hover], 1
    cmp     dword ptr [rip+sc_obj], 0
    je      1f
    mov     dword ptr [rip+dirty], 1
1:  ret

sculpt_overlay:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 32
    cmp     dword ptr [rip+sc_obj], 0
    je      .Lso_out
    call    fmt_reset                   # "Sculpt: draw  radius 50 ..."
    lea     rdi, [rip+s_hud]
    call    fmt_str
    mov     eax, [rip+sc_brush]
    lea     rcx, [rip+brush_names]
    mov     rdi, [rcx+rax*8]
    call    fmt_str
    lea     rdi, [rip+s_hud_r]
    call    fmt_str
    cvttss2si edi, [rip+sc_radius]
    call    fmt_int
    lea     rdi, [rip+s_hud_s]
    call    fmt_str
    movss   xmm0, [rip+sc_strength]
    call    fmt_val3
    test    dword ptr [rip+sc_sym], 1
    jz      1f
    lea     rdi, [rip+s_hud_sym]
    call    fmt_str
1:  lea     rdi, [rip+s_hud_keys]
    call    fmt_str
    mov     edi, [rip+cvs_x0]
    add     edi, 10
    mov     esi, [rip+cvs_y0]
    add     esi, 62
    lea     rdx, [rip+fmt_buf]
    mov     ecx, COL_ACTIVE
    call    draw_text
    call    fmt_reset                   # "stabilizer 25   pen: strength (soft)"
    xor     ebx, ebx
    mov     rdi, [rip+sc_mesh]          # multires: the level
    call    mr_owns
    test    eax, eax
    jz      9f
    lea     rdi, [rip+s_hud_mr]
    call    fmt_str
    mov     edi, [rip+mr_klev]
    call    fmt_int
    inc     ebx
9:  test    ebx, ebx
    jz      91f
    cmp     dword ptr [rip+sc_lazy], 0
    je      91f
    lea     rdi, [rip+s_hud_gap]
    call    fmt_str
91: cmp     dword ptr [rip+sc_lazy], 0
    je      10f
    lea     rdi, [rip+s_hud_lazy]
    call    fmt_str
    mov     edi, [rip+sc_lazy]
    call    fmt_int
    inc     ebx
10: cmp     dword ptr [rip+sc_dyn], 0
    je      11f
    test    ebx, ebx
    jz      101f
    lea     rdi, [rip+s_hud_gap]
    call    fmt_str
101:inc     ebx
    lea     rdi, [rip+s_hud_dyn]
    call    fmt_str
    cvttss2si edi, [rip+dyn_detail]
    call    fmt_int
    lea     rdi, [rip+s_px]
    call    fmt_str
11: cmp     dword ptr [rip+in_pen], 0   # (once a pen has been seen)
    je      14f
    test    ebx, ebx
    jz      111f
    lea     rdi, [rip+s_hud_gap]
    call    fmt_str
111:inc     ebx
    lea     rdi, [rip+s_hud_pen]
    call    fmt_str
    test    dword ptr [rip+sc_pmap], 3
    jnz     12f
    lea     rdi, [rip+s_hud_poff]
    call    fmt_str
    jmp     14f
12: test    dword ptr [rip+sc_pmap], 1
    jz      13f
    lea     rdi, [rip+s_hud_pstr]
    call    fmt_str
13: test    dword ptr [rip+sc_pmap], 2
    jz      131f
    lea     rdi, [rip+s_hud_prad]
    call    fmt_str
131:mov     eax, [rip+sc_pcurve]
    lea     rcx, [rip+curve_names]
    mov     rdi, [rcx+rax*8]
    call    fmt_str
14: test    ebx, ebx
    jz      15f
    mov     edi, [rip+cvs_x0]
    add     edi, 10
    mov     esi, [rip+cvs_y0]
    add     esi, 80
    lea     rdx, [rip+fmt_buf]
    mov     ecx, COL_ACTIVE
    call    draw_text
15: cmp     dword ptr [rip+sc_lazy], 0  # stroking with the stabilizer: its
    je      16f                         #  string, pointer to stroke
    cmp     dword ptr [rip+sc_stroking], 0
    je      16f
    cmp     dword ptr [rip+sd_hover], 0
    je      16f
    cvttss2si edi, [rip+lz_x]
    cvttss2si esi, [rip+lz_y]
    mov     edx, [rip+sd_hx]
    mov     ecx, [rip+sd_hy]
    mov     r8d, 0xf0f0f0
    call    draw_line
16:
    cmp     dword ptr [rip+sd_hover], 0 # the brush circle
    je      .Lso_out
    xor     ebx, ebx                    # 32 segments (logical pixels)
2:  cmp     ebx, 32
    jae     .Lso_out
    mov     edi, ebx
    call    circ_pt
    mov     r12d, eax
    mov     r13d, edx
    lea     edi, [rbx+1]
    call    circ_pt
    mov     ecx, edx
    mov     edx, eax
    mov     edi, r12d
    mov     esi, r13d
    mov     r8d, 0xf0f0f0
    call    draw_line
    inc     ebx
    jmp     2b
.Lso_out:
    add     rsp, 32
    pop     r13
    pop     r12
    pop     rbx
    ret

# circ_pt(edi=k of 32) -> eax, edx = the brush circle's k-th point
circ_pt:
    sub     rsp, 24
    cvtsi2ss xmm0, edi
    mulss   xmm0, [rip+sf_2pi32]
    call    sincos                      # xmm0 sin, xmm1 cos
    mulss   xmm0, [rip+sc_radius]
    mulss   xmm1, [rip+sc_radius]
    cvttss2si eax, xmm1
    add     eax, [rip+sd_hx]
    cvttss2si edx, xmm0
    add     edx, [rip+sd_hy]
    add     rsp, 24
    ret

# =============================================================================
#  Operators (keys work in sculpt mode)
# =============================================================================
OPERATOR op_sb_draw,    "sculpt.brush_draw",    "Draw",        do_brush, arg=B_DRAW,    key=KEY_X,             flags=OPF_AI_SAFE|OPF_QUIET|OPF_SCULPT, doc="Sculpt brush: raise the surface along its normal"
OPERATOR op_sb_clay,    "sculpt.brush_clay",    "Clay Strips", do_brush, arg=B_CLAY,    key=KEY_C,             flags=OPF_AI_SAFE|OPF_QUIET|OPF_SCULPT, doc="Sculpt brush: build up towards a plane above the surface"
OPERATOR op_sb_crease,  "sculpt.brush_crease",  "Crease",      do_brush, arg=B_CREASE,  key=KEY_C|KM_SHIFT,    flags=OPF_AI_SAFE|OPF_QUIET|OPF_SCULPT, doc="Sculpt brush: cut a sharp groove"
OPERATOR op_sb_inflate, "sculpt.brush_inflate", "Inflate",     do_brush, arg=B_INFLATE, key=KEY_I,             flags=OPF_AI_SAFE|OPF_QUIET|OPF_SCULPT, doc="Sculpt brush: push each vertex along its own normal"
OPERATOR op_sb_grab,    "sculpt.brush_grab",    "Grab",        do_brush, arg=B_GRAB,    key=KEY_G,             flags=OPF_AI_SAFE|OPF_QUIET|OPF_SCULPT, doc="Sculpt brush: move what was under the brush with the pointer"
OPERATOR op_sb_snake,   "sculpt.brush_snake",   "Snake Hook",  do_brush, arg=B_SNAKE,   key=KEY_K,             flags=OPF_AI_SAFE|OPF_QUIET|OPF_SCULPT, doc="Sculpt brush: pull the surface along the stroke"
OPERATOR op_sb_smooth,  "sculpt.brush_smooth",  "Smooth",      do_brush, arg=B_SMOOTH,  key=KEY_S,             flags=OPF_AI_SAFE|OPF_QUIET|OPF_SCULPT, doc="Sculpt brush: relax towards the neighbours (Shift with any brush)"
OPERATOR op_sb_flatten, "sculpt.brush_flatten", "Flatten",     do_brush, arg=B_FLATTEN, key=KEY_T|KM_SHIFT,    flags=OPF_AI_SAFE|OPF_QUIET|OPF_SCULPT, doc="Sculpt brush: towards the average plane"
OPERATOR op_sb_pinch,   "sculpt.brush_pinch",   "Pinch",       do_brush, arg=B_PINCH,   key=KEY_P,             flags=OPF_AI_SAFE|OPF_QUIET|OPF_SCULPT, doc="Sculpt brush: draw the surface together"
OPERATOR op_sb_layer,   "sculpt.brush_layer",   "Layer",       do_brush, arg=B_LAYER,   key=KEY_L,             flags=OPF_AI_SAFE|OPF_QUIET|OPF_SCULPT, doc="Sculpt brush: raise a layer of even height"
OPERATOR op_sb_mask,    "sculpt.brush_mask",    "Mask",        do_brush, arg=B_MASK,    key=KEY_M,             flags=OPF_AI_SAFE|OPF_QUIET|OPF_SCULPT, doc="Sculpt brush: paint a mask that other brushes leave alone (Ctrl erases)"
OPERATOR op_s_rad_dn,   "sculpt.radius_down",   "Smaller Brush", do_radius, arg=0,      key=KEY_LEFTBRACE,     flags=OPF_AI_SAFE|OPF_QUIET|OPF_SCULPT, doc="Sculpt: brush radius - 15%"
OPERATOR op_s_rad_up,   "sculpt.radius_up",     "Bigger Brush",  do_radius, arg=1,      key=KEY_RIGHTBRACE,    flags=OPF_AI_SAFE|OPF_QUIET|OPF_SCULPT, doc="Sculpt: brush radius + 15%"
OPERATOR op_s_str_dn,   "sculpt.strength_down", "Weaker",        do_strength, arg=0,    key=KEY_LEFTBRACE|KM_SHIFT, flags=OPF_AI_SAFE|OPF_QUIET|OPF_SCULPT, doc="Sculpt: strength - 0.1"
OPERATOR op_s_str_up,   "sculpt.strength_up",   "Stronger",      do_strength, arg=1,    key=KEY_RIGHTBRACE|KM_SHIFT, flags=OPF_AI_SAFE|OPF_QUIET|OPF_SCULPT, doc="Sculpt: strength + 0.1"
OPERATOR op_s_sym,      "sculpt.symmetry_x",    "X Symmetry",    do_sym, check=sym_check, key=KEY_X|KM_SHIFT, flags=OPF_AI_SAFE|OPF_QUIET|OPF_SCULPT, doc="Sculpt: mirror strokes across the object's X"
OPERATOR op_s_mclear,   "sculpt.mask_clear",    "Clear Mask",    do_mask, arg=0,        key=KEY_M|KM_ALT,      flags=OPF_AI_SAFE|OPF_QUIET|OPF_SCULPT, doc="Sculpt: remove the mask"
OPERATOR op_s_lazy,     "sculpt.stabilizer",    "Stabilizer",    do_lazy, check=lazy_check, key=KEY_S|KM_SHIFT, flags=OPF_AI_SAFE|OPF_QUIET|OPF_SCULPT, doc="Sculpt: the stroke trails the pointer on a string (off, 10, 25, 50 px) for steady lines"
OPERATOR op_s_pstr,     "sculpt.pressure_strength", "Pressure: Strength", do_pmap, arg=1, check=pstr_check, flags=OPF_AI_SAFE|OPF_QUIET, doc="Sculpt: pen pressure scales the brush strength"
OPERATOR op_s_prad,     "sculpt.pressure_radius", "Pressure: Radius", do_pmap, arg=2, check=prad_check, flags=OPF_AI_SAFE|OPF_QUIET, doc="Sculpt: pen pressure scales the brush radius"
OPERATOR op_s_pcurve,   "sculpt.pressure_curve", "Pressure Curve", do_pcurve, flags=OPF_AI_SAFE|OPF_QUIET, doc="Sculpt: the pressure curve - soft, linear, hard"
OPERATOR op_s_minv,     "sculpt.mask_invert",   "Invert Mask",   do_mask, arg=1,        key=KEY_I|KM_CTRL,     flags=OPF_AI_SAFE|OPF_QUIET|OPF_SCULPT, doc="Sculpt: invert the mask"

do_brush:
    mov     [rip+sc_brush], edi
    mov     dword ptr [rip+dirty], 1
    ret
do_radius:
    movss   xmm0, [rip+sc_radius]
    test    edi, edi
    jz      1f
    mulss   xmm0, [rip+sf_grow]
    jmp     2f
1:  mulss   xmm0, [rip+sf_shrink]
2:  maxss   xmm0, [rip+sf_rmin]
    minss   xmm0, [rip+sf_rmax]
    movss   [rip+sc_radius], xmm0
    mov     dword ptr [rip+dirty], 1
    ret
do_strength:
    movss   xmm0, [rip+sc_strength]
    test    edi, edi
    jz      1f
    addss   xmm0, [rip+sf_tenth]
    jmp     2f
1:  subss   xmm0, [rip+sf_tenth]
2:  maxss   xmm0, [rip+sf_tenth]
    minss   xmm0, [rip+sf_one]
    movss   [rip+sc_strength], xmm0
    mov     dword ptr [rip+dirty], 1
    ret
do_sym:
    xor     dword ptr [rip+sc_sym], 1
    mov     dword ptr [rip+dirty], 1
    ret
sym_check:
    mov     eax, [rip+sc_sym]
    and     eax, 1
    ret
do_mask:
    jmp     sculpt_mask_op
do_lazy:                                # off, 10, 25, 50 pixels
    mov     eax, [rip+sc_lazy]
    mov     ecx, 10
    test    eax, eax
    jz      1f
    mov     ecx, 25
    cmp     eax, 10
    je      1f
    mov     ecx, 50
    cmp     eax, 25
    je      1f
    xor     ecx, ecx
1:  mov     [rip+sc_lazy], ecx
    sub     rsp, 8
    call    fmt_reset
    lea     rdi, [rip+s_lazy_log]
    call    fmt_str
    mov     edi, [rip+sc_lazy]
    call    fmt_int
    lea     rdi, [rip+s_px]
    call    fmt_str
    lea     rdi, [rip+fmt_buf]
    call    log_line
    add     rsp, 8
    mov     dword ptr [rip+dirty], 1
    ret
lazy_check:
    xor     eax, eax
    cmp     dword ptr [rip+sc_lazy], 0
    setne   al
    ret
do_pmap:                                # edi = 1 strength, 2 radius
    xor     [rip+sc_pmap], edi
    mov     dword ptr [rip+dirty], 1
    ret
pstr_check:
    mov     eax, [rip+sc_pmap]
    and     eax, 1
    ret
prad_check:
    mov     eax, [rip+sc_pmap]
    shr     eax, 1
    and     eax, 1
    ret
do_pcurve:
    mov     eax, [rip+sc_pcurve]
    inc     eax
    cmp     eax, 3
    jb      1f
    xor     eax, eax
1:  mov     [rip+sc_pcurve], eax
    mov     dword ptr [rip+dirty], 1
    ret

.section .bss
.align 8
sv_pos:         .skip 8
sv_tris:        .skip 8
.text

.section .note.GNU-stack,"",@progbits
