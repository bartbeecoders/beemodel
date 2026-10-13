# =============================================================================
#  BeeModel - mesh analysis and repair.
#
#  mesh_analyze classifies a mesh in one pass (edges by how many faces use
#  them and in which direction, faces by area and by how far they face
#  down, vertices no face uses). The viewport shows the classes as overlays
#  (View > Show ...), scripts and agents read the counts (analyze()), and
#  mesh.repair fixes what can be fixed: merge by distance, drop degenerate
#  and duplicate faces, fill holes, make the normals consistent and point
#  them out, drop loose vertices - with a one-line report.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

# exports
.globl mesh_analyze
.globl mesh_merge_dist
.globl an_count
.globl analysis_draw
.globl an_flags
.globl an_check
.globl mesh_analyze
.globl an_res
.globl an_fcls
.globl mesh_clean

.equ AN_NORMALS,  1
.equ AN_NONMAN,   2
.equ AN_BOUND,    4
.equ AN_DEGEN,    8
.equ AN_OVER,     16
.equ AN_THIN,     32                # print.s: wall thickness

.equ EC_BOUND,    1             # edge classes
.equ EC_NONMAN,   2
.equ FC_DEGEN,    1             # face classes
.equ FC_OVER,     2
.equ FC_THIN,     4                 # wall under the minimum
.equ FC_THIN2,    8                 #  under twice it

.equ SCR_MAX,     65536         # meshops.s's scratch polygon
.equ COL_AN_NORMAL, 0xa8e050
.equ COL_AN_BOUND,  0x40e0e0
.equ COL_AN_NONMAN, 0xf04848
.equ COL_AN_DEGEN,  0xe050e0
.equ COL_AN_OVER,   0xf08040
.equ COL_AN_THIN,   0xff3030
.equ COL_AN_THIN2,  0xf0d040

.section .bss
.align 8
an_flags:       .skip 4
an_angle:       .skip 4             # overhang angle (degrees, float)
an_res:         .skip 24            # boundary, non-manifold, degenerate,
                                    #  loose, overhang (u32 each)
.align 8
an_ecls:        .skip 8             # u8 per edge (ME_EDGES order)
an_fcls:        .skip 8             # u8 per polygon
an_mtx:         .skip 48
an_tmp:         .skip 64
# repair
.align 8
rp_rep:         .skip 8             # vertex -> representative
rp_next:        .skip 8
rp_used:        .skip 8
rp_poff:        .skip 8             # new polygons (offsets, loops)
rp_loops:       .skip 8
rp_np:          .skip 4
rp_nl:          .skip 4
rp_capp:        .skip 4
rp_capl:        .skip 4
rp_dead:        .skip 8             # u8 per new polygon: dropped
rp_flip:        .skip 8             # u8 per new polygon: reversed
rp_cnt:         .skip 32            # merged, degenerate, duplicate, holes,
                                    #  flipped, loose
.align 4
rp_dist:        .skip 4

.section .rodata
mc_rel:         .float 1.0e-4
.align 4
an_f45:         .float 45.0
an_deg2rad:     .float 0.017453292
an_fone:        .float 1.0
an_feps:        .float 1.0e-20
an_fnlen:       .float 0.4
an_fdist:       .float 0.0001
an_fhalf:       .float 0.5
.align 16
an_abs:         .long 0x7fffffff, 0, 0, 0
s_an_title:     .asciz "Analysis: "
s_an_b:         .asciz " boundary  "
s_an_n:         .asciz " non-manifold  "
s_an_d:         .asciz " degenerate  "
s_an_o:         .asciz " overhang  "
s_an_t:         .asciz " thin"
s_an_l:         .asciz " loose  "
s_rp_head:      .asciz "repair: merged "
s_rp_deg:       .asciz " vertices, removed "
s_rp_dup:       .asciz " degenerate and "
s_rp_holes:     .asciz " duplicate faces, filled "
s_rp_flip:      .asciz " holes, flipped "
s_rp_loose:     .asciz " faces, deleted "
s_rp_tail:      .asciz " loose vertices: "
s_rp_closed:    .asciz "closed"
s_rp_open:      .asciz "still open"
s_rp_none:      .asciz "repair: needs a mesh (active object, or edit mode)"
s_an_kinds:     .asciz "boundary"
                .asciz "nonmanifold"
                .asciz "degenerate"
                .asciz "loose"
                .asciz "overhang"
                .byte 0

OPERATOR op_an_normals, "view.show_normals", "Show Normals", do_an_toggle, check=an_check, arg=AN_NORMALS, flags=OPF_AI_SAFE|OPF_QUIET, doc="Draw the face normals of the active mesh"
OPERATOR op_an_nonman, "view.show_nonmanifold", "Show Non-manifold", do_an_toggle, check=an_check, arg=AN_NONMAN, flags=OPF_AI_SAFE|OPF_QUIET, doc="Mark edges used by more than two faces, or by two facing opposite ways"
OPERATOR op_an_bound, "view.show_boundary", "Show Boundary Edges", do_an_toggle, check=an_check, arg=AN_BOUND, flags=OPF_AI_SAFE|OPF_QUIET, doc="Mark edges used by one face only (holes)"
OPERATOR op_an_degen, "view.show_degenerate", "Show Degenerate Faces", do_an_toggle, check=an_check, arg=AN_DEGEN, flags=OPF_AI_SAFE|OPF_QUIET, doc="Mark faces without area"
OPERATOR op_an_over, "view.show_overhangs", "Show Overhangs", do_an_overhang, check=an_check, arg=AN_OVER, flags=OPF_AI_SAFE|OPF_QUIET, doc="Mark faces facing down steeper than an angle (for 3D printing): view.show_overhangs [degrees, default 45]"
OPERATOR op_repair, "mesh.repair", "Repair Mesh", do_repair, flags=OPF_AI_SAFE|OPF_UNDO, doc="Merge by distance, remove degenerate and duplicate faces, fill holes, fix normals, drop loose vertices: mesh.repair [distance, default 0.0001]"

.text

# =============================================================================
#  Analysis
# =============================================================================
# mesh_analyze(rdi=object) -> eax = 1; an_res counts, an_ecls / an_fcls per
#   edge / polygon (frame arena). Overhangs are measured in world space.
mesh_analyze:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 72
    mov     rbp, rdi
    mov     rbx, [rdi+OB_MESH]
    lea     rdi, [rip+an_res]
    xor     eax, eax
    mov     ecx, 6
    rep     stosd
    test    rbx, rbx
    jz      .Lma_fail
    mov     rdi, rbp
    lea     rsi, [rip+an_mtx]
    call    obj_matrix
    mov     edi, [rbx+ME_NEDGES]
    add     edi, 8
    call    fa
    test    rax, rax
    jz      .Lma_fail
    mov     [rip+an_ecls], rax
    mov     edi, [rbx+ME_NPOLYS]
    add     edi, 8
    call    fa
    test    rax, rax
    jz      .Lma_fail
    mov     [rip+an_fcls], rax
    mov     edi, [rbx+ME_NEDGES]        # edge -> index
    call    eh_new
    test    rax, rax
    jz      .Lma_fail
    mov     r12, rax
    mov     edi, [rbx+ME_NEDGES]        # counts: uses, forward, backward
    lea     edi, [rdi*4+16]
    call    fa
    test    rax, rax
    jz      .Lma_fail
    mov     r13, rax                    # u8 x 4 per edge: uses, fwd, bwd
    mov     edi, [rbx+ME_NVERTS]
    add     edi, 8
    call    fa
    test    rax, rax
    jz      .Lma_fail
    mov     r14, rax                    # vertex used
    xor     r15d, r15d
1:  cmp     r15d, [rbx+ME_NEDGES]
    jae     2f
    mov     rax, [rbx+ME_EDGES]
    mov     edi, [rax+r15*8]
    mov     esi, [rax+r15*8+4]
    call    ukey
    mov     rsi, rax
    mov     rdi, r12
    call    eh_slot
    mov     [rax], r15d
    inc     r15d
    jmp     1b
2:  xor     r15d, r15d                  # polygons: their edges
.Lma_poly:
    cmp     r15d, [rbx+ME_NPOLYS]
    jae     .Lma_edges
    mov     rax, [rbx+ME_POFF]
    mov     ecx, [rax+r15*4]
    mov     edx, [rax+r15*4+4]
    mov     [rsp], ecx
    mov     [rsp+4], edx
    mov     [rsp+8], ecx                # loop
3:  mov     ecx, [rsp+8]
    cmp     ecx, [rsp+4]
    jae     5f
    mov     rax, [rbx+ME_LOOPS]
    mov     edi, [rax+rcx*4]
    lea     edx, [rcx+1]
    cmp     edx, [rsp+4]
    jb      4f
    mov     edx, [rsp]
