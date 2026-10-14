# =============================================================================
#  BeeModel - B-rep booleans (union, difference)
#
#  1. Both solids are tessellated (for inside / outside), every pair of
#     faces whose boxes meet is intersected (bssi.s); faces on the same
#     plane are paired instead.
#  2. Each section curve is cut where it crosses either face's boundary:
#     the crossing is found exactly on the boundary edge (a root of the
#     distance to the other surface along it) and becomes a vertex that
#     splits that edge, shared by everything that finds the same point. The
#     pieces inside both faces become new edges (lines and circles stay
#     exact, traced curves become polylines on both surfaces).
#  3. Every face cut by a section, or whose edges were split, is divided:
#     its boundary pieces (one way round), the section edges in it and a
#     paired face's edges inside it (both ways) are walked in its (u, v),
#     turning the sharpest way at each vertex, into cycles; outer cycles
#     with the holes inside them are its regions.
#  4. A point inside each region says where it lies: inside or outside the
#     other solid, or on its paired face facing the same or the other way.
#     Union keeps A outside B, B outside A and A on B facing the same way;
#     difference keeps A outside B, A on B facing the other way and B inside
#     A turned inside out. The kept regions are the result's faces.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "brep.inc"

.globl bk_bool
.globl bk_err

.equ OP_UNION,  0
.equ OP_DIFF,   1
.equ C_OUT,     0
.equ C_IN,      1
.equ C_SAME,    2
.equ C_OPP,     3
.equ MAXLF,     4096
.equ BS_SZ,     64                      # a boundary segment of a face
.equ BS_U0,     0
.equ BS_V0,     8
.equ BS_U1,     16
.equ BS_V1,     24
.equ BS_T0,     32
.equ BS_T1,     40
.equ BS_E,      48
.equ MAXBS,     131072
.equ MAXSPL,    65536
.equ MAXNV,     65536
.equ MAXSPC,    65536
.equ MAXCR,     16384
.equ MAXEPL,    262144
.equ HE_SZ,     64                      # a half-edge of a face's arrangement
.equ HE_E,      0
.equ HE_REV,    4
.equ HE_V0,     8
.equ HE_V1,     12
.equ HE_USED,   16
.equ HE_P,      20                      # its points (scaled, oriented (u, v))
.equ HE_N,      24
.equ HE_ANG,    32                      # its first direction
.equ HE_RANG,   40                      # the reverse of its last
.equ MAXHE,     16384
.equ MAXHP,     1048576
.equ MAXCY,     4096
.equ MAXCL,     32768

.section .rodata
.align 16
bo_absm:        .quad 0x7fffffffffffffff, 0x7fffffffffffffff
bo_negm:        .quad 0x8000000000000000, 0x8000000000000000
bo_one:         .double 1.0
bo_half:        .double 0.5
bo_2pi:         .double 6.28318530717958647692
bo_pi:          .double 3.14159265358979323846
bo_rweld:       .double 1.0e-8
bo_ron:         .double 1.0e-7
bo_rsec:        .double 1.0e-6
bo_rtess:       .double 2.0e-4
bo_angeps:      .double 1.0e-10
bo_tiny:        .double 1.0e-14
bo_big:         .double 1.0e300
bo_grow:        .double 1.0e-6         # bracket growth (of the edge's range)
bo_left:        .double 1.0e-3
bo_gold:        .double 0.6180339887498949

.section .bss
.align 8
bo_a:           .skip 4
bo_b:           .skip 4
bo_op:          .skip 4
bo_fail:        .skip 4
bk_err:         .skip 4                 # why the last boolean failed
bo_size:        .skip 8
bo_weld:        .skip 8
bo_on:          .skip 8
# local faces: A's then B's
lf_n:           .skip 4
lf_na:          .skip 4
lf_face:        .skip 4*MAXLF
lf_coin:        .skip 4*MAXLF
lf_touch:       .skip 4*MAXLF
lf_bs0:         .skip 4*MAXLF
lf_bsn:         .skip 4*MAXLF
.align 8
lf_box:         .skip 48*MAXLF
lf_su:          .skip 8*MAXLF
lf_sv:          .skip 8*MAXLF
bs_rec:         .skip BS_SZ*MAXBS
bs_n:           .skip 4
# splits of edges (heads in ED_AUX), new vertices
.align 8
spl_t:          .skip 8*MAXSPL
spl_v:          .skip 4*MAXSPL
spl_next:       .skip 4*MAXSPL
spl_n:          .skip 4
nv_v:           .skip 4*MAXNV
nv_n:           .skip 4
# edges of one solid lying in a face of the other (from sections along
#   them): put into that face
ins_e:          .skip 4*4096
ins_f:          .skip 4*4096
ins_n:          .skip 4
# the solids' own vertices (welding, snapping)
ov_v:           .skip 4*65536
ov_n:           .skip 4
ov_mark:        .skip 8
# section pieces: edge, local face a, local face b
spc_e:          .skip 4*MAXSPC
spc_a:          .skip 4*MAXSPC
spc_b:          .skip 4*MAXSPC
spc_n:          .skip 4
# one section's crossings
.align 8
cr_pos:         .skip 8*MAXCR
cr_v:           .skip 4*MAXCR
cr_n:           .skip 4
# edge pieces (by edge index)
ep_first:       .skip 8                 # (arrays in bk_data)
ep_cnt:         .skip 8
ep_cap:         .skip 4
ep_list:        .skip 4*MAXEPL
ep_n:           .skip 4
# a face's arrangement
.align 8
he_rec:         .skip HE_SZ*MAXHE
he_n:           .skip 4
hp_pts:         .skip 16*MAXHP
hp_n:           .skip 4
cy_first:       .skip 4*MAXCY
cy_cnt:         .skip 4*MAXCY
cy_par:         .skip 4*MAXCY
.align 8
cy_area:        .skip 8*MAXCY
cy_list:        .skip 4*MAXCL
cy_n:           .skip 4
cy_ln:          .skip 4
af_lf:          .skip 4                 # the face being divided
af_f:           .skip 4
af_surf:        .skip 8
af_su:          .skip 8
af_sv:          .skip 8                 # (negative for sense 1)
af_hu:          .skip 8                 # inversion hints
af_hv:          .skip 8

.text

# =============================================================================
#  The operation
# =============================================================================
# bk_bool(edi=A, esi=B, edx=OP_UNION / OP_DIFF) -> eax = the result, or -1
bk_bool:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 40
    mov     [rip+bo_a], edi
    mov     [rip+bo_b], esi
    mov     [rip+bo_op], edx
    mov     dword ptr [rip+bo_fail], 0
    mov     dword ptr [rip+bk_err], 0
    # sizes and tolerances
    call    bd_reach
    movsd   [rsp], xmm0
    mov     edi, [rip+bo_b]
    call    bd_reach
    maxsd   xmm0, [rsp]
    movsd   [rip+bo_size], xmm0
    movsd   xmm1, xmm0
    mulsd   xmm1, [rip+bo_rweld]
    movsd   [rip+bo_weld], xmm1
    movsd   xmm1, xmm0
    mulsd   xmm1, [rip+bo_ron]
    movsd   [rip+bo_on], xmm1
    movsd   xmm1, xmm0
    mulsd   xmm1, [rip+bo_rsec]
    movsd   [rip+ss_tol], xmm1
    mulsd   xmm0, [rip+bo_rtess]
    movsd   [rip+bt_tol], xmm0
    mov     edi, [rip+bo_a]
    call    bd_tess
    mov     edi, [rip+bo_b]
    call    bd_tess
    call    ss_reset
    xor     eax, eax
    mov     [rip+spl_n], eax
    mov     [rip+nv_n], eax
    mov     [rip+spc_n], eax
    mov     [rip+ins_n], eax
    mov     [rip+ov_n], eax
    mov     [rip+ep_n], eax
    mov     [rip+bs_n], eax
    call    bo_faces
    cmp     dword ptr [rip+bo_fail], 0
    jne     .Lbk_f1
    # pairs: paired planes or sections
    xor     ebx, ebx
.Lbk_pa:
    cmp     ebx, [rip+lf_na]
    jae     .Lbk_secs
    mov     r12d, [rip+lf_na]
.Lbk_pb:
    cmp     r12d, [rip+lf_n]
    jae     .Lbk_pan
    mov     edi, ebx
    mov     esi, r12d
    call    boxes_meet
    test    eax, eax
    jz      .Lbk_pbn
    lea     rcx, [rip+lf_face]
    mov     edi, [rcx+rbx*4]
    call    p_fc
    mov     edi, [rax+FC_SURF]
    call    p_sf
    mov     r13, rax
    lea     rcx, [rip+lf_face]
    mov     edi, [rcx+r12*4]
    call    p_fc
    mov     edi, [rax+FC_SURF]
    call    p_sf
    mov     r14, rax
    mov     rdi, r13
    mov     rsi, r14
    call    sf_coincide
    test    eax, eax
    jz      2f
    cmp     dword ptr [r13+SF_TYPE], ST_PLANE   # only planes can be paired
    jne     .Lbk_f2
    lea     rcx, [rip+lf_coin]          # (one partner each)
    cmp     dword ptr [rcx+rbx*4], -1
    jne     .Lbk_f3
    cmp     dword ptr [rcx+r12*4], -1
    jne     .Lbk_f4
    mov     [rcx+rbx*4], r12d
    mov     [rcx+r12*4], ebx
    lea     rcx, [rip+lf_touch]
    mov     dword ptr [rcx+rbx*4], 1
    mov     dword ptr [rcx+r12*4], 1
    jmp     .Lbk_pbn
2:  lea     rcx, [rip+lf_face]
    mov     edi, [rcx+rbx*4]
    mov     esi, [rcx+r12*4]
    call    ssi
.Lbk_pbn:
    inc     r12d
    jmp     .Lbk_pb
.Lbk_pan:
    inc     ebx
    jmp     .Lbk_pa
.Lbk_secs:
    xor     ebx, ebx
1:  cmp     ebx, [rip+ss_n]
    jae     2f
    mov     edi, ebx
    call    bo_section
    inc     ebx
    jmp     1b
2:  cmp     dword ptr [rip+bo_fail], 0
    jne     .Lbk_f5
    call    snap_vertices               # new vertices on existing edges
    call    bo_pieces
    cmp     dword ptr [rip+bo_fail], 0
    jne     .Lbk_f6
    call    bb_begin
    xor     ebx, ebx
3:  cmp     ebx, [rip+lf_n]
    jae     4f
    mov     edi, ebx
    call    bo_face
    inc     ebx
    jmp     3b
4:  call    bb_end
    mov     r15d, eax
    cmp     dword ptr [rip+bo_fail], 0
    jne     .Lbk_f7
    mov     edi, r15d
    call    p_bd
    cmp     dword ptr [rax+BD_NF], 0
    je      .Lbk_f8
    mov     ebx, [rax+BD_FIRST]
    mov     r12d, [rax+BD_NF]
    add     r12d, ebx
5:  cmp     ebx, r12d
    jae     6f
    mov     edi, ebx
    call    fc_pcurves
    mov     edi, ebx
    call    fc_box
    inc     ebx
    jmp     5b
6:  mov     edi, r15d
    call    bd_check
    mov     [rsp+8], eax
    call    bk_keep                     # (debugging: kept, shown)
    test    eax, eax
    jnz     7f
    cmp     dword ptr [rsp+8], 0
    jne     .Lbk_f9
    jmp     8f
7:  mov     edi, r15d
    mov     esi, [rsp+8]
    mov     edx, 9999
    call    bk_note
    mov     edi, r15d
    call    bk_dump
8:
    mov     eax, r15d
    jmp     .Lbk_out
.Lbk_f1:
    mov     dword ptr [rip+bk_err], 1
    jmp     .Lbk_fail
.Lbk_f2:
    mov     dword ptr [rip+bk_err], 2
    jmp     .Lbk_fail
.Lbk_f3:
    mov     dword ptr [rip+bk_err], 3
    jmp     .Lbk_fail
.Lbk_f4:
    mov     dword ptr [rip+bk_err], 4
    jmp     .Lbk_fail
.Lbk_f5:
    mov     dword ptr [rip+bk_err], 5
    jmp     .Lbk_fail
.Lbk_f6:
    mov     dword ptr [rip+bk_err], 6
    jmp     .Lbk_fail
.Lbk_f7:
    mov     dword ptr [rip+bk_err], 7
    jmp     .Lbk_fail
.Lbk_f8:
    mov     dword ptr [rip+bk_err], 8
    jmp     .Lbk_fail
.Lbk_f9:
    mov     dword ptr [rip+bk_err], 9
    jmp     .Lbk_fail
.Lbk_fail:
    mov     eax, -1
.Lbk_out:
    add     rsp, 40
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# boxes_meet(edi, esi = local faces) -> eax = 1 if their boxes overlap
boxes_meet:
    lea     rax, [rip+lf_box]
    imul    rdi, rdi, 48
    imul    rsi, rsi, 48
    add     rdi, rax
    add     rsi, rax
    movsd   xmm7, [rip+bo_on]
    xor     ecx, ecx
1:  movsd   xmm0, [rdi+24+rcx*8]        # a max >= b min, b max >= a min
    addsd   xmm0, xmm7
    comisd  xmm0, [rsi+rcx*8]
    jb      8f
    movsd   xmm0, [rsi+24+rcx*8]
    addsd   xmm0, xmm7
    comisd  xmm0, [rdi+rcx*8]
    jb      8f
    inc     ecx
    cmp     ecx, 3
    jb      1b
    mov     eax, 1
    ret
8:  xor     eax, eax
    ret

# =============================================================================
#  Faces, their boundaries
# =============================================================================
# bo_faces - the local faces: boxes, metric, boundary segments, marks
bo_faces:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     dword ptr [rip+lf_n], 0
    xor     r13d, r13d                  # A then B
.Lbx_body:
    cmp     r13d, 2
    jae     .Lbx_out
    mov     edi, [rip+bo_a]
    test    r13d, r13d
    jz      1f
    mov     edi, [rip+bo_b]
1:  call    p_bd
    mov     ebx, [rax+BD_FIRST]
    mov     r12d, [rax+BD_NF]
    add     r12d, ebx
2:  cmp     ebx, r12d
    jae     3f
    mov     eax, [rip+lf_n]
    cmp     eax, MAXLF
    jae     .Lbx_full
    lea     rcx, [rip+lf_face]
    mov     [rcx+rax*4], ebx
    lea     rcx, [rip+lf_coin]
    mov     dword ptr [rcx+rax*4], -1
    lea     rcx, [rip+lf_touch]
    mov     dword ptr [rcx+rax*4], 0
    mov     r14d, eax
    mov     edi, ebx
    call    p_fc
    mov     [rax+FC_MARK], r14d         # face -> local index
    mov     edi, ebx
    imul    eax, r14d, 48
    lea     rsi, [rip+lf_box]
    add     rsi, rax
    call    fc_bbox
    mov     edi, r14d
    call    bo_bsegs
    inc     dword ptr [rip+lf_n]
    inc     ebx
    jmp     2b
3:  test    r13d, r13d
    jnz     4f
    mov     eax, [rip+lf_n]
    mov     [rip+lf_na], eax
4:  inc     r13d
    jmp     .Lbx_body
.Lbx_full:
    mov     dword ptr [rip+bo_fail], 1
.Lbx_out:
    call    edges_reset
    call    own_vertices
    add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# own_vertices - ov_v: every vertex of both solids, once
own_vertices:
    push    rbx
    sub     rsp, 16
    mov     rdi, [rip+bk_vx+AR_USED]    # a byte per vertex: seen
    shr     rdi, 5
    add     rdi, 16
    mov     [rsp], rdi
    call    bk_data
    mov     [rip+ov_mark], rax
    mov     rdi, rax
    mov     rcx, [rsp]
    xor     eax, eax
    rep     stosb
    xor     ebx, ebx
1:  cmp     ebx, [rip+lf_n]
    jae     9f
    lea     rcx, [rip+lf_face]
    mov     edi, [rcx+rbx*4]
    lea     rsi, [rip+ov_take]
    call    each_coedge
    inc     ebx
    jmp     1b
9:  add     rsp, 16
    pop     rbx
    ret
ov_take:
    sub     rsp, 8
    mov     edi, [rax+CE_EDGE]
    call    p_ed
    mov     edi, [rax+ED_V0]
    call    ov_one
    mov     edi, [rax+ED_V1]
    call    ov_one
    add     rsp, 8
    ret
# ov_one(edi=vertex; rax kept)
ov_one:
    mov     rcx, [rip+ov_mark]
    cmp     byte ptr [rcx+rdi], 0
    jne     9f
    mov     byte ptr [rcx+rdi], 1
    mov     ecx, [rip+ov_n]
    cmp     ecx, 65536
    jae     9f
    lea     rdx, [rip+ov_v]
    mov     [rdx+rcx*4], edi
    inc     dword ptr [rip+ov_n]
9:  ret

# edges_reset - every edge of both solids: no splits, no pieces yet
edges_reset:
    push    rbx
    sub     rsp, 16
    mov     rax, [rip+bk_ed+AR_USED]    # piece tables by edge index (with
    shr     rax, 6                      #  room for the edges made later)
    add     eax, 65536
    mov     [rip+ep_cap], eax
    mov     edi, eax
    shl     edi, 2
    call    bk_data
    mov     [rip+ep_first], rax
    mov     rdi, rax
    mov     ecx, [rip+ep_cap]
    mov     eax, -1
    rep     stosd
    mov     edi, [rip+ep_cap]
    shl     edi, 2
    call    bk_data
    mov     [rip+ep_cnt], rax
    mov     rdi, rax
    mov     ecx, [rip+ep_cap]
    xor     eax, eax
    rep     stosd
    xor     ebx, ebx                    # ED_AUX = -1 (split list heads)
1:  cmp     ebx, [rip+lf_n]
    jae     9f
    lea     rcx, [rip+lf_face]
    mov     edi, [rcx+rbx*4]
    lea     rsi, [rip+ed_aux_clear]
    call    each_coedge
    inc     ebx
    jmp     1b
9:  add     rsp, 16
    pop     rbx
    ret
ed_aux_clear:
    sub     rsp, 8
    mov     edi, [rax+CE_EDGE]
    call    p_ed
    mov     dword ptr [rax+ED_AUX], -1
    add     rsp, 8
    ret

# each_coedge(edi=face, rsi=function (rax=coedge record, edx=index)) - called
#   for every coedge of the face, in loop order
each_coedge:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r15, rsi
    call    p_fc
    mov     ebx, [rax+FC_LOOP]
    mov     r12d, [rax+FC_NLOOP]
    add     r12d, ebx
1:  cmp     ebx, r12d
    jae     9f
    mov     edi, ebx
    call    p_lp
    mov     r13d, [rax+LP_FIRST]
    mov     r14d, [rax+LP_N]
    add     r14d, r13d
2:  cmp     r13d, r14d
    jae     3f
    mov     edi, r13d
    call    p_ce
    mov     edx, r13d
    call    r15
    inc     r13d
    jmp     2b
3:  inc     ebx
    jmp     1b
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# to_uv(rdi=surface, rsi=point, xmm0/xmm1 = guess) -> xmm0, xmm1 = its (u, v)
to_uv:
    push    rbx
    sub     rsp, 16
    movsd   [rsp], xmm0
    movsd   [rsp+8], xmm1
    cmp     dword ptr [rdi+SF_TYPE], ST_NURBS
    jne     1f
    call    sf_project
    jmp     9f
1:  call    sf_invert
    test    eax, eax
    jz      9f
    movsd   xmm0, [rsp]                 # (a pole: the guess)
    movsd   xmm1, [rsp+8]
9:  add     rsp, 16
    pop     rbx
    ret

# bo_bsegs(edi=local face) - its boundary as (u, v) segments with each
#   segment's edge and edge parameters
.equ BB_LF,   0
.equ BB_C,    4                         # coedge
.equ BB_K,    8
.equ BB_KN,   12
.equ BB_TS,   16
.equ BB_TE,   24
.equ BB_PU,   32                        # the previous point
.equ BB_PV,   40
.equ BB_PT,   48
.equ BB_UV,   56                        # ce_uv out
.equ BB_E,    88
.equ BB_REV,  96
.equ BB_L,    100
.equ BB_LN,   104
.equ BB_CN,   108
.equ BB_SURF, 112
.equ BB_F,    120
.equ BB_PRT,  128                       # t of the previous point
bo_bsegs:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 136
    mov     [rsp+BB_LF], edi
    mov     eax, [rip+bs_n]
    lea     rcx, [rip+lf_bs0]
    mov     [rcx+rdi*4], eax
    lea     rcx, [rip+lf_face]
    mov     edi, [rcx+rdi*4]
    call    p_fc
    mov     [rsp+BB_F], rax
    mov     rbx, rax
    mov     edi, [rbx+FC_SURF]
    call    p_sf
    mov     [rsp+BB_SURF], rax
    # metric scales at the box's middle
    movsd   xmm0, [rbx+FC_U0]
    addsd   xmm0, [rbx+FC_U1]
    mulsd   xmm0, [rip+bo_half]
    movsd   xmm1, [rbx+FC_V0]
    addsd   xmm1, [rbx+FC_V1]
    mulsd   xmm1, [rip+bo_half]
    mov     rdi, rax
    lea     rsi, [rsp+BB_UV-56+56]
    sub     rsp, 80
    lea     rsi, [rsp]
    call    srf_eval
    lea     rdi, [rsp+24]
    call    v3len
    maxsd   xmm0, [rip+bo_tiny]
    mov     eax, [rsp+80+BB_LF]
    lea     rcx, [rip+lf_su]
    movsd   [rcx+rax*8], xmm0
    lea     rdi, [rsp+48]
    call    v3len
    maxsd   xmm0, [rip+bo_tiny]
    mov     eax, [rsp+80+BB_LF]
    lea     rcx, [rip+lf_sv]
    movsd   [rcx+rax*8], xmm0
    add     rsp, 80
    mov     eax, [rbx+FC_LOOP]
    mov     [rsp+BB_L], eax
    add     eax, [rbx+FC_NLOOP]
    mov     [rsp+BB_LN], eax
.Lbs_loop:
    mov     eax, [rsp+BB_L]
    cmp     eax, [rsp+BB_LN]
    jae     .Lbs_out
    mov     edi, eax
    call    p_lp
    mov     ecx, [rax+LP_FIRST]
    mov     [rsp+BB_C], ecx
    add     ecx, [rax+LP_N]
    mov     [rsp+BB_CN], ecx
.Lbs_ce:
    mov     eax, [rsp+BB_C]
    cmp     eax, [rsp+BB_CN]
    jae     .Lbs_lnext
    mov     edi, eax
    call    p_ce
    mov     r13, rax
    mov     ecx, [r13+CE_REV]
    mov     [rsp+BB_REV], ecx
    mov     ecx, [r13+CE_EDGE]
    mov     [rsp+BB_E], ecx
    mov     edi, ecx
    call    p_ed
    mov     r14, rax
    test    dword ptr [r14+ED_FLAGS], EF_DEGEN
    jnz     .Lbs_degen
    movsd   xmm0, [r14+ED_T0]
    movsd   xmm1, [r14+ED_T1]
    cmp     dword ptr [rsp+BB_REV], 0
    je      1f
    movsd   xmm2, xmm0
    movsd   xmm0, xmm1
    movsd   xmm1, xmm2
1:  movsd   [rsp+BB_TS], xmm0
    movsd   [rsp+BB_TE], xmm1
    mov     ecx, [r14+ED_NPOLY]
    mov     [rsp+BB_KN], ecx
    mov     dword ptr [rsp+BB_K], 0
.Lbs_pt:
    mov     eax, [rsp+BB_K]
    cmp     eax, [rsp+BB_KN]
    jae     .Lbs_cnext
    mov     ecx, eax                    # the edge's point in walking order
    cmp     dword ptr [rsp+BB_REV], 0
    je      2f
    mov     ecx, [rsp+BB_KN]
    dec     ecx
    sub     ecx, eax
2:  shl     ecx, 5
    mov     r15, [r14+ED_POLY]
    add     r15, rcx
    movsd   xmm0, [r15+24]              # its pcurve guess
    movsd   [rsp+BB_PT], xmm0
    subsd   xmm0, [rsp+BB_TS]
    movsd   xmm1, [rsp+BB_TE]
    subsd   xmm1, [rsp+BB_TS]
    divsd   xmm0, xmm1
    mov     edi, [rsp+BB_C]
    lea     rsi, [rsp+BB_UV]
    call    ce_uv
    mov     rdi, [rsp+BB_SURF]
    mov     rsi, r15
    movsd   xmm0, [rsp+BB_UV]
    movsd   xmm1, [rsp+BB_UV+8]
    call    to_uv
    cmp     dword ptr [rsp+BB_K], 0
    je      3f
    movsd   xmm2, [rsp+BB_PT]           # a segment from the previous point
    call    bs_add
3:  movsd   [rsp+BB_PU], xmm0
    movsd   [rsp+BB_PV], xmm1
    movsd   xmm0, [rsp+BB_PT]
    movsd   [rsp+BB_PRT], xmm0
    inc     dword ptr [rsp+BB_K]
    jmp     .Lbs_pt
.Lbs_degen:
    mov     dword ptr [rsp+BB_E], -1    # a pole: its pcurve (no edge to cut)
    mov     dword ptr [rsp+BB_K], 0
4:  cmp     dword ptr [rsp+BB_K], 8
    ja      .Lbs_cnext
    cvtsi2sd xmm0, dword ptr [rsp+BB_K]
    mov     eax, 8
    cvtsi2sd xmm1, eax
    divsd   xmm0, xmm1
    movsd   [rsp+BB_PT], xmm0
    mov     edi, [rsp+BB_C]
    lea     rsi, [rsp+BB_UV]
    call    ce_uv
    movsd   xmm0, [rsp+BB_UV]
    movsd   xmm1, [rsp+BB_UV+8]
    cmp     dword ptr [rsp+BB_K], 0
    je      5f
    movsd   xmm2, [rsp+BB_PT]
    call    bs_add
5:  movsd   [rsp+BB_PU], xmm0
    movsd   [rsp+BB_PV], xmm1
    movsd   xmm0, [rsp+BB_PT]
    movsd   [rsp+BB_PRT], xmm0
    inc     dword ptr [rsp+BB_K]
    jmp     4b
.Lbs_cnext:
    inc     dword ptr [rsp+BB_C]
    jmp     .Lbs_ce
.Lbs_lnext:
    inc     dword ptr [rsp+BB_L]
    jmp     .Lbs_loop
.Lbs_out:
    mov     eax, [rsp+BB_LF]
    mov     ecx, [rip+bs_n]
    lea     rdx, [rip+lf_bs0]
    sub     ecx, [rdx+rax*4]
    lea     rdx, [rip+lf_bsn]
    mov     [rdx+rax*4], ecx
    add     rsp, 136
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
# bs_add(xmm0, xmm1 = this point's (u, v), xmm2 = its t; bo_bsegs' frame:
#   the previous point and its t, the edge) - a segment
bs_add:
    mov     eax, [rip+bs_n]
    cmp     eax, MAXBS
    jae     9f
    lea     r8, [rsp+8]                 # bo_bsegs' frame
    imul    rcx, rax, BS_SZ
    lea     rdx, [rip+bs_rec]
    add     rdx, rcx
    movsd   xmm3, [r8+BB_PU]
    movsd   [rdx+BS_U0], xmm3
    movsd   xmm3, [r8+BB_PV]
    movsd   [rdx+BS_V0], xmm3
    movsd   [rdx+BS_U1], xmm0
    movsd   [rdx+BS_V1], xmm1
    movsd   xmm3, [r8+BB_PRT]
    movsd   [rdx+BS_T0], xmm3
    movsd   [rdx+BS_T1], xmm2
    mov     ecx, [r8+BB_E]
    mov     [rdx+BS_E], ecx
    inc     dword ptr [rip+bs_n]
9:  ret

# uv_inside(edi=local face, xmm0=u, xmm1=v) -> eax = 1 inside its boundary
uv_inside:
    lea     rax, [rip+lf_bs0]
    mov     ecx, [rax+rdi*4]
    lea     rax, [rip+lf_bsn]
    mov     edx, [rax+rdi*4]
    add     edx, ecx
    xor     eax, eax
    lea     r8, [rip+bs_rec]
1:  cmp     ecx, edx
    jae     9f
    imul    r9, rcx, BS_SZ
    add     r9, r8
    movsd   xmm2, [r9+BS_V0]
    movsd   xmm3, [r9+BS_V1]
    xor     r10d, r10d
    xor     r11d, r11d
    comisd  xmm2, xmm1
    seta    r10b
    comisd  xmm3, xmm1
    seta    r11b
    cmp     r10d, r11d
    je      2f
    movsd   xmm4, xmm1                  # u at v
    subsd   xmm4, xmm2
    movsd   xmm5, [r9+BS_U1]
    subsd   xmm5, [r9+BS_U0]
    mulsd   xmm4, xmm5
    subsd   xmm3, xmm2
    divsd   xmm4, xmm3
    addsd   xmm4, [r9+BS_U0]
    comisd  xmm0, xmm4
    jae     2f
    xor     eax, 1
2:  inc     ecx
    jmp     1b
9:  ret

# bdist(edi=local face, xmm0=u, xmm1=v) -> xmm0 = the distance (in the
#   face's metric) to its boundary, eax = the edge of the nearest piece
bdist:
    lea     rax, [rip+lf_su]
    movsd   xmm6, [rax+rdi*8]
    lea     rax, [rip+lf_sv]
    movsd   xmm7, [rax+rdi*8]
    mulsd   xmm0, xmm6                  # scaled point
    mulsd   xmm1, xmm7
    lea     rax, [rip+lf_bs0]
    mov     ecx, [rax+rdi*4]
    lea     rax, [rip+lf_bsn]
    mov     edx, [rax+rdi*4]
    add     edx, ecx
    movsd   xmm8, [rip+bo_big]          # best squared
    mov     eax, -1                     # (its edge)
    lea     r8, [rip+bs_rec]
1:  cmp     ecx, edx
    jae     9f
    imul    r9, rcx, BS_SZ
    add     r9, r8
    movsd   xmm2, [r9+BS_U0]            # a, d = b - a (scaled)
    mulsd   xmm2, xmm6
    movsd   xmm3, [r9+BS_V0]
    mulsd   xmm3, xmm7
    movsd   xmm4, [r9+BS_U1]
    mulsd   xmm4, xmm6
    subsd   xmm4, xmm2
    movsd   xmm5, [r9+BS_V1]
    mulsd   xmm5, xmm7
    subsd   xmm5, xmm3
    movsd   xmm9, xmm0                  # w = p - a
    subsd   xmm9, xmm2
    movsd   xmm10, xmm1
    subsd   xmm10, xmm3
    movsd   xmm11, xmm9                 # t = clamp(w.d / d.d)
    mulsd   xmm11, xmm4
    movsd   xmm12, xmm10
    mulsd   xmm12, xmm5
    addsd   xmm11, xmm12
    movsd   xmm12, xmm4
    mulsd   xmm12, xmm4
    movsd   xmm13, xmm5
    mulsd   xmm13, xmm5
    addsd   xmm12, xmm13
    xorpd   xmm13, xmm13
    comisd  xmm12, [rip+bo_tiny]
    jbe     2f
    divsd   xmm11, xmm12
    maxsd   xmm11, xmm13
    minsd   xmm11, [rip+bo_one]
    movsd   xmm13, xmm11