4:  mov     esi, [rax+rdx*4]
    mov     byte ptr [r14+rdi], 1
    mov     [rsp+12], edi
    mov     [rsp+16], esi
    call    ukey
    lea     rsi, [rax+1]
    mov     rdi, r12
    call    an_get
    test    eax, eax
    js      41f
    cmp     byte ptr [r13+rax*4], 255
    je      41f
    inc     byte ptr [r13+rax*4]
    mov     ecx, [rsp+12]
    cmp     ecx, [rsp+16]
    jb      42f
    inc     byte ptr [r13+rax*4+2]
    jmp     41f
42: inc     byte ptr [r13+rax*4+1]
41: inc     dword ptr [rsp+8]
    jmp     3b
5:  mov     edi, r15d                   # the face itself
    call    face_class
    mov     rcx, [rip+an_fcls]
    mov     [rcx+r15], al
    test    al, FC_DEGEN
    jz      51f
    inc     dword ptr [rip+an_res+8]
51: test    al, FC_OVER
    jz      52f
    inc     dword ptr [rip+an_res+16]
52: inc     r15d
    jmp     .Lma_poly
.Lma_edges:
    test    dword ptr [rip+an_flags], AN_THIN   # wall thickness classes
    jz      .Lma_e0
    mov     rdi, rbp
    call    th_faces
    test    rax, rax
    jz      .Lma_e0
    mov     [rsp+24], rax
    call    th_minw
    movss   [rsp+32], xmm0
    addss   xmm0, xmm0
    movss   [rsp+36], xmm0
    xor     r15d, r15d
1:  cmp     r15d, [rbx+ME_NPOLYS]
    jae     .Lma_e0
    mov     rax, [rsp+24]
    movss   xmm0, [rax+r15*4]
    mov     rcx, [rip+an_fcls]
    comiss  xmm0, [rsp+32]
    jae     2f
    or      byte ptr [rcx+r15], FC_THIN
    inc     dword ptr [rip+an_res+20]
    jmp     3f
2:  comiss  xmm0, [rsp+36]
    jae     3f
    or      byte ptr [rcx+r15], FC_THIN2
3:  inc     r15d
    jmp     1b
.Lma_e0:
    xor     r15d, r15d
1:  cmp     r15d, [rbx+ME_NEDGES]
    jae     3f
    movzx   eax, byte ptr [r13+r15*4]
    xor     edx, edx
    cmp     eax, 1
    jne     11f
    mov     edx, EC_BOUND
    inc     dword ptr [rip+an_res]
    jmp     2f
11: cmp     eax, 2
    ja      12f
    jb      2f
    cmp     byte ptr [r13+r15*4+1], 1   # two faces, opposite ways: fine
    je      2f
12: mov     edx, EC_NONMAN
    inc     dword ptr [rip+an_res+4]
2:  mov     rax, [rip+an_ecls]
    mov     [rax+r15], dl
    inc     r15d
    jmp     1b
3:  xor     ecx, ecx                    # loose vertices
4:  cmp     ecx, [rbx+ME_NVERTS]
    jae     5f
    cmp     byte ptr [r14+rcx], 0
    jne     41f
    inc     dword ptr [rip+an_res+12]
41: inc     ecx
    jmp     4b
5:  mov     eax, 1
    jmp     9f
.Lma_fail:
    xor     eax, eax
9:  add     rsp, 72
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# an_get(rdi=table, rsi=key+1) -> eax = value or -1
an_get:
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

# poly_newell(rbx=mesh, edi=polygon, rsi=out float[3] normal (not unit),
#   rdx=out float[3] centre)
poly_newell:
    push    r12
    push    r13
    mov     r8, [rbx+ME_POFF]
    mov     r9, [rbx+ME_LOOPS]
    mov     r10, [rbx+ME_POS]
    mov     ecx, [r8+rdi*4]
    mov     r11d, [r8+rdi*4+4]
    mov     r12d, ecx                   # first
    xorps   xmm0, xmm0                  # normal
    xorps   xmm1, xmm1
    xorps   xmm2, xmm2
    xorps   xmm3, xmm3                  # centre
    xorps   xmm4, xmm4
    xorps   xmm5, xmm5
1:  cmp     ecx, r11d
    jae     2f
    mov     eax, [r9+rcx*4]
    lea     eax, [rax+rax*2]
    lea     r13d, [rcx+1]
    cmp     r13d, r11d
    jb      11f
    mov     r13d, r12d
11: mov     r13d, [r9+r13*4]
    lea     r13d, [r13+r13*2]
    addss   xmm3, [r10+rax*4]
    addss   xmm4, [r10+rax*4+4]
    addss   xmm5, [r10+rax*4+8]
    # n.x += (y_i - y_j)(z_i + z_j), n.y += (z_i - z_j)(x_i + x_j),
    # n.z += (x_i - x_j)(y_i + y_j)
    movss   xmm6, [r10+rax*4+4]
    subss   xmm6, [r10+r13*4+4]
    movss   xmm7, [r10+rax*4+8]
    addss   xmm7, [r10+r13*4+8]
    mulss   xmm6, xmm7
    addss   xmm0, xmm6
    movss   xmm6, [r10+rax*4+8]
    subss   xmm6, [r10+r13*4+8]
    movss   xmm7, [r10+rax*4]
    addss   xmm7, [r10+r13*4]
    mulss   xmm6, xmm7
    addss   xmm1, xmm6
    movss   xmm6, [r10+rax*4]
    subss   xmm6, [r10+r13*4]
    movss   xmm7, [r10+rax*4+4]
    addss   xmm7, [r10+r13*4+4]
    mulss   xmm6, xmm7
    addss   xmm2, xmm6
    inc     ecx
    jmp     1b
2:  movss   [rsi], xmm0
    movss   [rsi+4], xmm1
    movss   [rsi+8], xmm2
    sub     r11d, r12d
    cvtsi2ss xmm6, r11d
    movss   xmm7, [rip+an_fone]
    divss   xmm7, xmm6
    mulss   xmm3, xmm7
    mulss   xmm4, xmm7
    mulss   xmm5, xmm7
    movss   [rdx], xmm3
    movss   [rdx+4], xmm4
    movss   [rdx+8], xmm5
    pop     r13
    pop     r12
    ret

# face_class(rbx=mesh, edi=polygon) -> eax = FC_ bits (an_mtx = the object's
#   matrix, for overhangs)
face_class:
    push    r12
    push    r13
    sub     rsp, 40
    mov     r12d, edi
    xor     r13d, r13d
    mov     r8, [rbx+ME_POFF]           # a corner repeated: degenerate
    mov     r9, [rbx+ME_LOOPS]
    mov     ecx, [r8+r12*4]
    mov     edx, [r8+r12*4+4]
    mov     eax, edx
    sub     eax, ecx
    cmp     eax, 3
    jb      .Lfc_degen
1:  cmp     ecx, edx
    jae     3f
    lea     r10d, [rcx+1]
2:  cmp     r10d, edx
    jae     21f
    mov     eax, [r9+rcx*4]
    cmp     eax, [r9+r10*4]
    je      .Lfc_degen
    inc     r10d
    jmp     2b
21: inc     ecx
    jmp     1b
3:  mov     edi, r12d
    lea     rsi, [rsp]
    lea     rdx, [rsp+12]
    call    poly_newell
    movss   xmm0, [rsp]                 # |n|^2 against the size^2
    mulss   xmm0, xmm0
    movss   xmm1, [rsp+4]
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    movss   xmm1, [rsp+8]
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    movss   [rsp+24], xmm0
    movss   xmm1, [rbx+ME_BMAX]         # diagonal^2 of the box
    subss   xmm1, [rbx+ME_BMIN]
    mulss   xmm1, xmm1
    movss   xmm2, [rbx+ME_BMAX+4]
    subss   xmm2, [rbx+ME_BMIN+4]
    mulss   xmm2, xmm2
    addss   xmm1, xmm2
    movss   xmm2, [rbx+ME_BMAX+8]
    subss   xmm2, [rbx+ME_BMIN+8]
    mulss   xmm2, xmm2
    addss   xmm1, xmm2
    mulss   xmm1, xmm1                  # (area ~ size^2, compared squared)
    mulss   xmm1, [rip+an_feps]
    comiss  xmm0, xmm1
    jbe     .Lfc_degen
    # overhang: the world normal (rotation part of the matrix; enough for
    #   the direction with uniform-ish scales) against straight down
    lea     rax, [rip+an_mtx]
    movss   xmm0, [rax+16]              # world y = row 1 . n
    mulss   xmm0, [rsp]
    movss   xmm1, [rax+20]
    mulss   xmm1, [rsp+4]
    addss   xmm0, xmm1
    movss   xmm1, [rax+24]
    mulss   xmm1, [rsp+8]
    addss   xmm0, xmm1
    movss   [rsp+28], xmm0
    xor     ecx, ecx                    # |world n|^2
    xorps   xmm3, xmm3
4:  imul    edx, ecx, 16
    movss   xmm0, [rax+rdx]
    mulss   xmm0, [rsp]
    movss   xmm1, [rax+rdx+4]
    mulss   xmm1, [rsp+4]
    addss   xmm0, xmm1
    movss   xmm1, [rax+rdx+8]
    mulss   xmm1, [rsp+8]
    addss   xmm0, xmm1
    mulss   xmm0, xmm0
    addss   xmm3, xmm0
    inc     ecx
    cmp     ecx, 3
    jb      4b
    sqrtss  xmm3, xmm3
    movss   xmm0, [rsp+28]              # -y / |n| > cos(angle)
    xorps   xmm1, xmm1
    subss   xmm1, xmm0
    divss   xmm1, xmm3
    movss   xmm0, [rip+an_angle]
    xorps   xmm2, xmm2
    comiss  xmm0, xmm2
    ja      5f
    movss   xmm0, [rip+an_f45]
5:  mulss   xmm0, [rip+an_deg2rad]
    movss   [rsp+32], xmm1
    call    cosf_
    movss   xmm1, [rsp+32]
    comiss  xmm1, xmm0
    jbe     .Lfc_out
    or      r13d, FC_OVER
    jmp     .Lfc_out
.Lfc_degen:
    or      r13d, FC_DEGEN
.Lfc_out:
    mov     eax, r13d
    add     rsp, 40
    pop     r13
    pop     r12
    ret

# cosf_(xmm0) -> xmm0 = cos
cosf_:
    sub     rsp, 8
    movss   [rsp], xmm0
    fld     dword ptr [rsp]
    fcos
    fstp    dword ptr [rsp]
    movss   xmm0, [rsp]
    add     rsp, 8
    ret

# an_count(rdi=object, esi=kind 0..4) -> eax = count (boundary, non-manifold,
#   degenerate, loose, overhang); -1 if not a mesh
an_count:
    push    rbx
    push    r12
    push    r13
    mov     r12d, esi
    call    fa_mark
    mov     r13, rax
    cmp     dword ptr [rdi+OB_TYPE], OT_MESH
    jne     8f
    call    mesh_analyze
    test    eax, eax
    jz      8f
    lea     rax, [rip+an_res]
    mov     ebx, [rax+r12*4]
    jmp     9f
8:  mov     ebx, -1
9:  mov     rdi, r13
    call    fa_release
    mov     eax, ebx
    pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Overlays
# =============================================================================
an_check:                               # rdi = flag -> eax = on
    xor     eax, eax
    test    [rip+an_flags], edi
    setnz   al
    ret

do_an_toggle:                           # rdi = flag
    xor     [rip+an_flags], edi
    mov     dword ptr [rip+dirty], 1
    ret

do_an_overhang:
    sub     rsp, 24
    mov     rsi, [rip+op_arg]           # an angle: on with it
    test    rsi, rsi
    jz      1f
    cmp     byte ptr [rsi], 0
    je      1f
    lea     rdx, [rsi+32]
    call    parse_float
    test    eax, eax
    jz      1f
    movss   [rip+an_angle], xmm0
    or      dword ptr [rip+an_flags], AN_OVER
    jmp     2f
1:  xor     dword ptr [rip+an_flags], AN_OVER
2:  mov     dword ptr [rip+dirty], 1
    add     rsp, 24
    ret

# analysis_draw - the overlays for the active mesh (viewport being drawn)
analysis_draw:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 88
    cmp     dword ptr [rip+an_flags], 0
    je      .Lad_out
    call    edit_get                    # the edit mesh, or the active one
    test    rax, rax
    jnz     1f
    mov     edi, [rip+active_obj]
    call    obj_get
    test    rax, rax
    jz      .Lad_out
    cmp     dword ptr [rax+OB_TYPE], OT_MESH
    jne     .Lad_out
1:  mov     rbx, rax
    mov     rdi, rbx
    call    mesh_analyze
    test    eax, eax
    jz      .Lad_out
    call    project_all                 # (rbx = object)
    test    rax, rax
    jz      .Lad_out
    mov     r13, rax                    # projected vertices
    mov     r12, [rbx+OB_MESH]
    # edges by class
    xor     r14d, r14d
2:  cmp     r14d, [r12+ME_NEDGES]
    jae     .Lad_faces
    mov     rax, [rip+an_ecls]
    movzx   eax, byte ptr [rax+r14]
    mov     edx, COL_AN_BOUND
    cmp     eax, EC_BOUND
    jne     21f
    test    dword ptr [rip+an_flags], AN_BOUND
    jnz     23f
    jmp     29f
21: cmp     eax, EC_NONMAN
    jne     29f
    mov     edx, COL_AN_NONMAN
    test    dword ptr [rip+an_flags], AN_NONMAN
    jz      29f
23: mov     rcx, [r12+ME_EDGES]
    mov     eax, [rcx+r14*8]
    mov     ecx, [rcx+r14*8+4]
    mov     edi, eax
    mov     esi, ecx
    call    an_edge
29: inc     r14d
    jmp     2b
.Lad_faces:
    xor     r14d, r14d
3:  cmp     r14d, [r12+ME_NPOLYS]
    jae     .Lad_legend
    mov     rax, [rip+an_fcls]
    movzx   r15d, byte ptr [rax+r14]
    mov     ebp, COL_AN_DEGEN
    test    r15d, FC_DEGEN
    jz      31f
    test    dword ptr [rip+an_flags], AN_DEGEN
    jnz     33f
31: test    dword ptr [rip+an_flags], AN_THIN
    jz      32f
    mov     ebp, COL_AN_THIN
    test    r15d, FC_THIN
    jnz     33f
    mov     ebp, COL_AN_THIN2
    test    r15d, FC_THIN2
    jnz     33f
32: mov     ebp, COL_AN_OVER
    test    r15d, FC_OVER
    jz      34f
    test    dword ptr [rip+an_flags], AN_OVER
    jz      34f
33: mov     rax, [r12+ME_POFF]          # its edges and a dot
    mov     ecx, [rax+r14*4]
    mov     edx, [rax+r14*4+4]
    mov     [rsp+64], ecx
    mov     [rsp+68], edx
    mov     [rsp+72], ecx
331:mov     ecx, [rsp+72]
    cmp     ecx, [rsp+68]
    jae     332f
    mov     rax, [r12+ME_LOOPS]
    mov     edi, [rax+rcx*4]
    lea     edx, [rcx+1]
    cmp     edx, [rsp+68]
    jb      333f
    mov     edx, [rsp+64]
333:mov     esi, [rax+rdx*4]
    mov     edx, ebp
    call    an_edge
    inc     dword ptr [rsp+72]
    jmp     331b
332:mov     rdi, r12                    # (rbx = object for poly_newell's
    push    rbx                         #  mesh: swap in the mesh)
    mov     rbx, r12
    mov     edi, r14d
    lea     rsi, [rsp+8]
    lea     rdx, [rsp+8+12]
    call    poly_newell
    pop     rbx
    movss   xmm0, [rsp+12]
    movss   xmm1, [rsp+16]
    movss   xmm2, [rsp+20]
    call    proj_local
    call    an_dot
34: test    dword ptr [rip+an_flags], AN_NORMALS
    jz      39f
    push    rbx
    mov     rbx, r12
    mov     edi, r14d
    lea     rsi, [rsp+8]
    lea     rdx, [rsp+8+12]
    call    poly_newell
    pop     rbx
    call    normal_line
39: inc     r14d
    jmp     3b
.Lad_legend:
    call    fmt_reset
    lea     rdi, [rip+s_an_title]
    call    fmt_str
    xor     r14d, r14d
4:  cmp     r14d, 6
    jae     5f
    lea     rax, [rip+an_res]
    mov     edi, [rax+r14*4]
    call    fmt_int
    lea     rax, [rip+an_legend]
    mov     rdi, [rax+r14*8]
    call    fmt_str
    inc     r14d
    jmp     4b
5:  mov     edi, [rip+cvs_x0]
    add     edi, 10
    mov     esi, [rip+cvs_y0]
    add     esi, 64
    lea     rdx, [rip+fmt_buf]
    mov     ecx, COL_ACCENT
    call    draw_text
.Lad_out:
    add     rsp, 88
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# an_edge(edi=a, esi=b vertices, edx=colour; r13 = projected) - depth tested,
#   two pixels wide
an_edge:
    push    rbx
    push    r12
    sub     rsp, 40
    mov     ebx, edx
    imul    rax, rdi, 12
    imul    rcx, rsi, 12
    lea     rdi, [r13+rax]
    lea     rsi, [r13+rcx]
    xorps   xmm0, xmm0
    comiss  xmm0, [rdi+8]
    jae     9f
    comiss  xmm0, [rsi+8]
    jae     9f
    mov     r12, rsi
    movups  xmm0, [rdi]                 # a copy one pixel down
    movups  [rsp], xmm0
    movups  xmm0, [rsi]
    movups  [rsp+16], xmm0
    mov     edx, ebx
    call    dline
    movss   xmm0, [rsp+4]
    addss   xmm0, [rip+an_fone]
    movss   [rsp+4], xmm0
    movss   xmm0, [rsp+20]
    addss   xmm0, [rip+an_fone]
    movss   [rsp+20], xmm0
    lea     rdi, [rsp]
    lea     rsi, [rsp+16]
    mov     edx, ebx
    call    dline