2:  mulsd   xmm4, xmm13                 # |w - t d|^2
    mulsd   xmm5, xmm13
    subsd   xmm9, xmm4
    subsd   xmm10, xmm5
    mulsd   xmm9, xmm9
    mulsd   xmm10, xmm10
    addsd   xmm9, xmm10
    comisd  xmm9, xmm8
    jae     3f
    movsd   xmm8, xmm9
    mov     eax, [r9+BS_E]
3:  inc     ecx
    jmp     1b
9:  sqrtsd  xmm0, xmm8
    ret

# =============================================================================
#  Sections
# =============================================================================
# lf_of(edi=face) -> eax = its local index
lf_of:
    sub     rsp, 8
    call    p_fc
    mov     eax, [rax+FC_MARK]
    add     rsp, 8
    ret

# lf_surf(edi=local face) -> rax = its surface
lf_surf:
    sub     rsp, 8
    lea     rcx, [rip+lf_face]
    mov     edi, [rcx+rdi*4]
    call    p_fc
    mov     edi, [rax+FC_SURF]
    call    p_sf
    add     rsp, 8
    ret

# bo_section(edi=section) - its crossings with both faces' boundaries, the
#   pieces inside both made edges
.equ SE_REC,  0                         # the section record
.equ SE_PTS,  8                         # its first point
.equ SE_N,    16
.equ SE_LA,   20
.equ SE_LB,   24
.equ SE_SA,   32                        # surfaces
.equ SE_SB,   40
.equ SE_K,    48
.equ SE_KN,   52
.equ SE_SIDE, 56
.equ SE_I,    60
.equ SE_TMP,  64                        # scratch
.equ SE_M,    128                       # a midpoint record (7 doubles)
.equ SE_C,    192
bo_section:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 216
    imul    eax, edi, 48
    lea     rcx, [rip+ss_rec]
    add     rax, rcx
    mov     [rsp+SE_REC], rax
    mov     rbx, rax
    mov     eax, [rbx+12]               # SS_N
    mov     [rsp+SE_N], eax
    mov     eax, [rbx+8]                # SS_FIRST
    imul    rax, rax, 56
    add     rax, [rip+ss_pts]
    mov     [rsp+SE_PTS], rax
    mov     edi, [rbx]                  # SS_FA
    call    lf_of
    mov     [rsp+SE_LA], eax
    mov     edi, [rbx+4]
    call    lf_of
    mov     [rsp+SE_LB], eax
    mov     edi, [rsp+SE_LA]
    call    lf_surf
    mov     [rsp+SE_SA], rax
    mov     edi, [rsp+SE_LB]
    call    lf_surf
    mov     [rsp+SE_SB], rax
    mov     dword ptr [rip+cr_n], 0
    # segments k -> k+1 (closed: n - 1 -> 0 too) against both boundaries
    mov     eax, [rsp+SE_N]
    dec     eax
    cmp     dword ptr [rbx+16], 0       # SS_CLOSED
    je      1f
    inc     eax
1:  mov     [rsp+SE_KN], eax
    mov     dword ptr [rsp+SE_K], 0
.Lse_seg:
    mov     eax, [rsp+SE_K]
    cmp     eax, [rsp+SE_KN]
    jae     .Lse_sort
    mov     dword ptr [rsp+SE_SIDE], 0
.Lse_side:
    cmp     dword ptr [rsp+SE_SIDE], 2
    jae     .Lse_segn
    call    se_crossings
    inc     dword ptr [rsp+SE_SIDE]
    jmp     .Lse_side
.Lse_segn:
    inc     dword ptr [rsp+SE_K]
    jmp     .Lse_seg
.Lse_sort:
    call    cr_sort
    mov     ecx, [rip+cr_n]
    test    ecx, ecx
    jnz     .Lse_pieces
    cmp     dword ptr [rbx+16], 0       # no crossings: a closed loop inside
    je      .Lse_out                    #  both maybe, cut in two halves
    mov     eax, [rsp+SE_N]
    cmp     eax, 4
    jb      .Lse_out
    xor     edi, edi
    call    se_vertex_at
    lea     rcx, [rip+cr_v]
    mov     [rcx], eax
    lea     rcx, [rip+cr_pos]
    mov     qword ptr [rcx], 0
    mov     edi, [rsp+SE_N]
    shr     edi, 1
    mov     [rsp+SE_I], edi
    call    se_vertex_at
    lea     rcx, [rip+cr_v]
    mov     [rcx+4], eax
    cvtsi2sd xmm0, dword ptr [rsp+SE_I]
    lea     rcx, [rip+cr_pos]
    movsd   [rcx+8], xmm0
    mov     dword ptr [rip+cr_n], 2
.Lse_pieces:
    xor     r12d, r12d                  # piece c: crossing c to c + 1
.Lse_pc:
    mov     eax, [rip+cr_n]
    cmp     dword ptr [rbx+16], 0
    jne     2f
    dec     eax                         # (open: n - 1 pieces)
2:  cmp     r12d, eax
    jae     .Lse_out
    lea     eax, [r12+1]
    xor     edx, edx
    div     dword ptr [rip+cr_n]
    mov     r13d, edx                   # the next crossing
    lea     rcx, [rip+cr_pos]
    movsd   xmm0, [rcx+r12*8]
    movsd   xmm1, [rcx+r13*8]
    comisd  xmm1, xmm0                  # (wraps round a closed loop)
    ja      3f
    cvtsi2sd xmm2, dword ptr [rsp+SE_N]
    addsd   xmm1, xmm2
3:  movsd   [rsp+SE_TMP], xmm0
    movsd   [rsp+SE_TMP+8], xmm1
    movsd   xmm2, xmm1
    subsd   xmm2, xmm0
    comisd  xmm2, [rip+bo_angeps]       # (no length)
    jbe     .Lse_pcn
    lea     rcx, [rip+cr_v]
    mov     eax, [rcx+r12*4]
    cmp     eax, [rcx+r13*4]
    jne     4f
    comisd  xmm2, [rip+bo_one]          # the same vertex, close: nothing
    jb      .Lse_pcn
4:  addsd   xmm0, xmm1                  # its middle
    mulsd   xmm0, [rip+bo_half]
    lea     rdi, [rsp+SE_M]
    call    se_point_at
    # on a face's boundary: that face's edge goes into the other face (when
    # inside it); off both: a section piece when inside both
    mov     edi, [rsp+SE_LA]
    movsd   xmm0, [rsp+SE_M+24]
    movsd   xmm1, [rsp+SE_M+32]
    call    bdist
    mov     [rsp+SE_I], eax             # a's nearest edge, distance
    movsd   [rsp+SE_C], xmm0
    mov     edi, [rsp+SE_LB]
    movsd   xmm0, [rsp+SE_M+40]
    movsd   xmm1, [rsp+SE_M+48]
    call    bdist
    mov     [rsp+SE_C+12], eax          # b's
    movsd   [rsp+SE_TMP+16], xmm0
    movsd   xmm1, [rip+bo_on]
    comisd  xmm1, [rsp+SE_C]
    jae     .Lse_onA
    comisd  xmm1, [rsp+SE_TMP+16]
    jae     .Lse_onB
    mov     edi, [rsp+SE_LA]            # off both: inside both?
    movsd   xmm0, [rsp+SE_M+24]
    movsd   xmm1, [rsp+SE_M+32]
    call    uv_inside
    test    eax, eax
    jz      .Lse_pcn
    mov     edi, [rsp+SE_LB]
    movsd   xmm0, [rsp+SE_M+40]
    movsd   xmm1, [rsp+SE_M+48]
    call    uv_inside
    test    eax, eax
    jz      .Lse_pcn
    jmp     6f
.Lse_onB:                               # on b's boundary, off a's: b's
    mov     edi, [rsp+SE_LA]            #  edges along it into a, when it
    movsd   xmm0, [rsp+SE_M+24]         #  is inside a
    movsd   xmm1, [rsp+SE_M+32]
    call    uv_inside
    test    eax, eax
    jz      .Lse_pcn
    mov     edi, 1
    call    ins_along
    jmp     .Lse_pcn
.Lse_onA:
    comisd  xmm1, [rsp+SE_TMP+16]       # (on both: nothing)
    jae     .Lse_pcn
    mov     edi, [rsp+SE_LB]
    movsd   xmm0, [rsp+SE_M+40]
    movsd   xmm1, [rsp+SE_M+48]
    call    uv_inside
    test    eax, eax
    jz      .Lse_pcn
    xor     edi, edi
    call    ins_along
    jmp     .Lse_pcn
6:  lea     rcx, [rip+cr_v]
    mov     edi, [rcx+r12*4]
    mov     esi, [rcx+r13*4]
    movsd   xmm0, [rsp+SE_TMP]
    movsd   xmm1, [rsp+SE_TMP+8]
    call    se_edge
    test    eax, eax
    js      .Lse_pcn
    mov     ecx, [rip+spc_n]
    cmp     ecx, MAXSPC
    jae     .Lse_pcn
    lea     rdx, [rip+spc_e]
    mov     [rdx+rcx*4], eax
    mov     eax, [rsp+SE_LA]
    lea     rdx, [rip+spc_a]
    mov     [rdx+rcx*4], eax
    lea     rdx, [rip+lf_touch]
    mov     dword ptr [rdx+rax*4], 1
    mov     eax, [rsp+SE_LB]
    lea     rdx, [rip+spc_b]
    mov     [rdx+rcx*4], eax
    lea     rdx, [rip+lf_touch]
    mov     dword ptr [rdx+rax*4], 1
    inc     dword ptr [rip+spc_n]
.Lse_pcn:
    inc     r12d
    jmp     .Lse_pc
.Lse_out:
    add     rsp, 216
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# sp_at(ecx=index; r9=bo_section's frame) -> rax = the point record (wraps)
sp_at:
    mov     eax, ecx
    xor     edx, edx
    div     dword ptr [r9+SE_N]
    imul    rax, rdx, 56
    add     rax, [r9+SE_PTS]
    ret

# ins_along(edi=0: a's edges into b / 1: b's into a; bo_section's frame:
#   the piece from SE_TMP to SE_TMP+8) - every boundary edge the piece runs
#   along (nearest to 17 points of it) into the other face
ins_along:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 64
    lea     r13, [rsp+64+24+8]          # bo_section's frame
    mov     r12d, edi
    xor     ebx, ebx
1:  cmp     ebx, 16
    ja      9f
    cvtsi2sd xmm0, ebx                  # position: p0 + (p1 - p0) k / 16
    mov     eax, 16
    cvtsi2sd xmm1, eax
    divsd   xmm0, xmm1
    movsd   xmm1, [r13+SE_TMP+8]
    subsd   xmm1, [r13+SE_TMP]
    mulsd   xmm0, xmm1
    addsd   xmm0, [r13+SE_TMP]
    lea     rdi, [rsp]
    call    se_point_at_f               # (bo_section's frame as given)
    mov     edi, [r13+SE_LA]            # the nearest edge of that side
    movsd   xmm0, [rsp+24]
    movsd   xmm1, [rsp+32]
    test    r12d, r12d
    jz      2f
    mov     edi, [r13+SE_LB]
    movsd   xmm0, [rsp+40]
    movsd   xmm1, [rsp+48]
2:  call    bdist
    comisd  xmm0, [rip+bo_on]
    ja      3f
    mov     edi, eax
    mov     esi, [r13+SE_LB]
    test    r12d, r12d
    jz      21f
    mov     esi, [r13+SE_LA]
21: call    ins_add
3:  inc     ebx
    jmp     1b
9:  add     rsp, 64
    pop     r13
    pop     r12
    pop     rbx
    ret
# se_point_at_f(rdi=out, xmm0=position; r13=bo_section's frame) - as
#   se_point_at, from a deeper frame
se_point_at_f:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     r12, r13
    jmp     se_point_body

# ins_add(edi=edge (-1: none), esi=local face) - the edge into that face
#   (once)
ins_add:
    push    rdi
    push    rsi
    sub     rsp, 8
    call    bk_keep
    test    eax, eax
    jz      0f
    mov     edi, [rsp+16]
    mov     esi, [rsp+8]
    mov     edx, 7777
    call    bk_note
0:  add     rsp, 8
    pop     rsi
    pop     rdi
    test    edi, edi
    js      9f
    xor     eax, eax
1:  cmp     eax, [rip+ins_n]
    jae     2f
    lea     rcx, [rip+ins_e]
    cmp     [rcx+rax*4], edi
    jne     11f
    lea     rcx, [rip+ins_f]
    cmp     [rcx+rax*4], esi
    je      9f
11: inc     eax
    jmp     1b
2:  cmp     eax, 4096
    jae     9f
    lea     rcx, [rip+ins_e]
    mov     [rcx+rax*4], edi
    lea     rcx, [rip+ins_f]
    mov     [rcx+rax*4], esi
    inc     dword ptr [rip+ins_n]
    lea     rcx, [rip+lf_touch]
    mov     dword ptr [rcx+rsi*4], 1
9:  ret

# se_point_at(rdi=out record, xmm0=position k + f; bo_section's frame) - the
#   section interpolated there
se_point_at:
    push    rbx
    push    r12
    sub     rsp, 8
    lea     r12, [rsp+32]               # bo_section's frame
se_point_body:
    mov     rbx, rdi
    mov     r9, r12
    cvttsd2si ecx, xmm0
    cvtsi2sd xmm1, ecx
    subsd   xmm0, xmm1                  # f
    movsd   xmm2, [rip+bo_one]
    subsd   xmm2, xmm0
    push    rcx
    sub     rsp, 8
    call    sp_at
    add     rsp, 8
    pop     rcx
    mov     r10, rax
    inc     ecx
    mov     r9, r12
    call    sp_at
    xor     ecx, ecx                    # the point between (in 3D)
1:  movsd   xmm3, [r10+rcx*8]
    mulsd   xmm3, xmm2
    movsd   xmm4, [rax+rcx*8]
    mulsd   xmm4, xmm0
    addsd   xmm3, xmm4
    movsd   [rbx+rcx*8], xmm3
    inc     ecx
    cmp     ecx, 3
    jb      1b
    mov     edi, [r12+SE_LA]            # its (u, v) on each face
    call    box_mid
    mov     rdi, [r12+SE_SA]
    mov     rsi, rbx
    call    to_uv
    movsd   [rbx+24], xmm0
    movsd   [rbx+32], xmm1
    mov     edi, [r12+SE_LB]
    call    box_mid
    mov     rdi, [r12+SE_SB]
    mov     rsi, rbx
    call    to_uv
    movsd   [rbx+40], xmm0
    movsd   [rbx+48], xmm1
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# box_mid(edi=local face) -> xmm0, xmm1 = the middle of its (u, v) box
box_mid:
    sub     rsp, 8
    lea     rcx, [rip+lf_face]
    mov     edi, [rcx+rdi*4]
    call    p_fc
    movsd   xmm0, [rax+FC_U0]
    addsd   xmm0, [rax+FC_U1]
    mulsd   xmm0, [rip+bo_half]
    movsd   xmm1, [rax+FC_V0]
    addsd   xmm1, [rax+FC_V1]
    mulsd   xmm1, [rip+bo_half]
    add     rsp, 8
    ret

# se_vertex_at(edi=point index; bo_section's frame) -> eax = a new vertex
#   there
se_vertex_at:
    push    rbx
    lea     r9, [rsp+16]
    mov     ecx, edi
    call    sp_at
    mov     rdi, rax
    call    new_vertex
    pop     rbx
    ret

# se_crossings(bo_section's frame: segment SE_K, side SE_SIDE) - its crossings
#   with that face's boundary: exact vertices on the boundary edges
.equ SC_P,    0                         # p, q
.equ SC_Q,    16
.equ SC_LAM,  32
.equ SC_MU,   40
.equ SC_I,    48
.equ SC_N,    52
.equ SC_LF,   56
.equ SC_SO,   64                        # the other surface
.equ SC_T,    72
.equ SC_SF,   80                        # this side's surface
.equ SC_PT,   88                        # the crossing's point
.equ SC_OL,   96                        # the other local face
.equ SC_UV,   104                       # the point on it
se_crossings:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 120
    lea     rbp, [rsp+120+48+8]         # bo_section's frame
    mov     r9, rbp
    mov     ecx, [rbp+SE_K]
    call    sp_at
    mov     r12, rax
    mov     ecx, [rbp+SE_K]
    inc     ecx
    mov     r9, rbp
    call    sp_at
    mov     r13, rax
    mov     ecx, 24                     # the side's (u, v): a at +24, b +40
    mov     eax, [rbp+SE_LA]
    mov     rdx, [rbp+SE_SB]
    mov     r8, [rbp+SE_SA]
    cmp     dword ptr [rbp+SE_SIDE], 0
    je      1f
    mov     ecx, 40
    mov     eax, [rbp+SE_LB]
    mov     rdx, [rbp+SE_SA]
    mov     r8, [rbp+SE_SB]
1:  mov     [rsp+SC_SF], r8
    mov     [rsp+SC_LF], eax
    mov     [rsp+SC_SO], rdx
    movupd  xmm0, [r12+rcx]
    movupd  [rsp+SC_P], xmm0
    movupd  xmm0, [r13+rcx]
    movupd  [rsp+SC_Q], xmm0
    mov     edi, eax
    lea     rax, [rip+lf_bs0]
    mov     ecx, [rax+rdi*4]
    mov     [rsp+SC_I], ecx
    lea     rax, [rip+lf_bsn]
    add     ecx, [rax+rdi*4]
    mov     [rsp+SC_N], ecx
.Lsx_seg:
    mov     eax, [rsp+SC_I]
    cmp     eax, [rsp+SC_N]
    jae     .Lsx_out
    imul    rbx, rax, BS_SZ
    lea     rcx, [rip+bs_rec]
    add     rbx, rcx
    cmp     dword ptr [rbx+BS_E], -1    # (a pole's: nothing to cut)
    je      .Lsx_next
    mov     rax, [rsp+SC_SF]            # a jump of a turn on a periodic
    cmp     dword ptr [rax+SF_TYPE], ST_PLANE   #  surface is no crossing
    je      0f
    cmp     dword ptr [rax+SF_TYPE], ST_NURBS
    je      0f
    movsd   xmm0, [rsp+SC_Q]
    subsd   xmm0, [rsp+SC_P]
    andpd   xmm0, [rip+bo_absm]
    comisd  xmm0, [rip+bo_pi]
    ja      .Lsx_out
    movsd   xmm0, [rsp+SC_Q+8]
    subsd   xmm0, [rsp+SC_P+8]
    andpd   xmm0, [rip+bo_absm]
    comisd  xmm0, [rip+bo_pi]
    ja      .Lsx_out
0:
    # p + lam (q - p) = a + mu (b - a): d = q - p, e = b - a, w = a - p
    movsd   xmm0, [rsp+SC_Q]
    subsd   xmm0, [rsp+SC_P]            # dx
    movsd   xmm1, [rsp+SC_Q+8]
    subsd   xmm1, [rsp+SC_P+8]          # dy
    movsd   xmm2, [rbx+BS_U1]
    subsd   xmm2, [rbx+BS_U0]           # ex
    movsd   xmm3, [rbx+BS_V1]
    subsd   xmm3, [rbx+BS_V0]           # ey
    movsd   xmm4, xmm0                  # den = dx ey - dy ex
    mulsd   xmm4, xmm3
    movsd   xmm5, xmm1
    mulsd   xmm5, xmm2
    subsd   xmm4, xmm5
    movsd   xmm5, xmm4
    andpd   xmm5, [rip+bo_absm]
    comisd  xmm5, [rip+bo_tiny]
    jbe     .Lsx_next
    movsd   xmm6, [rbx+BS_U0]           # w
    subsd   xmm6, [rsp+SC_P]
    movsd   xmm7, [rbx+BS_V0]
    subsd   xmm7, [rsp+SC_P+8]
    movsd   xmm8, xmm6                  # lam = (wx ey - wy ex) / den
    mulsd   xmm8, xmm3
    movsd   xmm9, xmm7
    mulsd   xmm9, xmm2
    subsd   xmm8, xmm9
    divsd   xmm8, xmm4
    movsd   xmm9, xmm6                  # mu = (wx dy - wy dx) / den
    mulsd   xmm9, xmm1
    movsd   xmm10, xmm7
    mulsd   xmm10, xmm0
    subsd   xmm9, xmm10
    divsd   xmm9, xmm4
    xorpd   xmm10, xmm10                # lam in [0, 1), mu in [0, 1]
    comisd  xmm8, xmm10
    jb      .Lsx_next
    comisd  xmm8, [rip+bo_one]
    jae     .Lsx_next
    comisd  xmm9, xmm10
    jb      .Lsx_next
    comisd  xmm9, [rip+bo_one]
    ja      .Lsx_next
    movsd   [rsp+SC_LAM], xmm8
    movsd   [rsp+SC_MU], xmm9
    # the exact point on the edge: a root of the distance to the other
    # surface in the segment's t range
    mov     edi, [rbx+BS_E]
    movsd   xmm0, [rbx+BS_T0]
    movsd   xmm1, [rbx+BS_T1]
    mov     rsi, [rsp+SC_SO]
    movsd   xmm2, [rsp+SC_MU]
    call    edge_root                   # -> xmm0 = t, rax = the point
    cmp     dword ptr [rip+er_miss], 0
    jne     .Lsx_next
    movsd   [rsp+SC_T], xmm0
    mov     [rsp+SC_PT], rax
    mov     rdi, [rsp+SC_SO]            # in (or on) the other face? else no
    mov     rsi, rax                    #  piece can end here: no split
    mov     edi, [rbp+SE_LB]
    cmp     dword ptr [rbp+SE_SIDE], 0
    je      0f
    mov     edi, [rbp+SE_LA]
0:  mov     [rsp+SC_OL], edi
    call    box_mid
    mov     rdi, [rsp+SC_SO]
    mov     rsi, [rsp+SC_PT]
    call    to_uv
    movsd   [rsp+SC_UV], xmm0
    movsd   [rsp+SC_UV+8], xmm1
    mov     edi, [rsp+SC_OL]
    call    uv_inside
    test    eax, eax
    jnz     79f
    mov     edi, [rsp+SC_OL]
    movsd   xmm0, [rsp+SC_UV]
    movsd   xmm1, [rsp+SC_UV+8]
    call    bdist
    movsd   xmm1, [rip+bo_on]
    addsd   xmm1, xmm1
    comisd  xmm0, xmm1
    ja      .Lsx_next
79: movsd   xmm0, [rsp+SC_T]
    mov     edi, [rbx+BS_E]
    mov     rsi, [rsp+SC_PT]
    call    split_vertex
    mov     ecx, [rip+cr_n]
    cmp     ecx, MAXCR
    jae     .Lsx_next
    lea     rdx, [rip+cr_v]
    mov     [rdx+rcx*4], eax
    cvtsi2sd xmm0, dword ptr [rbp+SE_K]
    addsd   xmm0, [rsp+SC_LAM]
    lea     rdx, [rip+cr_pos]
    movsd   [rdx+rcx*8], xmm0
    inc     dword ptr [rip+cr_n]
.Lsx_next:
    inc     dword ptr [rsp+SC_I]
    jmp     .Lsx_seg
.Lsx_out:
    add     rsp, 120
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# cr_sort - the crossings by position (insertion sort), repeats of one
#   vertex at one place dropped
cr_sort:
    lea     r8, [rip+cr_pos]
    lea     r9, [rip+cr_v]
    mov     ecx, 1
1:  cmp     ecx, [rip+cr_n]
    jae     4f
    movsd   xmm0, [r8+rcx*8]
    mov     r10d, [r9+rcx*4]
    mov     edx, ecx
2:  test    edx, edx
    jz      3f
    comisd  xmm0, [r8+rdx*8-8]
    jae     3f
    movsd   xmm1, [r8+rdx*8-8]
    movsd   [r8+rdx*8], xmm1
    mov     eax, [r9+rdx*4-4]
    mov     [r9+rdx*4], eax
    dec     edx
    jmp     2b
3:  movsd   [r8+rdx*8], xmm0
    mov     [r9+rdx*4], r10d
    inc     ecx
    jmp     1b
4:  xor     ecx, ecx                    # drop a vertex met again right away
    xor     edx, edx                    # (write index)
5:  cmp     ecx, [rip+cr_n]
    jae     7f
    test    edx, edx
    jz      6f
    mov     eax, [r9+rcx*4]
    cmp     eax, [r9+rdx*4-4]
    jne     6f
    movsd   xmm0, [r8+rcx*8]
    subsd   xmm0, [r8+rdx*8-8]
    comisd  xmm0, [rip+bo_one]
    jb      61f
6:  movsd   xmm0, [r8+rcx*8]
    movsd   [r8+rdx*8], xmm0
    mov     eax, [r9+rcx*4]
    mov     [r9+rdx*4], eax
    inc     edx
61: inc     ecx
    jmp     5b
7:  mov     [rip+cr_n], edx
    ret

# edge_root(edi=edge, xmm0=t0, xmm1=t1, rsi=surface, xmm2=guess in 0..1) ->
#   xmm0 = t where the edge's curve meets the surface, rax = the point
#   (er_p) - a bracketed root of the signed distance (Illinois), or the
#   nearest found
.equ ER_A,    0
.equ ER_B,    8
.equ ER_FA,   16
.equ ER_FB,   24
.equ ER_T,    32
.equ ER_F,    40
.equ ER_EV,   48                        # crv_eval out
.equ ER_HU,   120
.equ ER_HV,   128
.equ ER_SIDE, 136
edge_root:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 152
    mov     r13, rsi
    movsd   [rsp+ER_A], xmm0
    movsd   [rsp+ER_B], xmm1
    movsd   xmm3, xmm1                  # the guess
    subsd   xmm3, xmm0
    mulsd   xmm3, xmm2
    addsd   xmm3, xmm0
    movsd   [rsp+ER_T], xmm3
    call    p_ed
    mov     edi, [rax+ED_CURVE]
    call    p_cv
    mov     r12, rax
    mov     dword ptr [rip+er_miss], 0
    xorpd   xmm0, xmm0                  # hints
    movsd   [rsp+ER_HU], xmm0
    movsd   [rsp+ER_HV], xmm0
    movsd   xmm0, [rsp+ER_T]            # hint from the guess point
    call    er_f
    movsd   xmm0, [rsp+ER_A]
    call    er_f
    movsd   [rsp+ER_FA], xmm0
    movsd   xmm0, [rsp+ER_B]
    call    er_f
    movsd   [rsp+ER_FB], xmm0
    mulsd   xmm0, [rsp+ER_FA]
    xorpd   xmm1, xmm1
    comisd  xmm0, xmm1
    ja      .Ler_nobracket
    mov     dword ptr [rsp+ER_SIDE], 0
    xor     ebx, ebx
.Ler_it:
    cmp     ebx, 100
    jae     .Ler_done
    movsd   xmm0, [rsp+ER_FA]           # false position
    movsd   xmm1, [rsp+ER_FB]
    subsd   xmm1, xmm0
    movsd   xmm2, xmm1
    andpd   xmm2, [rip+bo_absm]
    comisd  xmm2, [rip+bo_tiny]
    jbe     .Ler_done
    movsd   xmm2, [rsp+ER_B]
    subsd   xmm2, [rsp+ER_A]
    mulsd   xmm2, xmm0
    divsd   xmm2, xmm1
    movsd   xmm3, [rsp+ER_A]
    subsd   xmm3, xmm2
    movsd   [rsp+ER_T], xmm3
    movsd   xmm0, xmm3
    call    er_f
    movsd   [rsp+ER_F], xmm0
    andpd   xmm0, [rip+bo_absm]
    movsd   xmm1, [rip+bo_size]
    mulsd   xmm1, [rip+bo_tiny]
    comisd  xmm0, xmm1
    jbe     .Ler_done
    movsd   xmm0, [rsp+ER_F]            # keep the bracket
    mulsd   xmm0, [rsp+ER_FA]
    xorpd   xmm1, xmm1
    comisd  xmm0, xmm1
    jbe     1f
    movsd   xmm0, [rsp+ER_T]            # f same sign as fa: a = t
    movsd   [rsp+ER_A], xmm0
    movsd   xmm0, [rsp+ER_F]
    movsd   [rsp+ER_FA], xmm0
    cmp     dword ptr [rsp+ER_SIDE], -1
    jne     2f
    movsd   xmm0, [rsp+ER_FB]           # (Illinois: halve the stuck end)
    mulsd   xmm0, [rip+bo_half]
    movsd   [rsp+ER_FB], xmm0
2:  mov     dword ptr [rsp+ER_SIDE], -1
    jmp     3f
1:  movsd   xmm0, [rsp+ER_T]
    movsd   [rsp+ER_B], xmm0
    movsd   xmm0, [rsp+ER_F]
    movsd   [rsp+ER_FB], xmm0
    cmp     dword ptr [rsp+ER_SIDE], 1
    jne     4f
    movsd   xmm0, [rsp+ER_FA]
    mulsd   xmm0, [rip+bo_half]
    movsd   [rsp+ER_FA], xmm0
4:  mov     dword ptr [rsp+ER_SIDE], 1
3:  movsd   xmm0, [rsp+ER_B]            # bracket tiny: done
    subsd   xmm0, [rsp+ER_A]
    andpd   xmm0, [rip+bo_absm]
    comisd  xmm0, [rip+bo_tiny]
    jbe     .Ler_done
    inc     ebx
    jmp     .Ler_it
.Ler_nobracket:
    # no sign change: at most a touch (a double root, found only to the
    # square root of the noise): no crossing here - the transversal side
    # makes that vertex exactly, and it splits this edge (snap_vertices)
    mov     dword ptr [rip+er_miss], 1
    movsd   xmm0, [rsp+ER_A]
    movsd   [rsp+ER_T], xmm0
    jmp     .Ler_done
    mov     dword ptr [rip+er_miss], 0
    xor     ebx, ebx
5:  cmp     ebx, 80
    jae     6f
    movsd   xmm0, [rsp+ER_B]            # c = b - g (b - a), d = a + g (b - a)
    subsd   xmm0, [rsp+ER_A]
    mulsd   xmm0, [rip+bo_gold]
    movsd   xmm1, [rsp+ER_B]
    subsd   xmm1, xmm0
    movsd   [rsp+ER_T], xmm1
    movsd   xmm2, [rsp+ER_A]
    addsd   xmm2, xmm0
    movsd   [rsp+ER_F], xmm2
    movsd   xmm0, [rsp+ER_T]
    call    er_f
    andpd   xmm0, [rip+bo_absm]
    movsd   [rsp+ER_FA+0], xmm0         # (|f(c)| kept in ER_FA)
    movsd   xmm0, [rsp+ER_F]
    call    er_f
    andpd   xmm0, [rip+bo_absm]
    comisd  xmm0, [rsp+ER_FA]
    jb      51f
    movsd   xmm0, [rsp+ER_F]            # f(c) smaller: b = d
    movsd   [rsp+ER_B], xmm0
    jmp     52f
51: movsd   xmm0, [rsp+ER_T]            # f(d) smaller: a = c
    movsd   [rsp+ER_A], xmm0
52: inc     ebx
    jmp     5b
6:  movsd   xmm0, [rsp+ER_A]
    addsd   xmm0, [rsp+ER_B]
    mulsd   xmm0, [rip+bo_half]
    movsd   [rsp+ER_T], xmm0
    call    er_f
    andpd   xmm0, [rip+bo_absm]
    comisd  xmm0, [rip+bo_on]
    jbe     .Ler_done
    mov     dword ptr [rip+er_miss], 1