9:  add     rsp, 40
    pop     r12
    pop     rbx
    ret

# an_dot(xmm0..2 = projected point, ebp = colour) - when visible
an_dot:
    xorps   xmm3, xmm3
    comiss  xmm2, xmm3
    jbe     9f
    sub     rsp, 24
    movss   [rsp], xmm0
    movss   [rsp+4], xmm1
    call    visible
    test    eax, eax
    jz      8f
    movss   xmm0, [rsp]
    movss   xmm1, [rsp+4]
    mov     edx, ebp
    mov     ecx, 5
    call    dot
8:  add     rsp, 24
9:  ret

# normal_line([rsp+8..] = normal, centre of the caller's polygon; r12 =
#   mesh) - a line along the normal, as long as the face is wide (0.4x)
normal_line:
    push    rbx
    sub     rsp, 64
    lea     rbx, [rsp+80]               # caller's [rsp+8]: n (12), centre (12)
    movss   xmm0, [rbx]                 # unit n * len
    mulss   xmm0, xmm0
    movss   xmm1, [rbx+4]
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    movss   xmm1, [rbx+8]
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    sqrtss  xmm0, xmm0
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    jbe     9f
    movss   xmm1, xmm0                  # len ~ the face's size: 0.4 sqrt(area)
    mulss   xmm1, [rip+an_fhalf]        #  (|n| = 2 area)
    sqrtss  xmm1, xmm1
    mulss   xmm1, [rip+an_fnlen]
    divss   xmm1, xmm0
    movss   [rsp+48], xmm1
    movss   xmm0, [rbx+12]              # the centre
    movss   xmm1, [rbx+16]
    movss   xmm2, [rbx+20]
    call    proj_local
    movss   [rsp], xmm0
    movss   [rsp+4], xmm1
    movss   [rsp+8], xmm2
    movss   xmm0, [rbx]                 # the tip
    mulss   xmm0, [rsp+48]
    addss   xmm0, [rbx+12]
    movss   xmm1, [rbx+4]
    mulss   xmm1, [rsp+48]
    addss   xmm1, [rbx+16]
    movss   xmm2, [rbx+8]
    mulss   xmm2, [rsp+48]
    addss   xmm2, [rbx+20]
    call    proj_local
    movss   [rsp+16], xmm0
    movss   [rsp+20], xmm1
    movss   [rsp+24], xmm2
    xorps   xmm0, xmm0
    comiss  xmm0, [rsp+8]
    jae     9f
    comiss  xmm0, [rsp+24]
    jae     9f
    lea     rdi, [rsp]
    lea     rsi, [rsp+16]
    mov     edx, COL_AN_NORMAL
    call    dline
9:  add     rsp, 64
    pop     rbx
    ret

.section .rodata
.align 8
an_legend:      .quad s_an_b, s_an_n, s_an_d, s_an_l, s_an_o, s_an_t
.text

# =============================================================================
#  Repair
# =============================================================================
do_repair:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 56
    movss   xmm0, [rip+an_fdist]        # the distance (argument)
    movss   [rip+rp_dist], xmm0
    mov     rsi, [rip+op_arg]
    test    rsi, rsi
    jz      1f
    cmp     byte ptr [rsi], 0
    je      1f
    lea     rdx, [rsi+32]
    call    parse_float
    test    eax, eax
    jz      1f
    movss   [rip+rp_dist], xmm0
1:  lea     rdi, [rip+rp_cnt]
    xor     eax, eax
    mov     ecx, 8
    rep     stosd
    xor     r15d, r15d                  # 1 = edit mode
    call    edit_get
    test    rax, rax
    jz      2f
    mov     r15d, 1
    call    edit_cow                    # (own the mesh before replacing)
    call    edit_get
    jmp     3f
2:  mov     edi, [rip+active_obj]
    call    obj_get
    test    rax, rax
    jz      .Lrp_none
    cmp     dword ptr [rax+OB_TYPE], OT_MESH
    jne     .Lrp_none
3:  mov     rbp, rax                    # object
    mov     rbx, [rbp+OB_MESH]          # source mesh
    test    rbx, rbx
    jz      .Lrp_none
    call    rp_merge
    test    eax, eax
    jz      .Lrp_none
    call    rp_polys
    test    eax, eax
    jz      .Lrp_none
    call    rp_fill
    test    eax, eax
    jz      .Lrp_none
    call    rp_orient
    test    eax, eax
    jz      .Lrp_none
    call    rp_build                    # rax = the new mesh
    test    rax, rax
    jz      .Lrp_none
    mov     r12, rax
    test    r15d, r15d
    jz      4f
    mov     rdi, r12
    call    edit_replace
    jmp     5f
4:  mov     rdi, [rbp+OB_MESH]
    mov     [rbp+OB_MESH], r12
    call    mesh_unref
5:  mov     dword ptr [rip+dirty], 1
    mov     rdi, rbp                    # the report
    call    mesh_analyze
    call    fmt_reset
    lea     rdi, [rip+s_rp_head]
    call    fmt_str
    mov     edi, [rip+rp_cnt]
    call    fmt_int
    lea     rdi, [rip+s_rp_deg]
    call    fmt_str
    mov     edi, [rip+rp_cnt+4]
    call    fmt_int
    lea     rdi, [rip+s_rp_dup]
    call    fmt_str
    mov     edi, [rip+rp_cnt+8]
    call    fmt_int
    lea     rdi, [rip+s_rp_holes]
    call    fmt_str
    mov     edi, [rip+rp_cnt+12]
    call    fmt_int
    lea     rdi, [rip+s_rp_flip]
    call    fmt_str
    mov     edi, [rip+rp_cnt+16]
    call    fmt_int
    lea     rdi, [rip+s_rp_loose]
    call    fmt_str
    mov     edi, [rip+rp_cnt+20]
    call    fmt_int
    lea     rdi, [rip+s_rp_tail]
    call    fmt_str
    lea     rdi, [rip+s_rp_closed]
    mov     eax, [rip+an_res]
    or      eax, [rip+an_res+4]
    jz      6f
    lea     rdi, [rip+s_rp_open]
6:  call    fmt_str
    lea     rdi, [rip+fmt_buf]
    call    log_line
    jmp     9f
.Lrp_none:
    lea     rdi, [rip+s_rp_none]
    call    log_line
    call    undo_drop_last
9:  add     rsp, 56
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# mesh_merge_dist(rdi=finished mesh, xmm0=distance) -> rax = a copy with
#   points closer than the distance welded (faces that collapse dropped), or 0
mesh_merge_dist:
    push    rbx
    push    rbp
    sub     rsp, 40
    mov     rbx, rdi
    movss   [rip+rp_dist], xmm0
    lea     rdi, [rip+rp_cnt]
    xor     eax, eax
    mov     ecx, 8
    rep     stosd
    call    rp_merge
    test    eax, eax
    jz      8f
    call    rp_polys
    test    eax, eax
    jz      8f
    call    rp_build
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 40
    pop     rbp
    pop     rbx
    ret

# mesh_clean(rdi=finished mesh) -> rax = a repaired copy (vertices at one
#   place welded - 1e-4 of the size -, degenerate and duplicate faces gone,
#   holes filled, normals consistent), or 0. Feature booleans run it so the
#   next boolean sees no slivers (which no perturbation can orient).
mesh_clean:
    push    rbx
    push    rbp
    sub     rsp, 40
    mov     rbx, rdi
    lea     rdi, [rip+rp_cnt]
    xor     eax, eax
    mov     ecx, 8
    rep     stosd
    movss   xmm0, [rbx+ME_BMAX]         # the distance: 1e-6 of the size
    subss   xmm0, [rbx+ME_BMIN]
    movss   xmm1, [rbx+ME_BMAX+4]
    subss   xmm1, [rbx+ME_BMIN+4]
    maxss   xmm0, xmm1
    movss   xmm1, [rbx+ME_BMAX+8]
    subss   xmm1, [rbx+ME_BMIN+8]
    maxss   xmm0, xmm1
    mulss   xmm0, [rip+mc_rel]
    movss   [rip+rp_dist], xmm0
    call    rp_merge
    test    eax, eax
    jz      8f
    call    rp_polys
    test    eax, eax
    jz      8f
    call    rp_fill
    test    eax, eax
    jz      8f
    call    rp_orient
    test    eax, eax
    jz      8f
    call    rp_build
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 40
    pop     rbp
    pop     rbx
    ret

# rp_merge(rbx=mesh) -> eax = 1: rp_rep = representative of each vertex
#   (the first one within rp_dist); rp_cnt[0] = merged, rp_cnt[5] = loose
rp_merge:
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 56
    mov     edi, [rbx+ME_NVERTS]
    lea     edi, [rdi*4+8]
    call    fa
    test    rax, rax
    jz      .Lrm_fail
    mov     [rip+rp_rep], rax
    mov     edi, [rbx+ME_NVERTS]
    lea     edi, [rdi*4+8]
    call    fa
    test    rax, rax
    jz      .Lrm_fail
    mov     [rip+rp_next], rax
    mov     edi, [rbx+ME_NVERTS]        # cell -> first vertex
    add     edi, 8
    call    eh_new
    test    rax, rax
    jz      .Lrm_fail
    mov     r12, rax
    mov     edi, [rbx+ME_NVERTS]        # loose: used by no face
    add     edi, 8
    call    fa
    test    rax, rax
    jz      .Lrm_fail
    mov     [rip+rp_used], rax
    mov     rcx, [rbx+ME_LOOPS]
    xor     edx, edx
1:  cmp     edx, [rbx+ME_NLOOPS]
    jae     2f
    mov     r8d, [rcx+rdx*4]
    mov     byte ptr [rax+r8], 1
    inc     edx
    jmp     1b
2:  xor     edx, edx
3:  cmp     edx, [rbx+ME_NVERTS]
    jae     4f
    cmp     byte ptr [rax+rdx], 0
    jne     31f
    inc     dword ptr [rip+rp_cnt+20]
31: inc     edx
    jmp     3b
4:  movss   xmm7, [rip+rp_dist]         # 1 / cell size
    xorps   xmm6, xmm6
    comiss  xmm7, xmm6
    ja      41f
    xor     ecx, ecx                    # no distance: every vertex itself
    mov     rax, [rip+rp_rep]
42: cmp     ecx, [rbx+ME_NVERTS]
    jae     .Lrm_ok
    mov     [rax+rcx*4], ecx
    inc     ecx
    jmp     42b
41: movss   xmm6, [rip+an_fone]
    divss   xmm6, xmm7
    movss   [rsp+48], xmm6
    xor     r13d, r13d                  # vertex
.Lrm_v:
    cmp     r13d, [rbx+ME_NVERTS]
    jae     .Lrm_ok
    mov     rax, [rip+rp_rep]
    mov     [rax+r13*4], r13d
    mov     rax, [rbx+ME_POS]           # its cell
    lea     rcx, [r13+r13*2]
    lea     r14, [rax+rcx*4]
    xor     ecx, ecx
5:  movss   xmm0, [r14+rcx*4]
    mulss   xmm0, [rsp+48]
    roundss xmm0, xmm0, 1               # floor
    cvtss2si eax, xmm0
    mov     [rsp+rcx*4], eax
    inc     ecx
    cmp     ecx, 3
    jb      5b
    mov     dword ptr [rsp+16], -1      # 27 neighbours: an earlier vertex
.Lrm_nb:                                #  within the distance?
    inc     dword ptr [rsp+16]
    cmp     dword ptr [rsp+16], 27
    jae     .Lrm_insert
    mov     eax, [rsp+16]
    xor     edx, edx
    mov     ecx, 3
    div     ecx                         # dx = edx - 1
    lea     r8d, [rdx-1]
    xor     edx, edx
    div     ecx
    lea     r9d, [rdx-1]
    lea     r10d, [rax-1]
    add     r8d, [rsp]
    add     r9d, [rsp+4]
    add     r10d, [rsp+8]
    call    cell_key
    lea     rsi, [rax+1]
    mov     rdi, r12
    call    an_get
6:  test    eax, eax
    js      .Lrm_nb
    mov     r15d, eax                   # a candidate
    mov     rcx, [rbx+ME_POS]
    lea     rdx, [r15+r15*2]
    movss   xmm0, [rcx+rdx*4]
    subss   xmm0, [r14]
    mulss   xmm0, xmm0
    movss   xmm1, [rcx+rdx*4+4]
    subss   xmm1, [r14+4]
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    movss   xmm1, [rcx+rdx*4+8]
    subss   xmm1, [r14+8]
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    movss   xmm1, [rip+rp_dist]
    mulss   xmm1, xmm1
    comiss  xmm0, xmm1
    ja      7f
    mov     rax, [rip+rp_rep]           # merge into its representative
    mov     ecx, [rax+r15*4]
    mov     [rax+r13*4], ecx
    inc     dword ptr [rip+rp_cnt]
    jmp     .Lrm_next                   # (merged ones need no cell)
7:  mov     rax, [rip+rp_next]
    mov     eax, [rax+r15*4]
    jmp     6b
.Lrm_insert:
    mov     r8d, [rsp]
    mov     r9d, [rsp+4]
    mov     r10d, [rsp+8]
    call    cell_key
    mov     rsi, rax
    mov     rdi, r12
    call    eh_slot
    mov     ecx, [rax]                  # -1 when new
    mov     rdx, [rip+rp_next]
    mov     [rdx+r13*4], ecx
    mov     [rax], r13d
.Lrm_next:
    inc     r13d
    jmp     .Lrm_v
.Lrm_ok:
    mov     eax, 1
    jmp     9f
.Lrm_fail:
    xor     eax, eax
9:  add     rsp, 56
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    ret

# cell_key(r8d, r9d, r10d = cell x y z) -> rax (21 bits each)
cell_key:
    mov     eax, r10d
    and     eax, 0x1fffff
    shl     rax, 21
    mov     ecx, r9d
    and     ecx, 0x1fffff
    or      rax, rcx
    shl     rax, 21
    mov     ecx, r8d
    and     ecx, 0x1fffff
    or      rax, rcx
    ret

# rp_polys(rbx=mesh) -> eax = 1: the polygons through rp_rep, corners that
#   repeat dropped, faces without area dropped (rp_cnt[1]), duplicates
#   dropped (rp_cnt[2]: the same face twice keeps one, two opposite ones
#   cancel)
rp_polys:
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 56
    mov     eax, [rbx+ME_NPOLYS]        # room: the faces, then the holes
    lea     eax, [rax*2+16]
    add     eax, [rbx+ME_NEDGES]
    mov     [rip+rp_capp], eax
    mov     eax, [rbx+ME_NLOOPS]
    add     eax, eax
    add     eax, 64
    mov     [rip+rp_capl], eax
    mov     edi, [rip+rp_capp]
    lea     edi, [rdi*4+8]
    call    fa
    test    rax, rax
    jz      .Lrq_fail
    mov     [rip+rp_poff], rax
    mov     edi, [rip+rp_capl]
    shl     edi, 2
    call    fa
    test    rax, rax
    jz      .Lrq_fail
    mov     [rip+rp_loops], rax
    mov     edi, [rip+rp_capp]
    call    fa
    test    rax, rax
    jz      .Lrq_fail
    mov     [rip+rp_dead], rax
    mov     edi, [rip+rp_capp]
    call    fa
    test    rax, rax
    jz      .Lrq_fail
    mov     [rip+rp_flip], rax
    mov     dword ptr [rip+rp_np], 0
    mov     dword ptr [rip+rp_nl], 0
    xor     r12d, r12d                  # source polygon
.Lrq_poly:
    cmp     r12d, [rbx+ME_NPOLYS]
    jae     .Lrq_dups
    mov     rax, [rbx+ME_POFF]
    mov     r13d, [rax+r12*4]
    mov     r14d, [rax+r12*4+4]
    mov     r15d, [rip+rp_nl]           # start of the new one
    mov     rax, [rip+rp_poff]
    mov     ecx, [rip+rp_np]
    mov     [rax+rcx*4], r15d
1:  cmp     r13d, r14d
    jae     2f
    mov     rax, [rbx+ME_LOOPS]
    mov     eax, [rax+r13*4]
    mov     rcx, [rip+rp_rep]
    mov     eax, [rcx+rax*4]
    mov     ecx, [rip+rp_nl]            # same as the previous corner: skip
    cmp     ecx, r15d
    je      11f
    mov     rdx, [rip+rp_loops]
    cmp     [rdx+rcx*4-4], eax
    je      12f
11: mov     rdx, [rip+rp_loops]
    mov     [rdx+rcx*4], eax
    inc     dword ptr [rip+rp_nl]
12: inc     r13d
    jmp     1b
2:  mov     ecx, [rip+rp_nl]            # last = first: drop the last
    mov     edx, ecx
    sub     edx, r15d
    cmp     edx, 2
    jb      21f
    mov     rdx, [rip+rp_loops]
    mov     eax, [rdx+rcx*4-4]
    cmp     eax, [rdx+r15*4]
    jne     21f
    dec     dword ptr [rip+rp_nl]
21: mov     eax, [rip+rp_nl]            # fewer than 3: degenerate
    sub     eax, r15d
    cmp     eax, 3
    jb      .Lrq_drop
    mov     edi, r15d                   # no area: degenerate
    mov     esi, [rip+rp_nl]
    call    rp_area_ok
    test    eax, eax
    jz      .Lrq_drop
    inc     dword ptr [rip+rp_np]
    mov     rax, [rip+rp_poff]
    mov     ecx, [rip+rp_np]
    mov     edx, [rip+rp_nl]
    mov     [rax+rcx*4], edx
    jmp     .Lrq_next
.Lrq_drop:
    mov     [rip+rp_nl], r15d
    inc     dword ptr [rip+rp_cnt+4]