.Ler_done:
    movsd   xmm0, [rsp+ER_T]            # the point at t
    mov     rdi, r12
    lea     rsi, [rip+er_p]
    call    crv_eval
    movsd   xmm0, [rsp+ER_T]
    lea     rax, [rip+er_p]
    add     rsp, 152
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
# er_f(xmm0=t; edge_root's frame) -> xmm0 = signed distance of the curve
#   point to the surface (hints carried)
er_f:
    push    rbx
    lea     rbx, [rsp+16]
    mov     rdi, r12
    lea     rsi, [rbx+ER_EV]
    call    crv_eval
    mov     rdi, r13
    lea     rsi, [rbx+ER_EV]
    movsd   xmm0, [rbx+ER_HU]
    movsd   xmm1, [rbx+ER_HV]
    call    sf_dist
    movsd   [rbx+ER_HU], xmm1
    movsd   [rbx+ER_HV], xmm2
    pop     rbx
    ret

.section .bss
.align 8
er_p:           .skip 72
er_miss:        .skip 4                 # edge_root found no crossing
.text

# new_vertex(rdi=point) -> eax = a vertex there: one made by this boolean
#   within the weld distance, or a new one
new_vertex:
    push    rbx
    push    r12
    push    r13
    mov     r12, rdi
    xor     ebx, ebx                    # the solids' own vertices first
55: cmp     ebx, [rip+ov_n]
    jae     57f
    lea     rax, [rip+ov_v]
    mov     edi, [rax+rbx*4]
    call    p_vx
    mov     rdi, rax
    mov     rsi, r12
    call    v3dist
    comisd  xmm0, [rip+bo_weld]
    ja      56f
    lea     rax, [rip+ov_v]
    mov     eax, [rax+rbx*4]
    jmp     9f
56: inc     ebx
    jmp     55b
57: xor     ebx, ebx
1:  cmp     ebx, [rip+nv_n]
    jae     2f
    lea     rax, [rip+nv_v]
    mov     edi, [rax+rbx*4]
    call    p_vx
    mov     rdi, rax
    mov     rsi, r12
    call    v3dist
    comisd  xmm0, [rip+bo_weld]
    ja      11f
    lea     rax, [rip+nv_v]
    mov     eax, [rax+rbx*4]
    jmp     9f
11: inc     ebx
    jmp     1b
2:  mov     rdi, r12
    call    n_vx
    mov     ecx, [rip+nv_n]
    cmp     ecx, MAXNV
    jae     9f
    lea     rdx, [rip+nv_v]
    mov     [rdx+rcx*4], eax
    inc     dword ptr [rip+nv_n]
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# split_vertex(edi=edge, rsi=point, xmm0=t) -> eax = the vertex there: the
#   edge's own end, a split it already has, or a new split
split_vertex:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 24
    mov     ebx, edi
    mov     r12, rsi
    movsd   [rsp], xmm0
    call    p_ed
    mov     r13, rax
    mov     edi, [r13+ED_V0]            # its ends
    call    p_vx
    mov     rdi, rax
    mov     rsi, r12
    call    v3dist
    comisd  xmm0, [rip+bo_weld]
    ja      1f
    mov     eax, [r13+ED_V0]
    jmp     9f
1:  mov     edi, [r13+ED_V1]
    call    p_vx
    mov     rdi, rax
    mov     rsi, r12
    call    v3dist
    comisd  xmm0, [rip+bo_weld]
    ja      2f
    mov     eax, [r13+ED_V1]
    jmp     9f
2:  mov     r14d, [r13+ED_AUX]          # its splits
3:  test    r14d, r14d
    js      4f
    lea     rax, [rip+spl_v]
    mov     edi, [rax+r14*4]
    call    p_vx
    mov     rdi, rax
    mov     rsi, r12
    call    v3dist
    comisd  xmm0, [rip+bo_weld]
    ja      31f
    lea     rax, [rip+spl_v]
    mov     eax, [rax+r14*4]
    jmp     9f
31: lea     rax, [rip+spl_next]
    mov     r14d, [rax+r14*4]
    jmp     3b
4:  mov     rdi, r12                    # a new split
    call    new_vertex
    mov     ecx, [rip+spl_n]
    cmp     ecx, MAXSPL
    jae     8f
    lea     rdx, [rip+spl_v]
    mov     [rdx+rcx*4], eax
    movsd   xmm0, [rsp]
    lea     rdx, [rip+spl_t]
    movsd   [rdx+rcx*8], xmm0
    mov     edx, [r13+ED_AUX]
    lea     r8, [rip+spl_next]
    mov     [r8+rcx*4], edx
    mov     [r13+ED_AUX], ecx
    inc     dword ptr [rip+spl_n]
    jmp     9f
8:  mov     dword ptr [rip+bo_fail], 1
9:  add     rsp, 24
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# se_edge(edi=start vertex, esi=end vertex, xmm0, xmm1 = their positions
#   along the section; bo_section's frame) -> eax = a new edge: the exact
#   curve's arc between them, or a polyline through the section's points
.equ SG_V0,   0
.equ SG_V1,   4
.equ SG_P0,   8
.equ SG_P1,   16
.equ SG_T0,   24
.equ SG_T1,   32
.equ SG_D,    40
.equ SG_K,    64
.equ SG_N,    68
.equ SG_LEN,  72
se_edge:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 88
    lea     rbp, [rsp+88+48+8]          # bo_section's frame
    mov     [rsp+SG_V0], edi
    mov     [rsp+SG_V1], esi
    movsd   [rsp+SG_P0], xmm0
    movsd   [rsp+SG_P1], xmm1
    mov     rbx, [rbp+SE_REC]
    mov     eax, [rbx+20]               # SS_CURVE
    test    eax, eax
    js      .Lsg_poly
    mov     r12d, eax
    mov     edi, eax
    call    p_cv
    mov     r13, rax
    mov     edi, [rsp+SG_V0]
    call    cv_param
    movsd   [rsp+SG_T0], xmm0
    mov     edi, [rsp+SG_V1]
    call    cv_param
    movsd   [rsp+SG_T1], xmm0
    cmp     dword ptr [r13+CV_TYPE], CT_CIRCLE
    jne     2f
    movsd   xmm0, [rsp+SG_T1]           # a circle: forwards, t1 > t0
    comisd  xmm0, [rsp+SG_T0]
    ja      2f
    addsd   xmm0, [rip+bo_2pi]
    movsd   [rsp+SG_T1], xmm0
2:  mov     edi, r12d
    mov     esi, [rsp+SG_V0]
    mov     edx, [rsp+SG_V1]
    movsd   xmm0, [rsp+SG_T0]
    movsd   xmm1, [rsp+SG_T1]
    call    n_ed
    jmp     .Lsg_out
.Lsg_poly:
    # points: the start vertex, section points strictly between, the end
    movsd   xmm0, [rsp+SG_P0]
    cvttsd2si eax, xmm0
    inc     eax
    mov     [rsp+SG_K], eax             # first inner index
    movsd   xmm0, [rsp+SG_P1]
    cvttsd2si ecx, xmm0
    cvtsi2sd xmm1, ecx
    ucomisd xmm1, xmm0
    jne     1f
    dec     ecx                         # (exactly on a point: not inner)
1:  sub     ecx, eax
    inc     ecx
    jns     11f
    xor     ecx, ecx
11: add     ecx, 2
    mov     [rsp+SG_N], ecx             # points
    mov     edi, 1
    mov     esi, ecx
    call    nb_new_poly
    test    rax, rax
    jz      .Lsg_fail
    mov     r14, rax
    mov     r15, [r14+CV_CP]
    mov     edi, [rsp+SG_V0]
    call    p_vx
    mov     rsi, rax
    mov     rdi, r15
    call    put_pt
    xor     ebx, ebx
2:  mov     eax, [rsp+SG_N]
    sub     eax, 2
    cmp     ebx, eax
    jae     3f
    mov     ecx, [rsp+SG_K]
    add     ecx, ebx
    mov     r9, rbp
    call    sp_at
    mov     rsi, rax
    lea     rdi, [r15+32]
    mov     eax, ebx
    shl     eax, 5
    add     rdi, rax
    call    put_pt
    inc     ebx
    jmp     2b
3:  mov     edi, [rsp+SG_V1]
    call    p_vx
    mov     rsi, rax
    mov     eax, [rsp+SG_N]
    dec     eax
    shl     eax, 5
    lea     rdi, [r15+rax]
    call    put_pt
    # knots: chord lengths
    mov     rdi, [r14+CV_KN]
    xorpd   xmm0, xmm0
    movsd   [rdi], xmm0
    movsd   [rdi+8], xmm0
    xor     ebx, ebx
4:  lea     eax, [rbx+1]
    cmp     eax, [rsp+SG_N]
    jae     5f
    mov     eax, ebx
    shl     eax, 5
    lea     rdi, [r15+rax]
    lea     rsi, [r15+rax+32]
    call    v3dist
    mov     rdi, [r14+CV_KN]
    addsd   xmm0, [rdi+rbx*8+8]
    movsd   [rdi+rbx*8+16], xmm0
    inc     ebx
    jmp     4b
5:  mov     eax, [rsp+SG_N]
    mov     rdi, [r14+CV_KN]
    movsd   xmm0, [rdi+rax*8]
    movsd   [rdi+rax*8+8], xmm0
    movsd   [rsp+SG_LEN], xmm0
    mov     rdi, r14
    call    i_cv
    mov     edi, eax
    mov     esi, [rsp+SG_V0]
    mov     edx, [rsp+SG_V1]
    xorpd   xmm0, xmm0
    movsd   xmm1, [rsp+SG_LEN]
    call    n_ed
    jmp     .Lsg_out
.Lsg_fail:
    mov     eax, -1
.Lsg_out:
    add     rsp, 88
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
# put_pt(rdi=homogeneous slot, rsi=point) - (x, y, z, 1)
put_pt:
    movupd  xmm0, [rsi]
    movupd  [rdi], xmm0
    mov     rax, [rsi+16]
    mov     [rdi+16], rax
    mov     rax, [rip+bo_one]
    mov     [rdi+24], rax
    ret
# cv_param(edi=vertex; r13=line or circle) -> xmm0 = its parameter
cv_param:
    push    rbx
    sub     rsp, 32
    call    p_vx
    lea     rdi, [rsp]
    mov     rsi, rax
    lea     rdx, [r13+CV_O]
    call    v3sub
    lea     rdi, [rsp]
    lea     rsi, [r13+CV_X]
    call    v3dot
    cmp     dword ptr [r13+CV_TYPE], CT_LINE
    je      9f
    movsd   [rsp+24], xmm0
    lea     rdi, [rsp]
    lea     rsi, [r13+CV_Y]
    call    v3dot
    movsd   xmm1, [rsp+24]
    call    datan2
9:  add     rsp, 32
    pop     rbx
    ret
# nb_new_poly(edi=1, esi=points) -> rax = a degree 1 NURBS (3D)
nb_new_poly:
    push    rbx
    push    r12
    push    r13
    mov     r12d, edi
    mov     r13d, esi
    call    kc_new
    test    rax, rax
    jz      9f
    mov     rbx, rax
    mov     dword ptr [rbx+CV_TYPE], CT_NURBS
    mov     dword ptr [rbx+CV_DIM], 3
    mov     [rbx+CV_DEG], r12d
    mov     [rbx+CV_N], r13d
    lea     edi, [r12+r13+1]
    shl     edi, 3
    call    bk_data
    mov     [rbx+CV_KN], rax
    mov     edi, r13d
    shl     edi, 5
    call    bk_data
    mov     [rbx+CV_CP], rax
    mov     rax, rbx
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# snap_vertices - every vertex this boolean made that lies on an edge of
#   either solid (inside it, not at its ends) splits that edge (sections
#   meeting an edge tangentially, or along a face that lies on a plane of the
#   other solid, find no crossing of their own there)
snap_vertices:
    push    rbx
    push    r12
    sub     rsp, 8
    xor     ebx, ebx                    # new vertices, then the solids' own
1:  mov     eax, [rip+nv_n]
    add     eax, [rip+ov_n]
    cmp     ebx, eax
    jae     9f
    mov     eax, ebx
    lea     rcx, [rip+nv_v]
    cmp     ebx, [rip+nv_n]
    jb      11f
    sub     eax, [rip+nv_n]
    lea     rcx, [rip+ov_v]
11: mov     edi, [rcx+rax*4]
    mov     [rip+sn_vx], edi
    call    p_vx
    movupd  xmm0, [rax]
    movupd  [rip+sn_p], xmm0
    mov     rcx, [rax+16]
    mov     [rip+sn_p+16], rcx
    xor     r12d, r12d
2:  cmp     r12d, [rip+lf_n]
    jae     3f
    lea     rcx, [rip+lf_face]
    mov     edi, [rcx+r12*4]
    lea     rsi, [rip+snap_one]
    call    each_coedge
    inc     r12d
    jmp     2b
3:  inc     ebx
    jmp     1b
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

.section .bss
.align 8
sn_p:           .skip 24
sn_vx:          .skip 4
.text

# snap_one(rax=coedge) - split its edge at sn_p if the point lies on it
snap_one:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     ebx, [rax+CE_EDGE]
    mov     edi, ebx
    call    p_ed
    mov     r12, rax
    test    dword ptr [r12+ED_FLAGS], EF_DEGEN
    jnz     9f
    mov     eax, [rip+sn_vx]            # (its own end)
    cmp     eax, [r12+ED_V0]
    je      9f
    cmp     eax, [r12+ED_V1]
    je      9f
    cmp     qword ptr [r12+ED_POLY], 0
    je      9f
    mov     edi, ebx
    call    ed_nearest_t                # -> xmm0 = t, xmm1 = distance
    comisd  xmm1, [rip+bo_on]
    ja      9f
    movsd   xmm1, [r12+ED_T0]           # strictly inside (t0, t1)
    movsd   xmm2, [r12+ED_T1]
    movsd   xmm3, xmm1
    minsd   xmm3, xmm2
    maxsd   xmm1, xmm2
    comisd  xmm0, xmm3
    jbe     9f
    comisd  xmm0, xmm1
    jae     9f
    mov     edi, ebx
    lea     rsi, [rip+sn_p]
    call    split_vertex
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# ed_nearest_t(edi=edge; sn_p) -> xmm0 = the parameter of its curve nearest
#   sn_p, xmm1 = the distance (the polyline's nearest piece, then Newton on
#   the curve)
.equ NT_BEST, 0
.equ NT_T,    8
.equ NT_EV,   16                        # crv_eval out (72 bytes)
.equ NT_I,    88
.equ NT_W,    96                        # C - P
.equ NT_G,    120
ed_nearest_t:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 128
    call    p_ed
    mov     rbx, rax
    mov     edi, [rbx+ED_CURVE]
    call    p_cv
    mov     r13, rax
    movsd   xmm0, [rip+bo_big]
    movsd   [rsp+NT_BEST], xmm0
    movsd   xmm0, [rbx+ED_T0]
    movsd   [rsp+NT_T], xmm0
    mov     r12, [rbx+ED_POLY]
    xor     ecx, ecx
1:  lea     eax, [rcx+1]
    cmp     eax, [rbx+ED_NPOLY]
    jae     3f
    mov     [rsp+NT_I], ecx
    shl     ecx, 5
    lea     rdi, [r12+rcx]              # piece a -> b: the nearest point on it
    lea     rsi, [r12+rcx+32]
    call    seg_near                    # -> xmm0 = fraction, xmm1 = distance
    comisd  xmm1, [rsp+NT_BEST]
    jae     2f
    movsd   [rsp+NT_BEST], xmm1
    mov     ecx, [rsp+NT_I]
    shl     ecx, 5
    movsd   xmm2, [r12+rcx+56]          # t = ta + f (tb - ta)
    subsd   xmm2, [r12+rcx+24]
    mulsd   xmm2, xmm0
    addsd   xmm2, [r12+rcx+24]
    movsd   [rsp+NT_T], xmm2
2:  mov     ecx, [rsp+NT_I]
    inc     ecx
    jmp     1b