.Lrq_next:
    inc     r12d
    jmp     .Lrq_poly
.Lrq_dups:
    mov     edi, [rip+rp_np]            # duplicates by their corner cycles
    add     edi, 8
    call    eh_new
    test    rax, rax
    jz      .Lrq_fail
    mov     r12, rax
    xor     r13d, r13d
3:  cmp     r13d, [rip+rp_np]
    jae     .Lrq_ok
    mov     edi, r13d
    xor     esi, esi
    call    rp_cyc
    mov     [rsp], rax
    mov     rdi, r12                    # the same one before: drop this
    lea     rsi, [rax+1]
    call    an_get
    test    eax, eax
    js      31f
    mov     rcx, [rip+rp_dead]
    cmp     byte ptr [rcx+rax], 0
    jne     31f
    mov     byte ptr [rcx+r13], 1
    inc     dword ptr [rip+rp_cnt+8]
    jmp     33f
31: mov     edi, r13d                   # its opposite before: drop both
    mov     esi, 1
    call    rp_cyc
    lea     rsi, [rax+1]
    mov     rdi, r12
    call    an_get
    test    eax, eax
    js      32f
    mov     rcx, [rip+rp_dead]
    cmp     byte ptr [rcx+rax], 0
    jne     32f
    mov     byte ptr [rcx+rax], 1
    mov     byte ptr [rcx+r13], 1
    add     dword ptr [rip+rp_cnt+8], 2
    jmp     33f
32: mov     rsi, [rsp]
    mov     rdi, r12
    call    eh_slot
    mov     [rax], r13d
33: inc     r13d
    jmp     3b
.Lrq_ok:
    mov     eax, 1
    jmp     9f
.Lrq_fail:
    xor     eax, eax
9:  add     rsp, 56
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    ret

# rp_area_ok(edi=first loop, esi=end loop in rp_loops; rbx = mesh) -> eax =
#   1 if the corners enclose an area (Newell, against the size)
rp_area_ok:
    mov     r8, [rip+rp_loops]
    mov     r10, [rbx+ME_POS]
    xorps   xmm0, xmm0
    xorps   xmm1, xmm1
    xorps   xmm2, xmm2
    mov     ecx, edi
1:  cmp     ecx, esi
    jae     2f
    mov     eax, [r8+rcx*4]
    lea     eax, [rax+rax*2]
    lea     edx, [rcx+1]
    cmp     edx, esi
    jb      11f
    mov     edx, edi
11: mov     edx, [r8+rdx*4]
    lea     edx, [rdx+rdx*2]
    movss   xmm6, [r10+rax*4+4]
    subss   xmm6, [r10+rdx*4+4]
    movss   xmm7, [r10+rax*4+8]
    addss   xmm7, [r10+rdx*4+8]
    mulss   xmm6, xmm7
    addss   xmm0, xmm6
    movss   xmm6, [r10+rax*4+8]
    subss   xmm6, [r10+rdx*4+8]
    movss   xmm7, [r10+rax*4]
    addss   xmm7, [r10+rdx*4]
    mulss   xmm6, xmm7
    addss   xmm1, xmm6
    movss   xmm6, [r10+rax*4]
    subss   xmm6, [r10+rdx*4]
    movss   xmm7, [r10+rax*4+4]
    addss   xmm7, [r10+rdx*4+4]
    mulss   xmm6, xmm7
    addss   xmm2, xmm6
    inc     ecx
    jmp     1b
2:  mulss   xmm0, xmm0
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    mulss   xmm2, xmm2
    addss   xmm0, xmm2
    movss   xmm1, [rbx+ME_BMAX]
    subss   xmm1, [rbx+ME_BMIN]
    mulss   xmm1, xmm1
    movss   xmm2, [rbx+ME_BMAX+4]
    subss   xmm2, [rbx+ME_BMIN+4]
    mulss   xmm2, xmm2
    addss   xmm1, xmm2
    movss   xmm2, [rbx+ME_BMAX+8]
    subss   xmm2, [rbx+ME_BMIN+8]
    mulss   xmm2, xmm2
    addss   xmm1, xmm2
    mulss   xmm1, xmm1
    mulss   xmm1, [rip+an_feps]
    xor     eax, eax
    comiss  xmm0, xmm1
    jbe     9f
    mov     eax, 1
9:  ret

# rp_cyc(edi=new polygon, esi=1 reversed) -> rax = hash of its corners from
#   the smallest one (bit 63 clear)
rp_cyc:
    mov     r8, [rip+rp_poff]
    mov     r9, [rip+rp_loops]
    mov     ecx, [r8+rdi*4]
    mov     r10d, [r8+rdi*4+4]
    sub     r10d, ecx
    lea     r9, [r9+rcx*4]
    xor     ecx, ecx
    xor     edx, edx
1:  cmp     edx, r10d
    jae     2f
    mov     eax, [r9+rdx*4]
    cmp     eax, [r9+rcx*4]
    jae     11f
    mov     ecx, edx
11: inc     edx
    jmp     1b
2:  mov     rax, 0xcbf29ce484222325
    xor     rax, r10
    xor     edx, edx
3:  cmp     edx, r10d
    jae     9f
    mov     r11d, ecx
    test    esi, esi
    jnz     4f
    add     r11d, edx
    jmp     5f
4:  sub     r11d, edx
    add     r11d, r10d
5:  cmp     r11d, r10d
    jb      6f
    sub     r11d, r10d
6:  mov     r11d, [r9+r11*4]
    xor     rax, r11
    mov     r11, 0x100000001b3
    imul    rax, r11
    inc     edx
    jmp     3b
9:  shr     rax, 1
    ret

# rp_fill(rbx=mesh) -> eax = 1: every closed loop of boundary edges (an edge
#   that one face uses) becomes a face (rp_cnt[3])
rp_fill:
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 48
    mov     edi, [rip+rp_nl]            # edges and how many faces use them
    add     edi, 8
    call    eh_new
    test    rax, rax
    jz      .Lrf_fail
    mov     r12, rax
    xor     r13d, r13d
1:  cmp     r13d, [rip+rp_np]
    jae     2f
    mov     edi, r13d
    mov     rsi, r12
    lea     rdx, [rip+rf_add]
    call    rp_each_edge
    inc     r13d
    jmp     1b
2:  mov     edi, [rip+rp_nl]            # boundary edges a -> b by their b,
    add     edi, 8                      #  chained (rf_next)
    call    eh_new
    test    rax, rax
    jz      .Lrf_fail
    mov     r13, rax
    mov     edi, [rip+rp_nl]
    lea     edi, [rdi*4+8]
    call    fa
    test    rax, rax
    jz      .Lrf_fail
    mov     [rip+rf_ba], rax            # boundary edge: a
    mov     edi, [rip+rp_nl]
    lea     edi, [rdi*4+8]
    call    fa
    test    rax, rax
    jz      .Lrf_fail
    mov     [rip+rf_bb], rax            # b
    mov     edi, [rip+rp_nl]
    lea     edi, [rdi*4+8]
    call    fa
    test    rax, rax
    jz      .Lrf_fail
    mov     [rip+rf_bnext], rax         # next with the same b
    mov     edi, [rip+rp_nl]
    add     edi, 8
    call    fa
    test    rax, rax
    jz      .Lrf_fail
    mov     [rip+rf_bused], rax
    mov     dword ptr [rip+rf_nb], 0
    mov     [rip+rf_tab], r12
    mov     [rip+rf_btab], r13
    xor     r14d, r14d
3:  cmp     r14d, [rip+rp_np]
    jae     4f
    mov     edi, r14d
    mov     rsi, r12
    lea     rdx, [rip+rf_bound]
    call    rp_each_edge
    inc     r14d
    jmp     3b
4:  xor     r14d, r14d                  # loops: b, a, then the a' of the
.Lrf_loop:                              #  boundary edge a' -> a, ...
    cmp     r14d, [rip+rf_nb]
    jae     .Lrf_ok
    mov     rax, [rip+rf_bused]
    cmp     byte ptr [rax+r14], 0
    jne     .Lrf_lnext
    mov     byte ptr [rax+r14], 1
    mov     r15d, [rip+rp_nl]           # the hole's corners go to the end
    mov     ebp, r15d
    mov     rax, [rip+rf_bb]
    mov     ecx, [rax+r14*4]
    mov     [rsp], ecx                  # start (b)
    call    rf_push
    test    eax, eax
    jz      .Lrf_fail
    mov     rax, [rip+rf_ba]
    mov     ecx, [rax+r14*4]            # current = a
5:  cmp     ecx, [rsp]
    je      .Lrf_closed
    mov     [rsp+4], ecx
    call    rf_push
    test    eax, eax
    jz      .Lrf_fail
    mov     eax, [rip+rp_nl]            # runaway: give up on this one
    sub     eax, ebp
    cmp     eax, 100000
    ja      .Lrf_abandon
    mov     edi, [rsp+4]                # an unused boundary edge x -> current
    call    rf_take
    test    eax, eax
    js      .Lrf_abandon
    mov     ecx, eax                    # x
    jmp     5b
.Lrf_closed:
    mov     eax, [rip+rp_nl]
    sub     eax, ebp
    cmp     eax, 3
    jb      .Lrf_abandon
    mov     eax, [rip+rp_np]            # a face
    cmp     eax, [rip+rp_capp]
    jae     .Lrf_abandon
    inc     dword ptr [rip+rp_np]
    mov     rcx, [rip+rp_poff]
    mov     edx, [rip+rp_nl]
    mov     [rcx+rax*4+4], edx
    inc     dword ptr [rip+rp_cnt+12]
    jmp     .Lrf_lnext
.Lrf_abandon:
    mov     [rip+rp_nl], ebp
.Lrf_lnext:
    inc     r14d
    jmp     .Lrf_loop
.Lrf_ok:
    mov     eax, 1
    jmp     9f
.Lrf_fail:
    xor     eax, eax
9:  add     rsp, 48
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    ret

# rf_push(ecx=vertex) -> eax = 1 (appended to rp_loops)
rf_push:
    mov     eax, [rip+rp_nl]
    cmp     eax, [rip+rp_capl]
    jae     1f
    mov     rdx, [rip+rp_loops]
    mov     [rdx+rax*4], ecx
    inc     dword ptr [rip+rp_nl]
    mov     eax, 1
    ret
1:  xor     eax, eax
    ret

# rf_take(edi=vertex) -> eax = the a of an unused boundary edge a -> vertex
#   (marked used), or -1
rf_take:
    push    rbx
    mov     ebx, edi
    mov     esi, ebx
    mov     rdi, [rip+rf_btab]
    lea     rsi, [rsi+1]
    call    an_get
1:  test    eax, eax
    js      9f
    mov     rcx, [rip+rf_bused]
    cmp     byte ptr [rcx+rax], 0
    je      2f
    mov     rcx, [rip+rf_bnext]
    mov     eax, [rcx+rax*4]
    jmp     1b
2:  mov     byte ptr [rcx+rax], 1
    mov     rcx, [rip+rf_ba]
    mov     eax, [rcx+rax*4]
9:  pop     rbx
    ret

# rp_each_edge(edi=new polygon, rsi=table, rdx=callback(edi=a, esi=b,
#   rdx=table)) - for its edges a -> b (skipping dead polygons)
rp_each_edge:
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbx
    mov     rax, [rip+rp_dead]
    cmp     byte ptr [rax+rdi], 0
    jne     9f
    mov     r12, rsi
    mov     r13, rdx
    mov     rax, [rip+rp_poff]
    mov     r14d, [rax+rdi*4]
    mov     r15d, [rax+rdi*4+4]
    mov     ebx, r14d
1:  cmp     ebx, r15d
    jae     9f
    mov     rax, [rip+rp_loops]
    mov     edi, [rax+rbx*4]
    lea     ecx, [rbx+1]
    cmp     ecx, r15d
    jb      2f
    mov     ecx, r14d
2:  mov     esi, [rax+rcx*4]
    mov     rdx, r12
    call    r13
    inc     ebx
    jmp     1b
9:  pop     rbx
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    ret

rf_add:                                 # (a, b): count the faces of the edge
    push    rbx
    mov     rbx, rdx
    call    ukey
    mov     rsi, rax
    mov     rdi, rbx
    call    eh_slot
    test    edx, edx
    jnz     1f
    mov     dword ptr [rax], 0
1:  inc     dword ptr [rax]
    pop     rbx
    ret

rf_bound:                               # (a, b): boundary if one face only
    push    rbx
    push    r12
    push    r13
    mov     ebx, edi
    mov     r12d, esi
    mov     r13, rdx
    call    ukey
    lea     rsi, [rax+1]
    mov     rdi, r13
    call    an_get
    cmp     eax, 1
    jne     9f
    mov     eax, [rip+rf_nb]            # a boundary edge a -> b
    cmp     eax, [rip+rp_nl]
    jae     9f
    mov     rcx, [rip+rf_ba]
    mov     [rcx+rax*4], ebx
    mov     rcx, [rip+rf_bb]
    mov     [rcx+rax*4], r12d
    inc     dword ptr [rip+rf_nb]
    mov     esi, r12d                   # chained by b
    mov     rdi, [rip+rf_btab]
    push    rax
    sub     rsp, 8
    call    eh_slot
    add     rsp, 8
    pop     rcx
    mov     edx, [rax]
    mov     r8, [rip+rf_bnext]
    mov     [r8+rcx*4], edx
    mov     [rax], ecx
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# rp_orient(rbx=mesh) -> eax = 1: neighbours agree (a face is flipped when
#   it uses a shared edge the same way), then each connected part faces out
#   (positive volume); rp_cnt[4] = faces flipped in the end
rp_orient:
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 48
    mov     edi, [rip+rp_nl]            # undirected edge -> (face, a), 2 slots
    add     edi, 8
    call    eh_new
    test    rax, rax
    jz      .Lro_fail
    mov     r12, rax
    mov     edi, [rip+rp_nl]
    shl     edi, 4
    add     edi, 16
    call    fa_fill_ff
    test    rax, rax
    jz      .Lro_fail
    mov     [rip+ro_slots], rax         # per edge: f1, a1, f2, a2
    mov     dword ptr [rip+ro_ns], 0
    mov     [rip+ro_tab], r12
    xor     r13d, r13d
1:  cmp     r13d, [rip+rp_np]
    jae     2f
    mov     [rip+ro_face], r13d
    mov     edi, r13d
    mov     rsi, r12
    lea     rdx, [rip+ro_add]
    call    rp_each_edge
    inc     r13d
    jmp     1b
2:  mov     edi, [rip+rp_np]            # component per face, BFS
    lea     edi, [rdi*4+8]
    call    fa_fill_ff
    test    rax, rax
    jz      .Lro_fail
    mov     [rip+ro_comp], rax
    mov     edi, [rip+rp_np]
    lea     edi, [rdi*4+8]
    call    fa
    test    rax, rax
    jz      .Lro_fail
    mov     [rip+ro_stack], rax
    mov     dword ptr [rip+ro_nc], 0
    xor     r13d, r13d                  # seed
.Lro_seed:
    cmp     r13d, [rip+rp_np]
    jae     .Lro_volume
    mov     rax, [rip+rp_dead]
    cmp     byte ptr [rax+r13], 0
    jne     .Lro_snext
    mov     rax, [rip+ro_comp]
    cmp     dword ptr [rax+r13*4], -1
    jne     .Lro_snext
    mov     ecx, [rip+ro_nc]
    mov     [rax+r13*4], ecx
    inc     dword ptr [rip+ro_nc]
    mov     rax, [rip+ro_stack]
    mov     [rax], r13d
    mov     r14d, 1
3:  test    r14d, r14d
    jz      .Lro_snext
    dec     r14d
    mov     rax, [rip+ro_stack]
    mov     r15d, [rax+r14*4]           # face
    mov     [rip+ro_face], r15d
    mov     [rip+ro_depth], r14d
    mov     edi, r15d
    mov     rsi, r12
    lea     rdx, [rip+ro_visit]
    call    rp_each_edge
    mov     r14d, [rip+ro_depth]
    jmp     3b
.Lro_snext:
    inc     r13d
    jmp     .Lro_seed
.Lro_volume:                            # per component: signed volume
    mov     edi, [rip+ro_nc]
    shl     edi, 3
    add     edi, 16
    call    fa
    test    rax, rax
    jz      .Lro_fail
    mov     [rip+ro_vol], rax
    xor     r13d, r13d
4:  cmp     r13d, [rip+rp_np]
    jae     5f
    mov     rax, [rip+rp_dead]
    cmp     byte ptr [rax+r13], 0
    jne     41f
    mov     edi, r13d
    call    rp_volume                   # xmm0 (double), as currently oriented
    mov     rax, [rip+ro_comp]
    mov     ecx, [rax+r13*4]
    mov     rax, [rip+ro_vol]
    addsd   xmm0, [rax+rcx*8]
    movsd   [rax+rcx*8], xmm0
41: inc     r13d
    jmp     4b
5:  xor     r13d, r13d                  # inward parts flip; count the flips
6:  cmp     r13d, [rip+rp_np]
    jae     .Lro_ok
    mov     rax, [rip+rp_dead]
    cmp     byte ptr [rax+r13], 0
    jne     61f
    mov     rax, [rip+ro_comp]
    mov     ecx, [rax+r13*4]
    mov     rax, [rip+ro_vol]
    xorpd   xmm1, xmm1
    movsd   xmm0, [rax+rcx*8]
    comisd  xmm0, xmm1
    jae     62f
    mov     rax, [rip+rp_flip]
    xor     byte ptr [rax+r13], 1
62: mov     rax, [rip+rp_flip]
    cmp     byte ptr [rax+r13], 0
    je      61f
    inc     dword ptr [rip+rp_cnt+16]