3:  xor     r12d, r12d                  # Newton: (C(t) - P) . C'(t) = 0
4:  cmp     r12d, 8
    jae     5f
    mov     rdi, r13
    movsd   xmm0, [rsp+NT_T]
    lea     rsi, [rsp+NT_EV]
    call    crv_eval
    lea     rdi, [rsp+NT_W]
    lea     rsi, [rsp+NT_EV]
    lea     rdx, [rip+sn_p]
    call    v3sub
    lea     rdi, [rsp+NT_W]
    lea     rsi, [rsp+NT_EV+24]
    call    v3dot
    movsd   [rsp+NT_G], xmm0
    lea     rdi, [rsp+NT_EV+24]
    lea     rsi, [rsp+NT_EV+24]
    call    v3dot
    comisd  xmm0, [rip+bo_tiny]
    jbe     5f
    movsd   xmm1, [rsp+NT_G]
    divsd   xmm1, xmm0
    movsd   xmm2, [rsp+NT_T]
    subsd   xmm2, xmm1
    movsd   [rsp+NT_T], xmm2
    inc     r12d
    jmp     4b
5:  mov     rdi, r13
    movsd   xmm0, [rsp+NT_T]
    lea     rsi, [rsp+NT_EV]
    call    crv_eval
    lea     rdi, [rsp+NT_EV]
    lea     rsi, [rip+sn_p]
    call    v3dist
    movsd   xmm1, xmm0
    movsd   xmm0, [rsp+NT_T]
    add     rsp, 128
    pop     r13
    pop     r12
    pop     rbx
    ret

# seg_near(rdi=a, rsi=b; sn_p) -> xmm0 = the fraction along a -> b of the
#   point nearest sn_p, xmm1 = the distance to it
seg_near:
    xorpd   xmm4, xmm4                  # d.d, w.d
    xorpd   xmm5, xmm5
    xor     ecx, ecx
1:  movsd   xmm0, [rsi+rcx*8]
    subsd   xmm0, [rdi+rcx*8]
    lea     rax, [rip+sn_p]
    movsd   xmm1, [rax+rcx*8]
    subsd   xmm1, [rdi+rcx*8]
    mulsd   xmm1, xmm0
    addsd   xmm5, xmm1
    mulsd   xmm0, xmm0
    addsd   xmm4, xmm0
    inc     ecx
    cmp     ecx, 3
    jb      1b
    xorpd   xmm0, xmm0
    comisd  xmm4, [rip+bo_tiny]
    jbe     2f
    movsd   xmm0, xmm5
    divsd   xmm0, xmm4
    xorpd   xmm1, xmm1
    maxsd   xmm0, xmm1
    minsd   xmm0, [rip+bo_one]
2:  xorpd   xmm6, xmm6                  # |a + f d - p|
    xor     ecx, ecx
3:  movsd   xmm1, [rsi+rcx*8]
    subsd   xmm1, [rdi+rcx*8]
    mulsd   xmm1, xmm0
    addsd   xmm1, [rdi+rcx*8]
    lea     rax, [rip+sn_p]
    subsd   xmm1, [rax+rcx*8]
    mulsd   xmm1, xmm1
    addsd   xmm6, xmm1
    inc     ecx
    cmp     ecx, 3
    jb      3b
    sqrtsd  xmm1, xmm6
    ret

# =============================================================================
#  Edge pieces
# =============================================================================
# bo_pieces - every edge of both solids cut at its splits (sorted along it)
bo_pieces:
    push    rbx
    sub     rsp, 16
    xor     ebx, ebx
1:  cmp     ebx, [rip+lf_n]
    jae     9f
    lea     rcx, [rip+lf_face]
    mov     edi, [rcx+rbx*4]
    lea     rsi, [rip+edge_cut]
    call    each_coedge
    inc     ebx
    jmp     1b
9:  add     rsp, 16
    pop     rbx
    ret

# edge_cut(rax=coedge record) - its edge's pieces (once per edge)
.equ EC_E,    0
.equ EC_N,    4
.equ EC_I,    8
.equ EC_V,    12                        # the last vertex
.equ EC_T,    16                        # its t
.equ EC_DIR,  24
.equ EC_TS,   32                        # sorted splits: up to 1024 (t, v)
edge_cut:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 32+1024*16
    mov     ebx, [rax+CE_EDGE]
    mov     [rsp+EC_E], ebx
    mov     rcx, [rip+ep_first]
    cmp     ebx, [rip+ep_cap]
    jae     .Lec_fail
    cmp     dword ptr [rcx+rbx*4], -1
    jne     .Lec_out                    # (done already)
    mov     edi, ebx
    call    p_ed
    mov     r12, rax
    mov     eax, [rip+ep_n]             # its pieces start here
    mov     rcx, [rip+ep_first]
    mov     [rcx+rbx*4], eax
    # its splits, sorted along the edge (t0 -> t1)
    xor     r13d, r13d
    mov     r14d, [r12+ED_AUX]
1:  test    r14d, r14d
    js      2f
    cmp     r13d, 1024
    jae     2f
    lea     rax, [rip+spl_t]
    movsd   xmm0, [rax+r14*8]
    lea     rax, [rip+spl_v]
    mov     ecx, [rax+r14*4]
    mov     edx, r13d
    shl     edx, 4
    movsd   [rsp+EC_TS+rdx], xmm0
    mov     [rsp+EC_TS+rdx+8], ecx
    inc     r13d
    lea     rax, [rip+spl_next]
    mov     r14d, [rax+r14*4]
    jmp     1b
2:  mov     [rsp+EC_N], r13d
    test    r13d, r13d
    jnz     3f
    mov     eax, [rip+ep_n]             # no splits: the edge itself
    lea     rcx, [rip+ep_list]
    mov     [rcx+rax*4], ebx
    inc     dword ptr [rip+ep_n]
    mov     rcx, [rip+ep_cnt]
    mov     dword ptr [rcx+rbx*4], 1
    jmp     .Lec_out
3:  # sort by distance along the edge: by (t - t0) (t1 - t0)
    movsd   xmm7, [r12+ED_T1]
    subsd   xmm7, [r12+ED_T0]
    mov     ecx, 1
4:  cmp     ecx, r13d
    jae     6f
    mov     eax, ecx
    shl     eax, 4
    movsd   xmm0, [rsp+EC_TS+rax]
    mov     r8d, [rsp+EC_TS+rax+8]
    mov     edx, ecx
5:  test    edx, edx
    jz      51f
    mov     eax, edx
    shl     eax, 4
    movsd   xmm1, [rsp+EC_TS+rax-16]
    movsd   xmm2, xmm0                  # (t - prev) along the direction
    subsd   xmm2, xmm1
    mulsd   xmm2, xmm7
    xorpd   xmm3, xmm3
    comisd  xmm2, xmm3
    jae     51f
    movsd   [rsp+EC_TS+rax], xmm1
    mov     r9d, [rsp+EC_TS+rax-8]
    mov     [rsp+EC_TS+rax+8], r9d
    dec     edx
    jmp     5b
51: mov     eax, edx
    shl     eax, 4
    movsd   [rsp+EC_TS+rax], xmm0
    mov     [rsp+EC_TS+rax+8], r8d
    inc     ecx
    jmp     4b
6:  # pieces: v0 (t0) -> split 1 -> ... -> v1 (t1)
    mov     eax, [r12+ED_V0]
    mov     [rsp+EC_V], eax
    movsd   xmm0, [r12+ED_T0]
    movsd   [rsp+EC_T], xmm0
    xor     r14d, r14d
7:  cmp     r14d, r13d
    ja      8f
    cmp     r14d, r13d
    jb      71f
    mov     r15d, [r12+ED_V1]           # the last piece ends at v1
    movsd   xmm1, [r12+ED_T1]
    jmp     72f
71: mov     eax, r14d
    shl     eax, 4
    mov     r15d, [rsp+EC_TS+rax+8]
    movsd   xmm1, [rsp+EC_TS+rax]
72: cmp     r15d, [rsp+EC_V]            # (no length: skipped)
    je      74f
    movsd   [rsp+EC_DIR], xmm1
    mov     edi, [r12+ED_CURVE]
    mov     esi, [rsp+EC_V]
    mov     edx, r15d
    movsd   xmm0, [rsp+EC_T]
    call    n_ed
    mov     ecx, [rip+ep_n]
    cmp     ecx, MAXEPL
    jae     .Lec_fail
    lea     rdx, [rip+ep_list]
    mov     [rdx+rcx*4], eax
    inc     dword ptr [rip+ep_n]
    mov     rcx, [rip+ep_cnt]
    mov     edx, [rsp+EC_E]
    inc     dword ptr [rcx+rdx*4]
    mov     [rsp+EC_V], r15d
    movsd   xmm0, [rsp+EC_DIR]
    movsd   [rsp+EC_T], xmm0
74: inc     r14d
    jmp     7b
8:  mov     edi, ebx                    # (the original edge's own reuse)
    call    p_ed
    jmp     .Lec_out
.Lec_fail:
    mov     dword ptr [rip+bo_fail], 1
.Lec_out:
    add     rsp, 32+1024*16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Dividing a face
# =============================================================================
# he_add(edi=edge, esi=rev) - a half-edge of the face being divided: its
#   points in the face's scaled, oriented (u, v)
.equ HA_E,    0
.equ HA_REV,  4
.equ HA_K,    8
.equ HA_KN,   12
.equ HA_HU,   16
.equ HA_HV,   24
.equ HA_H,    32
he_add:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 48
    mov     [rsp+HA_E], edi
    mov     [rsp+HA_REV], esi
    xor     ecx, ecx                    # (already there: once is enough)
0:  cmp     ecx, [rip+he_n]
    jae     71f
    imul    rax, rcx, HE_SZ
    lea     rdx, [rip+he_rec]
    cmp     [rdx+rax+HE_E], edi
    jne     72f
    cmp     [rdx+rax+HE_REV], esi
    je      .Lha_out
72: inc     ecx
    jmp     0b
71: mov     eax, [rip+he_n]
    cmp     eax, MAXHE
    jae     .Lha_full
    imul    rbx, rax, HE_SZ
    lea     rcx, [rip+he_rec]
    add     rbx, rcx
    mov     [rbx+HE_E], edi
    mov     [rbx+HE_REV], esi
    mov     dword ptr [rbx+HE_USED], 0
    mov     ecx, [rip+hp_n]
    mov     [rbx+HE_P], ecx
    call    ed_tess
    mov     edi, [rsp+HA_E]
    call    p_ed
    mov     r12, rax
    mov     ecx, [r12+ED_V0]
    mov     edx, [r12+ED_V1]
    cmp     dword ptr [rsp+HA_REV], 0
    je      1f
    xchg    ecx, edx
1:  mov     [rbx+HE_V0], ecx
    mov     [rbx+HE_V1], edx
    mov     ecx, [r12+ED_NPOLY]
    mov     [rsp+HA_KN], ecx
    movsd   xmm0, [rip+af_hu]
    movsd   [rsp+HA_HU], xmm0
    movsd   xmm0, [rip+af_hv]
    movsd   [rsp+HA_HV], xmm0
    mov     dword ptr [rsp+HA_K], 0
.Lha_pt:
    mov     eax, [rsp+HA_K]
    cmp     eax, [rsp+HA_KN]
    jae     .Lha_done
    mov     ecx, eax
    cmp     dword ptr [rsp+HA_REV], 0
    je      2f
    mov     ecx, [rsp+HA_KN]
    dec     ecx
    sub     ecx, eax
2:  shl     ecx, 5
    mov     rsi, [r12+ED_POLY]
    add     rsi, rcx
    mov     rdi, [rip+af_surf]
    movsd   xmm0, [rsp+HA_HU]
    movsd   xmm1, [rsp+HA_HV]
    call    to_uv
    movsd   [rsp+HA_HU], xmm0
    movsd   [rsp+HA_HV], xmm1
    mov     eax, [rip+hp_n]
    cmp     eax, MAXHP
    jae     .Lha_full
    shl     rax, 4
    lea     rcx, [rip+hp_pts]
    mulsd   xmm0, [rip+af_su]
    mulsd   xmm1, [rip+af_sv]
    movsd   [rcx+rax], xmm0
    movsd   [rcx+rax+8], xmm1
    inc     dword ptr [rip+hp_n]
    inc     dword ptr [rsp+HA_K]
    jmp     .Lha_pt
.Lha_done:
    mov     eax, [rip+hp_n]
    sub     eax, [rbx+HE_P]
    mov     [rbx+HE_N], eax
    call    he_angles
    inc     dword ptr [rip+he_n]
    jmp     .Lha_out
.Lha_full:
    mov     dword ptr [rip+bo_fail], 1
.Lha_out:
    add     rsp, 48
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# he_angles(rbx=half-edge) - its first direction and its last reversed
he_angles:
    sub     rsp, 8
    mov     eax, [rbx+HE_P]
    shl     rax, 4
    lea     rcx, [rip+hp_pts]
    add     rcx, rax
    mov     edx, [rbx+HE_N]
    xorpd   xmm0, xmm0
    movsd   [rbx+HE_ANG], xmm0
    movsd   [rbx+HE_RANG], xmm0
    cmp     edx, 2
    jb      9f
    push    rcx
    push    rdx
    movsd   xmm0, [rcx+24]              # first: p1 - p0
    subsd   xmm0, [rcx+8]
    movsd   xmm1, [rcx+16]
    subsd   xmm1, [rcx]
    call    datan2
    movsd   [rbx+HE_ANG], xmm0
    pop     rdx
    pop     rcx
    dec     edx                         # last reversed: p(n-2) - p(n-1)
    shl     rdx, 4
    movsd   xmm0, [rcx+rdx-8]
    subsd   xmm0, [rcx+rdx+8]
    movsd   xmm1, [rcx+rdx-16]
    subsd   xmm1, [rcx+rdx]
    call    datan2
    movsd   [rbx+HE_RANG], xmm0
9:  add     rsp, 8
    ret

# he_left(rbx=half-edge) -> xmm0, xmm1 = a point a little to the left of
#   the middle of its first segment
he_left:
    mov     eax, [rbx+HE_P]
    shl     rax, 4
    lea     rcx, [rip+hp_pts]
    add     rcx, rax
    movsd   xmm2, [rcx+16]              # d = p1 - p0
    subsd   xmm2, [rcx]
    movsd   xmm3, [rcx+24]
    subsd   xmm3, [rcx+8]
    movsd   xmm0, [rcx]                 # middle - 0.001 dy, + 0.001 dx
    addsd   xmm0, [rcx+16]
    mulsd   xmm0, [rip+bo_half]
    movsd   xmm1, [rcx+8]
    addsd   xmm1, [rcx+24]
    mulsd   xmm1, [rip+bo_half]
    mulsd   xmm2, [rip+bo_left]
    mulsd   xmm3, [rip+bo_left]
    subsd   xmm0, xmm3
    addsd   xmm1, xmm2
    ret

# he_first / he_last(rbx=half-edge) -> xmm0, xmm1 = its first / last point
he_first:
    mov     eax, [rbx+HE_P]
    jmp     1f
he_last:
    mov     eax, [rbx+HE_P]
    add     eax, [rbx+HE_N]
    dec     eax
1:  shl     rax, 4
    lea     rcx, [rip+hp_pts]
    movsd   xmm0, [rcx+rax]
    movsd   xmm1, [rcx+rax+8]
    ret