61: inc     r13d
    jmp     6b
.Lro_ok:
    mov     eax, 1
    jmp     9f
.Lro_fail:
    xor     eax, eax
9:  add     rsp, 48
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    ret

# fa_fill_ff(edi=bytes) -> rax = frame-arena memory filled with 0xff
fa_fill_ff:
    push    rbx
    mov     ebx, edi
    call    fa
    test    rax, rax
    jz      9f
    push    rax
    mov     rdi, rax
    mov     ecx, ebx
    mov     al, 0xff
    rep     stosb
    pop     rax
9:  pop     rbx
    ret

ro_add:                                 # (a, b) of ro_face: into its slot
    push    rbx
    push    r12
    sub     rsp, 8
    mov     ebx, edi
    mov     r12d, esi
    call    ukey
    mov     rsi, rax
    mov     rdi, rdx
    call    eh_slot
    test    edx, edx
    jnz     1f
    mov     ecx, [rip+ro_ns]
    mov     [rax], ecx
    inc     dword ptr [rip+ro_ns]
1:  mov     ecx, [rax]
    shl     rcx, 4
    add     rcx, [rip+ro_slots]
    cmp     dword ptr [rcx], -1
    jne     2f
    mov     edx, [rip+ro_face]
    mov     [rcx], edx
    mov     [rcx+4], ebx
    jmp     9f
2:  cmp     dword ptr [rcx+8], -1       # (more than two: ignored)
    jne     9f
    mov     edx, [rip+ro_face]
    mov     [rcx+8], edx
    mov     [rcx+12], ebx
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

ro_visit:                               # (a, b) of ro_face: the neighbour
    push    rbx                         #  across, oriented to agree
    push    r12
    push    r13
    mov     ebx, edi
    mov     r12d, esi
    call    ukey
    lea     rsi, [rax+1]
    mov     rdi, [rip+ro_tab]
    call    an_get
    test    eax, eax
    js      9f
    shl     rax, 4
    add     rax, [rip+ro_slots]
    mov     ecx, [rax]                  # the other face of this edge
    mov     edx, [rax+4]
    cmp     ecx, [rip+ro_face]
    jne     1f
    mov     ecx, [rax+8]
    mov     edx, [rax+12]
1:  test    ecx, ecx
    js      9f
    mov     r13d, ecx
    mov     r8, [rip+ro_comp]
    cmp     dword ptr [r8+r13*4], -1
    jne     9f
    mov     r9d, [rip+ro_face]          # component of ro_face
    mov     r9d, [r8+r9*4]
    mov     [r8+r13*4], r9d
    # this face, as it will be emitted, walks a -> b when not flipped; the
    #   neighbour stored its own edge start (edx). They agree when the
    #   neighbour (as emitted) walks b -> a.
    mov     r10, [rip+rp_flip]
    mov     r11d, [rip+ro_face]
    movzx   eax, byte ptr [r10+r11]     # this face flipped?
    xor     esi, esi                    # this walks a -> b (as stored: ebx)
    cmp     edx, ebx                    # neighbour stored a -> b too?
    jne     2f
    mov     esi, 1
2:  xor     eax, esi                    # same way (after flips) -> flip it
    mov     [r10+r13], al
    mov     rax, [rip+ro_stack]
    mov     ecx, [rip+ro_depth]
    mov     [rax+rcx*4], r13d
    inc     dword ptr [rip+ro_depth]
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# rp_volume(edi=new polygon; rbx = mesh) -> xmm0 = its share of the signed
#   volume (fan, double), negated when it is flipped
rp_volume:
    mov     r8, [rip+rp_poff]
    mov     r9, [rip+rp_loops]
    mov     r10, [rbx+ME_POS]
    mov     ecx, [r8+rdi*4]
    mov     r11d, [r8+rdi*4+4]
    mov     eax, [r9+rcx*4]             # v0
    lea     eax, [rax+rax*2]
    xorpd   xmm0, xmm0
    lea     edx, [rcx+1]
1:  lea     esi, [rdx+1]
    cmp     esi, r11d
    jae     2f
    push    rdi
    mov     edi, [r9+rdx*4]
    lea     edi, [rdi+rdi*2]
    mov     esi, [r9+rsi*4]
    lea     esi, [rsi+rsi*2]
    # v0 . (v1 x v2)
    cvtss2sd xmm1, [r10+rdi*4+4]
    cvtss2sd xmm2, [r10+rsi*4+8]
    mulsd   xmm1, xmm2
    cvtss2sd xmm2, [r10+rdi*4+8]
    cvtss2sd xmm3, [r10+rsi*4+4]
    mulsd   xmm2, xmm3
    subsd   xmm1, xmm2
    cvtss2sd xmm2, [r10+rax*4]
    mulsd   xmm1, xmm2
    cvtss2sd xmm4, [r10+rdi*4+8]
    cvtss2sd xmm2, [r10+rsi*4]
    mulsd   xmm4, xmm2
    cvtss2sd xmm2, [r10+rdi*4]
    cvtss2sd xmm3, [r10+rsi*4+8]
    mulsd   xmm2, xmm3
    subsd   xmm4, xmm2
    cvtss2sd xmm2, [r10+rax*4+4]
    mulsd   xmm4, xmm2
    addsd   xmm1, xmm4
    cvtss2sd xmm4, [r10+rdi*4]
    cvtss2sd xmm2, [r10+rsi*4+4]
    mulsd   xmm4, xmm2
    cvtss2sd xmm2, [r10+rdi*4+4]
    cvtss2sd xmm3, [r10+rsi*4]
    mulsd   xmm2, xmm3
    subsd   xmm4, xmm2
    cvtss2sd xmm2, [r10+rax*4+8]
    mulsd   xmm4, xmm2
    addsd   xmm1, xmm4
    addsd   xmm0, xmm1
    pop     rdi
    inc     edx
    jmp     1b
2:  mov     rax, [rip+rp_flip]
    cmp     byte ptr [rax+rdi], 0
    je      3f
    xorpd   xmm1, xmm1
    subsd   xmm1, xmm0
    movapd  xmm0, xmm1
3:  ret

# rp_build(rbx=mesh) -> rax = the repaired mesh (finished, compacted)
rp_build:
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    mov     edi, [rbx+ME_NVERTS]
    mov     esi, [rip+rp_nl]
    add     esi, 8
    mov     edx, [rip+rp_np]
    add     edx, 8
    call    mesh_new
    test    rax, rax
    jz      9f
    mov     r12, rax
    xor     r13d, r13d                  # every vertex (unused ones go away)
1:  cmp     r13d, [rbx+ME_NVERTS]
    jae     2f
    mov     rax, [rbx+ME_POS]
    lea     rcx, [r13+r13*2]
    movss   xmm0, [rax+rcx*4]
    movss   xmm1, [rax+rcx*4+4]
    movss   xmm2, [rax+rcx*4+8]
    mov     rdi, r12
    call    mesh_add_vert
    inc     r13d
    jmp     1b
2:  xor     r13d, r13d                  # the live polygons, flipped ones
3:  cmp     r13d, [rip+rp_np]           #  reversed
    jae     6f
    mov     rax, [rip+rp_dead]
    cmp     byte ptr [rax+r13], 0
    jne     5f
    mov     rax, [rip+rp_poff]
    mov     ecx, [rax+r13*4]
    mov     edx, [rax+r13*4+4]
    mov     rsi, [rip+rp_loops]
    lea     rdi, [rip+scr]
    xor     r8d, r8d
    mov     r9, [rip+rp_flip]
    cmp     byte ptr [r9+r13], 0
    jne     41f
4:  cmp     ecx, edx                    # forward
    jae     45f
    cmp     r8d, SCR_MAX
    jae     5f
    mov     eax, [rsi+rcx*4]
    mov     [rdi+r8*4], eax
    inc     r8d
    inc     ecx
    jmp     4b
41: cmp     edx, ecx                    # backward
    jbe     45f
    cmp     r8d, SCR_MAX
    jae     5f
    dec     edx
    mov     eax, [rsi+rdx*4]
    mov     [rdi+r8*4], eax
    inc     r8d
    jmp     41b
45: mov     rsi, rdi
    mov     rdi, r12
    mov     edx, r8d
    call    mesh_add_poly
5:  inc     r13d
    jmp     3b
6:  mov     rdi, r12
    call    mesh_finish
    mov     rdi, r12
    call    mesh_compact
9:  add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    ret

.section .bss
.align 8
rf_tab:         .skip 8
rf_btab:        .skip 8
rf_ba:          .skip 8
rf_bb:          .skip 8
rf_bnext:       .skip 8
rf_bused:       .skip 8
rf_nb:          .skip 4
.align 8
ro_tab:         .skip 8
ro_slots:       .skip 8
ro_comp:        .skip 8
ro_stack:       .skip 8
ro_vol:         .skip 8
ro_ns:          .skip 4
ro_nc:          .skip 4
ro_face:        .skip 4
ro_depth:       .skip 4

.section .note.GNU-stack,"",@progbits