# bo_face(edi=local face) - divided (when touched) and classified; what is
#   kept becomes faces of the result
.equ BF_LF,   0
.equ BF_F,    4
.equ BF_CLS,  8
.equ BF_KEEP, 12
.equ BF_FLIP, 16
.equ BF_I,    20
.equ BF_UV,   24
.equ BF_PN,   40                        # P, N
.equ BF_R,    88
bo_face:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 104
    mov     [rsp+BF_LF], edi
    mov     [rip+af_lf], edi
    lea     rcx, [rip+lf_face]
    mov     eax, [rcx+rdi*4]
    mov     [rsp+BF_F], eax
    mov     [rip+af_f], eax
    mov     edi, eax
    call    p_fc
    mov     rbx, rax
    mov     edi, [rbx+FC_SURF]
    call    p_sf
    mov     [rip+af_surf], rax
    mov     eax, [rsp+BF_LF]
    lea     rcx, [rip+lf_su]
    movsd   xmm0, [rcx+rax*8]
    movsd   [rip+af_su], xmm0
    lea     rcx, [rip+lf_sv]
    movsd   xmm0, [rcx+rax*8]
    cmp     dword ptr [rbx+FC_SENSE], 0
    je      1f
    xorpd   xmm0, [rip+bo_negm]
1:  movsd   [rip+af_sv], xmm0
    movsd   xmm0, [rbx+FC_U0]
    addsd   xmm0, [rbx+FC_U1]
    mulsd   xmm0, [rip+bo_half]
    movsd   [rip+af_hu], xmm0
    movsd   xmm0, [rbx+FC_V0]
    addsd   xmm0, [rbx+FC_V1]
    mulsd   xmm0, [rip+bo_half]
    movsd   [rip+af_hv], xmm0
    # touched: a section in it, a split edge, or a paired face
    mov     eax, [rsp+BF_LF]
    lea     rcx, [rip+lf_touch]
    cmp     dword ptr [rcx+rax*4], 0
    jne     .Lbf_divide
    mov     dword ptr [rip+cut_any], 0
    mov     edi, [rsp+BF_F]
    lea     rsi, [rip+cut_check]
    call    each_coedge
    cmp     dword ptr [rip+cut_any], 0
    jne     .Lbf_divide
    # untouched: one point decides for the whole face
    mov     edi, [rsp+BF_F]
    mov     esi, 24
    call    fc_sample
    call    fs_deep_point
    test    eax, eax
    jz      .Lbf_out
    call    classify
    call    keep_rule
    test    eax, eax
    jz      .Lbf_out
    mov     edi, [rsp+BF_F]
    mov     esi, edx
    call    emit_copy
    jmp     .Lbf_out
.Lbf_divide:
    mov     dword ptr [rip+he_n], 0
    mov     dword ptr [rip+hp_n], 0
    mov     edi, [rsp+BF_F]             # the boundary pieces
    lea     rsi, [rip+he_boundary]
    call    each_coedge
    xor     r12d, r12d                  # the sections in it
.Lbf_sec:
    cmp     r12d, [rip+spc_n]
    jae     .Lbf_coin
    mov     eax, [rsp+BF_LF]
    lea     rcx, [rip+spc_a]
    cmp     [rcx+r12*4], eax
    je      2f
    lea     rcx, [rip+spc_b]
    cmp     [rcx+r12*4], eax
    jne     3f
2:  lea     rcx, [rip+spc_e]
    mov     edi, [rcx+r12*4]
    xor     esi, esi
    call    he_add
    lea     rcx, [rip+spc_e]
    mov     edi, [rcx+r12*4]
    mov     esi, 1
    call    he_add
3:  inc     r12d
    jmp     .Lbf_sec
.Lbf_coin:
    mov     eax, [rsp+BF_LF]            # a paired face's edges inside it
    lea     rcx, [rip+lf_coin]
    mov     eax, [rcx+rax*4]
    test    eax, eax
    js      .Lbf_ins0
    lea     rcx, [rip+lf_face]
    mov     edi, [rcx+rax*4]
    lea     rsi, [rip+he_inserted]
    call    each_coedge
.Lbf_ins0:
    xor     r12d, r12d                  # edges of the other solid along it
.Lbf_ins:
    cmp     r12d, [rip+ins_n]
    jae     .Lbf_walk
    mov     eax, [rsp+BF_LF]
    lea     rcx, [rip+ins_f]
    cmp     [rcx+r12*4], eax
    jne     1f
    lea     rcx, [rip+ins_e]
    mov     eax, [rcx+r12*4]
    mov     [rsp+BF_I], eax
    lea     rax, [rsp+BF_I]             # (as a coedge record: CE_EDGE = 0)
    call    he_inserted
1:  inc     r12d
    jmp     .Lbf_ins
.Lbf_walk:
    cmp     dword ptr [rip+bo_fail], 0
    jne     .Lbf_out
    call    bk_keep                     # (debugging: the arrangement)
    test    eax, eax
    jz      1f
    lea     rdi, [rip+he_rec]
    mov     esi, [rip+he_n]
    mov     edx, [rip+af_lf]
    call    bk_dump_he
1:  call    walk_cycles
    call    nest_cycles
    xor     r12d, r12d                  # each outer cycle: a region
.Lbf_reg:
    cmp     r12d, [rip+cy_n]
    jae     .Lbf_out
    lea     rcx, [rip+cy_area]
    movsd   xmm0, [rcx+r12*8]
    comisd  xmm0, [rip+bo_tiny]
    jbe     .Lbf_regn
    mov     edi, r12d
    call    region_points
    call    fs_deep_point
    test    eax, eax
    jz      .Lbf_regn
    divsd   xmm0, [rip+af_su]           # back to the face's (u, v)
    divsd   xmm1, [rip+af_sv]
    call    classify
    call    keep_rule
    test    eax, eax
    jz      .Lbf_regn
    mov     edi, r12d
    mov     esi, edx
    call    emit_region
.Lbf_regn:
    inc     r12d
    jmp     .Lbf_reg
.Lbf_out:
    add     rsp, 104
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.section .bss
cut_any:        .skip 4
.text
# cut_check(rax=coedge) - cut_any = 1 if its edge was split
cut_check:
    mov     ecx, [rax+CE_EDGE]
    cmp     ecx, [rip+ep_cap]
    jae     9f
    mov     rdx, [rip+ep_cnt]
    cmp     dword ptr [rdx+rcx*4], 1
    jbe     9f
    mov     dword ptr [rip+cut_any], 1
9:  ret

# he_boundary(rax=coedge, edx=its index) - its edge's pieces walked its way
#   (a pole: its pcurve)
he_boundary:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     r14d, edx
    mov     ebx, [rax+CE_EDGE]
    mov     r12d, [rax+CE_REV]
    mov     edi, ebx
    call    p_ed
    test    dword ptr [rax+ED_FLAGS], EF_DEGEN
    jnz     .Lhb_pole
    mov     rcx, [rip+ep_first]
    mov     r13d, [rcx+rbx*4]
    mov     rcx, [rip+ep_cnt]
    mov     ebx, [rcx+rbx*4]
    test    r12d, r12d
    jnz     2f
    xor     ecx, ecx                    # forwards
1:  cmp     ecx, ebx
    jae     9f
    push    rcx
    sub     rsp, 8
    lea     eax, [r13+rcx]
    lea     rdx, [rip+ep_list]
    mov     edi, [rdx+rax*4]
    xor     esi, esi
    call    he_add
    add     rsp, 8
    pop     rcx
    inc     ecx
    jmp     1b
2:  mov     ecx, ebx                    # backwards
3:  dec     ecx
    js      9f
    push    rcx
    sub     rsp, 8
    lea     eax, [r13+rcx]
    lea     rdx, [rip+ep_list]
    mov     edi, [rdx+rax*4]
    mov     esi, 1
    call    he_add
    add     rsp, 8
    pop     rcx
    jmp     3b
.Lhb_pole:
    mov     edi, r14d
    mov     esi, ebx
    mov     edx, r12d
    call    he_pole
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# he_pole(edi=coedge, esi=edge, edx=rev) - a half-edge at a pole: its
#   pcurve's points
he_pole:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 48
    mov     r12d, edi
    mov     eax, [rip+he_n]
    cmp     eax, MAXHE
    jae     9f
    imul    rbx, rax, HE_SZ
    lea     rcx, [rip+he_rec]
    add     rbx, rcx
    mov     [rbx+HE_E], esi
    mov     [rbx+HE_REV], edx
    mov     dword ptr [rbx+HE_USED], 0
    mov     edi, esi
    call    p_ed
    mov     ecx, [rax+ED_V0]
    mov     [rbx+HE_V0], ecx
    mov     [rbx+HE_V1], ecx
    mov     ecx, [rip+hp_n]
    mov     [rbx+HE_P], ecx
    xor     r13d, r13d
1:  cmp     r13d, 8
    ja      2f
    cvtsi2sd xmm0, r13d
    mov     eax, 8
    cvtsi2sd xmm1, eax
    divsd   xmm0, xmm1
    mov     edi, r12d
    lea     rsi, [rsp]
    call    ce_uv
    mov     eax, [rip+hp_n]
    cmp     eax, MAXHP
    jae     9f
    shl     rax, 4
    lea     rcx, [rip+hp_pts]
    movsd   xmm0, [rsp]
    mulsd   xmm0, [rip+af_su]
    movsd   [rcx+rax], xmm0
    movsd   xmm0, [rsp+8]
    mulsd   xmm0, [rip+af_sv]
    movsd   [rcx+rax+8], xmm0
    inc     dword ptr [rip+hp_n]
    inc     r13d
    jmp     1b
2:  mov     eax, [rip+hp_n]
    sub     eax, [rbx+HE_P]
    mov     [rbx+HE_N], eax
    call    he_angles
    inc     dword ptr [rip+he_n]
9:  add     rsp, 48
    pop     r13
    pop     r12
    pop     rbx
    ret

# he_inserted(rax=coedge of the paired face) - its edge's pieces that lie
#   inside the face being divided (off its boundary): both ways
he_inserted:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 40
    mov     ebx, [rax+CE_EDGE]
    mov     rcx, [rip+ep_first]
    mov     r13d, [rcx+rbx*4]
    mov     rcx, [rip+ep_cnt]
    mov     r14d, [rcx+rbx*4]
    xor     r12d, r12d
1:  cmp     r12d, r14d
    jae     9f
    lea     eax, [r13+r12]
    lea     rcx, [rip+ep_list]
    mov     ebx, [rcx+rax*4]
    mov     edi, ebx
    lea     rsi, [rsp]
    call    ed_mid
    mov     rdi, [rip+af_surf]
    lea     rsi, [rsp]
    movsd   xmm0, [rip+af_hu]
    movsd   xmm1, [rip+af_hv]
    call    to_uv
    movsd   [rsp+24], xmm0
    movsd   [rsp+32], xmm1
    mov     edi, [rip+af_lf]
    call    uv_inside
    test    eax, eax
    jz      2f
    mov     edi, [rip+af_lf]
    movsd   xmm0, [rsp+24]
    movsd   xmm1, [rsp+32]
    call    bdist
    comisd  xmm0, [rip+bo_on]
    jbe     2f
    mov     edi, ebx
    xor     esi, esi
    call    he_add
    mov     edi, ebx
    mov     esi, 1
    call    he_add
2:  inc     r12d
    jmp     1b
9:  add     rsp, 40
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# walk_cycles - every half-edge into one cycle: at each vertex the next is
#   the one turning most sharply (the first clockwise from the way back)
walk_cycles:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 40
    mov     dword ptr [rip+cy_n], 0
    mov     dword ptr [rip+cy_ln], 0
    xor     r12d, r12d
.Lwc_start:
    cmp     r12d, [rip+he_n]
    jae     .Lwc_out
    imul    rbx, r12, HE_SZ
    lea     rcx, [rip+he_rec]
    add     rbx, rcx
    cmp     dword ptr [rbx+HE_USED], 0
    jne     .Lwc_next
    mov     eax, [rip+cy_n]
    cmp     eax, MAXCY
    jae     .Lwc_out
    mov     ecx, [rip+cy_ln]
    lea     rdx, [rip+cy_first]
    mov     [rdx+rax*4], ecx
    mov     r13d, r12d                  # current
    xor     r15d, r15d                  # length
.Lwc_step:
    imul    rbx, r13, HE_SZ
    lea     rcx, [rip+he_rec]
    add     rbx, rcx
    mov     dword ptr [rbx+HE_USED], 1
    mov     eax, [rip+cy_ln]
    cmp     eax, MAXCL
    jae     .Lwc_out
    lea     rcx, [rip+cy_list]
    mov     [rcx+rax*4], r13d
    inc     dword ptr [rip+cy_ln]
    inc     r15d
    call    he_last                     # where it ends
    movsd   [rsp], xmm0
    movsd   [rsp+8], xmm1
    movsd   xmm0, [rbx+HE_RANG]
    movsd   [rsp+16], xmm0
    mov     r14d, [rbx+HE_V1]
    mov     ebp, -1                     # the best next
    movsd   xmm0, [rip+bo_big]
    movsd   [rsp+24], xmm0
    xor     ecx, ecx
.Lwc_cand:
    cmp     ecx, [rip+he_n]
    jae     .Lwc_chosen
    imul    rdx, rcx, HE_SZ
    lea     rax, [rip+he_rec]
    add     rdx, rax
    cmp     [rdx+HE_V0], r14d
    jne     .Lwc_cn
    cmp     dword ptr [rdx+HE_USED], 0  # used: only the cycle's start
    je      1f
    cmp     ecx, r12d
    jne     .Lwc_cn
1:  push    rcx                         # it starts where we are (in (u, v))
    push    rdx
    push    rbx
    mov     rbx, rdx
    call    he_first
    pop     rbx
    pop     rdx
    pop     rcx
    subsd   xmm0, [rsp]
    subsd   xmm1, [rsp+8]
    andpd   xmm0, [rip+bo_absm]
    andpd   xmm1, [rip+bo_absm]
    addsd   xmm0, xmm1
    movsd   xmm1, [rip+bo_size]
    mulsd   xmm1, [rip+bo_rsec]
    comisd  xmm0, xmm1
    ja      .Lwc_cn
    movsd   xmm0, [rsp+16]              # d = (back - its angle) mod 2 pi,
    subsd   xmm0, [rdx+HE_ANG]          #  in (0, 2 pi]
2:  xorpd   xmm1, xmm1
    comisd  xmm0, [rip+bo_angeps]
    ja      3f
    addsd   xmm0, [rip+bo_2pi]
    jmp     2b
3:  comisd  xmm0, [rip+bo_2pi]
    jbe     4f
    subsd   xmm0, [rip+bo_2pi]
    jmp     3b
4:  comisd  xmm0, [rsp+24]
    jae     .Lwc_cn
    movsd   [rsp+24], xmm0
    mov     ebp, ecx
.Lwc_cn:
    inc     ecx
    jmp     .Lwc_cand
.Lwc_chosen:
    test    ebp, ebp
    js      .Lwc_end                    # (a dead end: broken)
    cmp     ebp, r12d
    je      .Lwc_end                    # round to the start
    imul    rax, rbp, HE_SZ
    lea     rcx, [rip+he_rec]
    cmp     dword ptr [rcx+rax+HE_USED], 0
    jne     .Lwc_end
    cmp     r15d, 4096
    ja      .Lwc_end
    mov     r13d, ebp
    jmp     .Lwc_step
.Lwc_end:
    mov     eax, [rip+cy_n]
    lea     rcx, [rip+cy_cnt]
    mov     [rcx+rax*4], r15d
    xor     edx, edx                    # closed? (ended at the start)
    cmp     ebp, r12d
    sete    dl
    mov     edi, eax
    push    rdx
    sub     rsp, 8
    call    cy_area_of
    add     rsp, 8
    pop     rdx
    test    edx, edx
    jnz     5f
    xorpd   xmm0, xmm0                  # (not closed: no area, ignored)
5:  mov     eax, [rip+cy_n]
    lea     rcx, [rip+cy_area]
    movsd   [rcx+rax*8], xmm0
    inc     dword ptr [rip+cy_n]
.Lwc_next:
    inc     r12d
    jmp     .Lwc_start
.Lwc_out:
    add     rsp, 40
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# cy_area_of(edi=cycle) -> xmm0 = its signed area
cy_area_of:
    push    rbx
    push    r12
    push    r13
    lea     rax, [rip+cy_first]
    mov     r12d, [rax+rdi*4]
    lea     rax, [rip+cy_cnt]
    mov     r13d, [rax+rdi*4]
    add     r13d, r12d
    xorpd   xmm6, xmm6
1:  cmp     r12d, r13d
    jae     9f
    lea     rax, [rip+cy_list]
    mov     eax, [rax+r12*4]
    imul    rbx, rax, HE_SZ
    lea     rcx, [rip+he_rec]
    add     rbx, rcx
    mov     eax, [rbx+HE_P]
    mov     ecx, [rbx+HE_N]
    dec     ecx
    lea     rdx, [rip+hp_pts]
2:  test    ecx, ecx
    jz      3f
    mov     r8, rax
    shl     r8, 4
    movsd   xmm0, [rdx+r8]              # x0 y1 - x1 y0
    mulsd   xmm0, [rdx+r8+24]
    movsd   xmm1, [rdx+r8+16]
    mulsd   xmm1, [rdx+r8+8]
    subsd   xmm0, xmm1
    addsd   xmm6, xmm0
    inc     eax
    dec     ecx
    jmp     2b
3:  inc     r12d
    jmp     1b
9:  movsd   xmm0, xmm6
    mulsd   xmm0, [rip+bo_half]
    pop     r13
    pop     r12
    pop     rbx
    ret

# cy_inside(edi=cycle, xmm0, xmm1 = point) -> eax = 1 inside it (even-odd)
cy_inside:
    push    rbx
    push    r12
    push    r13
    lea     rax, [rip+cy_first]
    mov     r12d, [rax+rdi*4]
    lea     rax, [rip+cy_cnt]
    mov     r13d, [rax+rdi*4]
    add     r13d, r12d
    xor     r9d, r9d
1:  cmp     r12d, r13d
    jae     9f
    lea     rax, [rip+cy_list]
    mov     eax, [rax+r12*4]
    imul    rbx, rax, HE_SZ
    lea     rcx, [rip+he_rec]
    add     rbx, rcx
    mov     eax, [rbx+HE_P]
    mov     ecx, [rbx+HE_N]
    dec     ecx
    lea     rdx, [rip+hp_pts]
2:  test    ecx, ecx
    jz      3f
    mov     r8, rax
    shl     r8, 4
    movsd   xmm2, [rdx+r8+8]
    movsd   xmm3, [rdx+r8+24]
    xor     r10d, r10d
    xor     r11d, r11d
    comisd  xmm2, xmm1
    seta    r10b
    comisd  xmm3, xmm1
    seta    r11b
    cmp     r10d, r11d
    je      4f
    movsd   xmm4, xmm1
    subsd   xmm4, xmm2
    movsd   xmm5, [rdx+r8+16]
    subsd   xmm5, [rdx+r8]
    mulsd   xmm4, xmm5
    subsd   xmm3, xmm2
    divsd   xmm4, xmm3
    addsd   xmm4, [rdx+r8]
    comisd  xmm0, xmm4
    jae     4f
    xor     r9d, 1
4:  inc     eax
    dec     ecx
    jmp     2b
3:  inc     r12d
    jmp     1b
9:  mov     eax, r9d
    pop     r13
    pop     r12
    pop     rbx
    ret

# nest_cycles - each hole (negative cycle) in the smallest outer cycle
#   around it (cy_par; -1 for outer cycles and lost holes)
nest_cycles:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 32
    xor     ebx, ebx
.Lnc_c:
    cmp     ebx, [rip+cy_n]
    jae     .Lnc_out
    lea     rcx, [rip+cy_par]
    mov     dword ptr [rcx+rbx*4], -1
    lea     rcx, [rip+cy_area]
    movsd   xmm0, [rcx+rbx*8]
    movsd   xmm1, [rip+bo_tiny]
    xorpd   xmm1, [rip+bo_negm]
    comisd  xmm0, xmm1
    jae     .Lnc_next
    lea     rcx, [rip+cy_first]         # a hole: its first point
    mov     eax, [rcx+rbx*4]
    lea     rcx, [rip+cy_list]
    mov     eax, [rcx+rax*4]
    imul    rax, rax, HE_SZ
    lea     rcx, [rip+he_rec]
    add     rcx, rax
    push    rbx                         # a point just left of its first
    mov     rbx, rcx                    #  segment: on the region's side
    call    he_left
    pop     rbx
    movsd   [rsp], xmm0
    movsd   [rsp+8], xmm1
    movsd   xmm0, [rip+bo_big]
    movsd   [rsp+16], xmm0
    xor     r12d, r12d
1:  cmp     r12d, [rip+cy_n]
    jae     .Lnc_next
    lea     rcx, [rip+cy_area]
    movsd   xmm0, [rcx+r12*8]
    comisd  xmm0, [rip+bo_tiny]
    jbe     2f
    comisd  xmm0, [rsp+16]
    jae     2f
    mov     edi, r12d
    movsd   xmm0, [rsp]
    movsd   xmm1, [rsp+8]
    call    cy_inside
    test    eax, eax
    jz      2f
    lea     rcx, [rip+cy_area]
    movsd   xmm0, [rcx+r12*8]
    movsd   [rsp+16], xmm0
    lea     rcx, [rip+cy_par]
    mov     [rcx+rbx*4], r12d
2:  inc     r12d
    jmp     1b
.Lnc_next:
    inc     ebx
    jmp     .Lnc_c
.Lnc_out:
    add     rsp, 32
    pop     r13
    pop     r12
    pop     rbx
    ret

# region_points(edi=outer cycle) - fs_* hold the region's cycles' points
region_points:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     ebx, edi
    xor     eax, eax
    mov     [rip+fs_nl], eax
    mov     [rip+fs_np], eax
    mov     edi, ebx
    call    fs_cycle
    xor     r12d, r12d
1:  cmp     r12d, [rip+cy_n]
    jae     9f
    lea     rcx, [rip+cy_par]
    cmp     [rcx+r12*4], ebx
    jne     2f
    mov     edi, r12d
    call    fs_cycle
2:  inc     r12d
    jmp     1b
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret
# fs_cycle(edi=cycle) - its points as one more fs loop
fs_cycle:
    push    rbx
    push    r12
    push    r13
    mov     eax, [rip+fs_nl]
    cmp     eax, 256
    jae     9f
    mov     ecx, [rip+fs_np]
    lea     rdx, [rip+fs_ls]
    mov     [rdx+rax*4], ecx
    lea     rax, [rip+cy_first]
    mov     r12d, [rax+rdi*4]
    lea     rax, [rip+cy_cnt]
    mov     r13d, [rax+rdi*4]
    add     r13d, r12d
1:  cmp     r12d, r13d
    jae     3f
    lea     rax, [rip+cy_list]
    mov     eax, [rax+r12*4]
    imul    rbx, rax, HE_SZ
    lea     rcx, [rip+he_rec]
    add     rbx, rcx
    mov     eax, [rbx+HE_P]
    mov     ecx, [rbx+HE_N]
    dec     ecx
2:  test    ecx, ecx
    jz      21f
    mov     edx, [rip+fs_np]
    cmp     edx, 16384
    jae     21f
    mov     r8, rax
    shl     r8, 4
    lea     r9, [rip+hp_pts]
    movupd  xmm0, [r9+r8]
    shl     rdx, 4
    lea     r9, [rip+fs_pts]
    movupd  [r9+rdx], xmm0
    inc     dword ptr [rip+fs_np]
    inc     eax
    dec     ecx
    jmp     2b
21: inc     r12d
    jmp     1b
3:  mov     eax, [rip+fs_nl]
    mov     ecx, [rip+fs_np]
    lea     rdx, [rip+fs_ls]
    sub     ecx, [rdx+rax*4]
    lea     rdx, [rip+fs_ln]
    mov     [rdx+rax*4], ecx
    inc     dword ptr [rip+fs_nl]
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# classify(xmm0, xmm1 = (u, v) on the face being divided) -> eax = C_OUT,
#   C_IN, C_SAME or C_OPP against the other solid
classify:
    push    rbx
    push    r12
    sub     rsp, 120
    movsd   [rsp], xmm0
    movsd   [rsp+8], xmm1
    mov     rdi, [rip+af_surf]
    lea     rsi, [rsp+16]
    call    sf_normal                   # P, N (Su x Sv)
    mov     edi, [rip+af_f]
    call    p_fc
    cmp     dword ptr [rax+FC_SENSE], 0
    je      1f
    lea     rdi, [rsp+40]
    lea     rsi, [rsp+40]
    movsd   xmm0, [rip+bo_one]
    xorpd   xmm0, [rip+bo_negm]
    call    v3scale
1:  mov     eax, [rip+af_lf]            # on the paired face?
    lea     rcx, [rip+lf_coin]
    mov     ebx, [rcx+rax*4]
    test    ebx, ebx
    js      .Lcl_ray
    mov     edi, ebx
    call    lf_surf
    mov     r12, rax
    mov     rdi, rax
    lea     rsi, [rsp+16]
    xorpd   xmm0, xmm0
    xorpd   xmm1, xmm1
    call    sf_invert
    mov     edi, ebx
    call    uv_inside
    test    eax, eax
    jz      .Lcl_ray
    lea     rdi, [r12+SF_Z]             # the same way out?
    lea     rsi, [rsp+40]
    call    v3dot
    mov     ecx, ebx
    lea     rdx, [rip+lf_face]
    mov     edi, [rdx+rcx*4]
    movsd   [rsp+64], xmm0
    call    p_fc
    movsd   xmm0, [rsp+64]
    cmp     dword ptr [rax+FC_SENSE], 0
    je      2f
    xorpd   xmm0, [rip+bo_negm]
2:  mov     eax, C_SAME
    xorpd   xmm1, xmm1
    comisd  xmm0, xmm1
    ja      9f
    mov     eax, C_OPP
    jmp     9f
.Lcl_ray:
    mov     edi, [rip+bo_b]             # the other solid
    mov     eax, [rip+af_lf]
    cmp     eax, [rip+lf_na]
    jb      3f
    mov     edi, [rip+bo_a]
3:  lea     rsi, [rsp+16]
    call    bd_inside
9:  add     rsp, 120
    pop     r12
    pop     rbx
    ret

# keep_rule(eax=class) -> eax = 1 kept, edx = 1 turned inside out
keep_rule:
    mov     ecx, [rip+af_lf]
    xor     edx, edx
    cmp     ecx, [rip+lf_na]
    jae     .Lkr_b
    cmp     eax, C_OUT                  # A: outside, or on B ...
    je      .Lkr_yes
    mov     ecx, C_SAME                 # ... the same way (union) or the
    cmp     dword ptr [rip+bo_op], OP_UNION   #  other way (difference)
    je      1f
    mov     ecx, C_OPP
1:  cmp     eax, ecx
    je      .Lkr_yes
    jmp     .Lkr_no
.Lkr_b:
    cmp     dword ptr [rip+bo_op], OP_UNION
    jne     2f
    cmp     eax, C_OUT                  # union: B outside A
    je      .Lkr_yes
    jmp     .Lkr_no
2:  cmp     eax, C_IN                   # difference: B inside A, turned
    jne     .Lkr_no
    mov     edx, 1
.Lkr_yes:
    mov     eax, 1
    ret
.Lkr_no:
    xor     eax, eax
    ret

# emit_copy(edi=face, esi=1 turned) - the face as it is in the result
emit_copy:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 24
    mov     r12d, esi
    call    p_fc
    mov     rbx, rax
    mov     edi, [rbx+FC_SURF]
    movsd   xmm0, [rip+af_hu]
    movsd   xmm1, [rip+af_hv]
    call    fb_face
    mov     edi, eax
    call    p_fc
    mov     r13, rax
    mov     eax, [rbx+FC_SENSE]
    xor     eax, r12d
    mov     [r13+FC_SENSE], eax
    call    copy_box
    mov     r14d, [rbx+FC_LOOP]
    mov     r15d, [rbx+FC_NLOOP]
    add     r15d, r14d
1:  cmp     r14d, r15d
    jae     9f
    call    fb_loop
    mov     edi, r14d
    call    p_lp
    mov     ebp, [rax+LP_FIRST]
    mov     ecx, [rax+LP_N]
    mov     [rsp], ecx
    mov     dword ptr [rsp+4], 0
2:  mov     eax, [rsp+4]
    cmp     eax, [rsp]
    jae     4f
    mov     ecx, eax                    # turned: walked backwards
    test    r12d, r12d
    jz      3f
    mov     ecx, [rsp]
    dec     ecx
    sub     ecx, eax
3:  lea     edi, [rbp+rcx]
    call    p_ce
    mov     [rsp+8], rax
    mov     edi, [rax+CE_EDGE]
    mov     esi, [rax+CE_REV]
    xor     esi, r12d
    call    fb_ce
    mov     edi, eax
    call    p_ce
    mov     rcx, [rsp+8]                # the same pcurve
    mov     edx, [rcx+CE_PC]
    mov     [rax+CE_PC], edx
    movsd   xmm0, [rcx+CE_P0]
    movsd   xmm1, [rcx+CE_P1]
    test    r12d, r12d
    jz      31f
    movsd   xmm2, xmm0
    movsd   xmm0, xmm1
    movsd   xmm1, xmm2
31: movsd   [rax+CE_P0], xmm0
    movsd   [rax+CE_P1], xmm1
    inc     dword ptr [rsp+4]
    jmp     2b
4:  inc     r14d
    jmp     1b
9:  add     rsp, 24
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
# copy_box(rbx=from, r13=to) - the (u, v) box
copy_box:
    movupd  xmm0, [rbx+FC_U0]
    movupd  [r13+FC_U0], xmm0
    movupd  xmm0, [rbx+FC_V0]
    movupd  [r13+FC_V0], xmm0
    mov     eax, [rip+af_f]
    mov     [r13+FC_SRC], eax
    ret

# emit_region(edi=outer cycle, esi=1 turned) - a face of the result: the
#   cycle and its holes
emit_region:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     r14d, edi
    mov     r12d, esi
    mov     edi, [rip+af_f]
    call    p_fc
    mov     rbx, rax
    mov     edi, [rbx+FC_SURF]
    movsd   xmm0, [rip+af_hu]
    movsd   xmm1, [rip+af_hv]
    call    fb_face
    mov     edi, eax
    call    p_fc
    mov     r13, rax
    mov     eax, [rbx+FC_SENSE]
    xor     eax, r12d
    mov     [r13+FC_SENSE], eax
    call    copy_box
    mov     edi, r14d
    mov     esi, r12d
    call    emit_cycle
    xor     ebx, ebx
1:  cmp     ebx, [rip+cy_n]
    jae     9f
    lea     rcx, [rip+cy_par]
    cmp     [rcx+rbx*4], r14d
    jne     2f
    mov     edi, ebx
    mov     esi, r12d
    call    emit_cycle
2:  inc     ebx
    jmp     1b
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
# emit_cycle(edi=cycle, esi=1 turned) - a loop of its half-edges
emit_cycle:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     r14d, esi
    lea     rax, [rip+cy_first]
    mov     r12d, [rax+rdi*4]
    lea     rax, [rip+cy_cnt]
    mov     r13d, [rax+rdi*4]
    call    fb_loop
    xor     ebx, ebx
1:  cmp     ebx, r13d
    jae     9f
    mov     eax, ebx
    test    r14d, r14d
    jz      2f
    mov     eax, r13d
    dec     eax
    sub     eax, ebx
2:  add     eax, r12d
    lea     rcx, [rip+cy_list]
    mov     eax, [rcx+rax*4]
    imul    rax, rax, HE_SZ
    lea     rcx, [rip+he_rec]
    add     rax, rcx
    mov     edi, [rax+HE_E]
    mov     esi, [rax+HE_REV]
    xor     esi, r14d
    call    fb_ce
    inc     ebx
    jmp     1b
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.section .note.GNU-stack,"",@progbits
