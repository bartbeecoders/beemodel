# =============================================================================
#  BeeModel - sketch objects: creation, editing helpers, display, files
#
#  A sketch object (OT_SKETCH) carries its sketch block (OB_SKETCH) and a
#  display mesh of 2-point polygons (OB_MESH, rebuilt after each solve) so
#  picking, bounds and the outliner treat it like any object. The viewport
#  draws the entities themselves, coloured by their constraint status:
#  fully constrained light, under-constrained blue, conflicts red.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"

.globl skx_create
.globl skx_get
.globl skx_begin
.globl skx_end
.globl skx_line_xy
.globl skx_circle_xy
.globl skx_arc_xy
.globl skx_rect
.globl skx_draw
.globl cad_rebuild
.globl sketches_write
.globl sketches_read

.equ SK_PLANE,   8
.equ SK_NPT,     12
.equ SK_NENT,    16
.equ SK_NCON,    20
.equ SK_DOF,     24
.equ SK_NBAD,    28
.equ SK_OFFSET,  32
.equ SK_PTS,     64
.equ PT_SZ,      24
.equ SK_ENTS,    SK_PTS + 256*PT_SZ
.equ EN_SZ,      32
.equ EN_TYPE,    0
.equ EN_P0,      4
.equ EN_P1,      8
.equ EN_P2,      12
.equ EN_R,       16
.equ EN_FLAGS,   24
.equ SK_SZ,      SK_ENTS + 256*EN_SZ + 256*96
.equ F_FULL,     1
.equ F_BAD,      2
.equ F_CONSTR,   4
.equ E_LINE,     1
.equ E_CIRCLE,   2
.equ E_ARC,      3
.equ C_COINCIDENT, 1
.equ C_HORIZONTAL, 2
.equ C_VERTICAL,   3
.equ SEGS,       48                     # segments in a full circle
.equ COL_FULLY,  0xe8eaee
.equ COL_UNDER,  0x5aa9ff
.equ COL_CONFL,  0xff5a5a
.equ COL_IDLE,   0x8a9bb0

.section .rodata
.align 8
xd_zero:        .double 0.0
xd_one:         .double 1.0
xd_2pi:         .double 6.28318530717958647692
s_sketch:       .asciz "Sketch"
.align 4
xf_mark:        .float 0.25             # the origin marker (scene units)

.section .bss
.align 8
xs_m:           .skip 48                # an object's matrix
xs_a:           .skip 12
xs_b:           .skip 12
xs_ids:         .skip 8

.text

# skx_create(rdi=name, esi=plane, xmm0=offset (double)) -> eax = handle or 0
skx_create:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 16
    mov     r12, rdi
    movsd   [rsp], xmm0
    mov     edi, esi
    call    sk_new
    test    rax, rax
    jz      8f
    mov     rbx, rax
    movsd   xmm0, [rsp]
    movsd   [rbx+SK_OFFSET], xmm0
    mov     rdi, rbx
    call    display_mesh
    test    rax, rax
    jz      7f
    mov     rdx, rax
    mov     edi, OT_SKETCH
    mov     rsi, r12
    test    rsi, rsi
    jnz     1f
    lea     rsi, [rip+s_sketch]
1:  call    obj_new
    test    eax, eax
    jz      7f
    mov     r13d, eax
    mov     edi, eax
    call    obj_get
    mov     [rax+OB_SKETCH], rbx
    mov     eax, r13d
    jmp     9f
7:  mov     rdi, rbx
    call    sk_unref
8:  xor     eax, eax
9:  add     rsp, 16
    pop     r13
    pop     r12
    pop     rbx
    ret

# skx_get(rdi=name) -> rax = the sketch object, or 0
skx_get:
    sub     rsp, 8
    call    obj_find
    test    eax, eax
    jz      8f
    mov     edi, eax
    call    obj_get
    test    rax, rax
    jz      8f
    cmp     dword ptr [rax+OB_TYPE], OT_SKETCH
    jne     8f
    cmp     qword ptr [rax+OB_SKETCH], 0
    je      8f
    add     rsp, 8
    ret
8:  xor     eax, eax
    add     rsp, 8
    ret

# skx_begin(rdi=object) -> rax = its sketch, ours to change
skx_begin:
    jmp     sk_own

# skx_end(rdi=object) -> eax = degrees of freedom left: solve, new display
skx_end:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    mov     rdi, rbx
    call    sk_own
    test    rax, rax
    jz      8f
    mov     r12, rax
    mov     rdi, rax
    call    sk_solve
    mov     rdi, r12
    call    display_mesh
    test    rax, rax
    jz      1f
    mov     rdi, [rbx+OB_MESH]
    mov     [rbx+OB_MESH], rax
    call    mesh_unref
1:  mov     dword ptr [rip+dirty], 1
    mov     eax, [r12+SK_DOF]
    jmp     9f
8:  mov     eax, -1
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# skx_line_xy(rdi=sketch, xmm0..3 = x1 y1 x2 y2 doubles) -> eax = entity
skx_line_xy:
    push    rbx
    push    r12
    sub     rsp, 40
    mov     rbx, rdi
    movsd   [rsp], xmm2
    movsd   [rsp+8], xmm3
    call    sk_add_point
    mov     r12d, eax
    movsd   xmm0, [rsp]
    movsd   xmm1, [rsp+8]
    mov     rdi, rbx
    call    sk_add_point
    test    r12d, r12d
    js      8f
    test    eax, eax
    js      8f
    mov     rdi, rbx
    mov     esi, r12d
    mov     edx, eax
    call    sk_add_line
    jmp     9f
8:  mov     eax, -1
9:  add     rsp, 40
    pop     r12
    pop     rbx
    ret

# skx_circle_xy(rdi=sketch, xmm0 cx, xmm1 cy, xmm2 r) -> eax = entity
skx_circle_xy:
    push    rbx
    sub     rsp, 16
    mov     rbx, rdi
    movsd   [rsp], xmm2
    call    sk_add_point
    test    eax, eax
    js      8f
    mov     rdi, rbx
    mov     esi, eax
    movsd   xmm0, [rsp]
    call    sk_add_circle
    jmp     9f
8:  mov     eax, -1
9:  add     rsp, 16
    pop     rbx
    ret

# skx_arc_xy(rdi=sketch, xmm0 cx, xmm1 cy, xmm2 r, xmm3 a0, xmm4 a1 radians)
#   -> eax = entity (counter-clockwise from a0 to a1)
skx_arc_xy:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 64
    mov     rbx, rdi
    movsd   [rsp], xmm0
    movsd   [rsp+8], xmm1
    movsd   [rsp+16], xmm2
    movsd   [rsp+24], xmm3
    movsd   [rsp+32], xmm4
    call    sk_add_point                # centre
    mov     r12d, eax
    lea     rsi, [rsp+24]
    call    arc_end
    mov     rdi, rbx
    call    sk_add_point
    mov     r13d, eax
    lea     rsi, [rsp+32]
    call    arc_end
    mov     rdi, rbx
    call    sk_add_point
    test    r12d, r12d
    js      8f
    test    r13d, r13d
    js      8f
    test    eax, eax
    js      8f
    mov     ecx, eax
    mov     rdi, rbx
    mov     esi, r12d
    mov     edx, r13d
    movsd   xmm0, [rsp+16]
    call    sk_add_arc
    jmp     9f
8:  mov     eax, -1
9:  add     rsp, 64
    pop     r13
    pop     r12
    pop     rbx
    ret
# arc_end(rsi=angle; caller frame +8: cx cy r) -> xmm0, xmm1 = c + r (cos, sin)
arc_end:
    fld     qword ptr [rsi]
    fsincos
    fstp    qword ptr [rsp+8+48]        # cos   (caller's [rsp+40], [rsp+48])
    fstp    qword ptr [rsp+8+40]        # sin
    movsd   xmm0, [rsp+8+48]
    mulsd   xmm0, [rsp+8+16]
    addsd   xmm0, [rsp+8]
    movsd   xmm1, [rsp+8+40]
    mulsd   xmm1, [rsp+8+16]
    addsd   xmm1, [rsp+8+8]
    ret

# skx_rect(rdi=sketch, xmm0 x, xmm1 y, xmm2 w, xmm3 h) -> eax = the first of
#   four lines (bottom, right, top, left) joined at the corners, horizontal
#   and vertical
skx_rect:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 72
    mov     rbx, rdi
    movsd   [rsp], xmm0                 # x0 y0 x1 y1
    movsd   [rsp+8], xmm1
    addsd   xmm0, xmm2
    movsd   [rsp+16], xmm0
    addsd   xmm1, xmm3
    movsd   [rsp+24], xmm1
    mov     r12d, [rbx+SK_NENT]         # the first line
    # bottom (x0,y0)-(x1,y0), right (x1,y0)-(x1,y1), top (x1,y1)-(x0,y1),
    # left (x0,y1)-(x0,y0)
    movsd   xmm0, [rsp]
    movsd   xmm1, [rsp+8]
    movsd   xmm2, [rsp+16]
    movsd   xmm3, [rsp+8]
    mov     rdi, rbx
    call    skx_line_xy
    test    eax, eax
    js      8f
    movsd   xmm0, [rsp+16]
    movsd   xmm1, [rsp+8]
    movsd   xmm2, [rsp+16]
    movsd   xmm3, [rsp+24]
    mov     rdi, rbx
    call    skx_line_xy
    test    eax, eax
    js      8f
    movsd   xmm0, [rsp+16]
    movsd   xmm1, [rsp+24]
    movsd   xmm2, [rsp]
    movsd   xmm3, [rsp+24]
    mov     rdi, rbx
    call    skx_line_xy
    test    eax, eax
    js      8f
    movsd   xmm0, [rsp]
    movsd   xmm1, [rsp+24]
    movsd   xmm2, [rsp]
    movsd   xmm3, [rsp+8]
    mov     rdi, rbx
    call    skx_line_xy
    test    eax, eax
    js      8f
    xor     r13d, r13d                  # corners: end of k = start of k+1
1:  cmp     r13d, 4
    jae     2f
    lea     esi, [r12+r13]              # line k, end point
    mov     edx, 1
    mov     rdi, rbx
    call    sk_ent_point
    mov     r14d, eax
    lea     eax, [r13+1]
    and     eax, 3
    lea     esi, [r12+rax]
    xor     edx, edx
    mov     rdi, rbx
    call    sk_ent_point
    mov     ecx, eax
    mov     rdi, rbx
    mov     esi, C_COINCIDENT
    mov     edx, r14d
    mov     r8d, -1
    xorpd   xmm0, xmm0
    xor     r9d, r9d
    call    sk_add_con
    inc     r13d
    jmp     1b
2:  xor     r13d, r13d                  # horizontal 0, 2; vertical 1, 3
3:  cmp     r13d, 4
    jae     4f
    mov     esi, C_HORIZONTAL
    test    r13d, 1
    jz      31f
    mov     esi, C_VERTICAL
31: lea     edx, [r12+r13]
    mov     ecx, -1
    mov     r8d, -1
    xorpd   xmm0, xmm0
    xor     r9d, r9d
    mov     rdi, rbx
    call    sk_add_con
    inc     r13d
    jmp     3b
4:  mov     eax, r12d
    jmp     9f
8:  mov     eax, -1
9:  add     rsp, 72
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ---- display ----------------------------------------------------------------
# ent_segs(rbx=sketch, r12=entity) -> eax = segments to draw it with
ent_segs:
    mov     eax, 1
    cmp     dword ptr [r12+EN_TYPE], E_LINE
    je      9f
    mov     eax, SEGS
9:  ret

# ent_at(rbx=sketch, r12=entity, ecx=i, edx=segments, rsi=out float[3]) -
#   the i-th of segments + 1 points along the entity, in plane coordinates
ent_at:
    push    r13
    push    r14
    sub     rsp, 56
    mov     r13, rsi
    mov     [rsp+40], ecx
    mov     [rsp+44], edx
    mov     eax, [r12+EN_TYPE]
    cmp     eax, E_LINE
    jne     2f
    mov     eax, [r12+EN_P0]            # a + (b - a) i / n
    test    ecx, ecx
    jz      1f
    mov     eax, [r12+EN_P1]
1:  imul    eax, eax, PT_SZ
    movsd   xmm0, [rbx+SK_PTS+rax]
    movsd   xmm1, [rbx+SK_PTS+rax+8]
    jmp     8f
2:  mov     eax, [r12+EN_P0]            # centre
    imul    eax, eax, PT_SZ
    movsd   xmm0, [rbx+SK_PTS+rax]
    movsd   [rsp], xmm0
    movsd   xmm0, [rbx+SK_PTS+rax+8]
    movsd   [rsp+8], xmm0
    xorpd   xmm2, xmm2                  # angles: circle 0..2pi, arc a0..a1
    movsd   xmm3, [rip+xd_2pi]
    cmp     dword ptr [r12+EN_TYPE], E_ARC
    jne     3f
    mov     eax, [r12+EN_P1]
    call    angle_of
    movsd   xmm2, xmm0
    movsd   [rsp+16], xmm2
    mov     eax, [r12+EN_P2]
    call    angle_of
    movsd   xmm2, [rsp+16]
    movsd   xmm3, xmm0
    subsd   xmm3, xmm2                  # sweep in (0, 2pi]
    xorpd   xmm4, xmm4
    comisd  xmm3, xmm4
    ja      3f
    addsd   xmm3, [rip+xd_2pi]
3:  cvtsi2sd xmm4, dword ptr [rsp+40]   # a = a0 + sweep i / n
    cvtsi2sd xmm5, dword ptr [rsp+44]
    divsd   xmm4, xmm5
    mulsd   xmm4, xmm3
    addsd   xmm4, xmm2
    movsd   [rsp+16], xmm4
    fld     qword ptr [rsp+16]
    fsincos
    fstp    qword ptr [rsp+24]          # cos
    fstp    qword ptr [rsp+32]          # sin
    movsd   xmm0, [rsp+24]
    mulsd   xmm0, [r12+EN_R]
    addsd   xmm0, [rsp]
    movsd   xmm1, [rsp+32]
    mulsd   xmm1, [r12+EN_R]
    addsd   xmm1, [rsp+8]
8:  mov     rdi, rbx
    mov     rsi, r13
    call    sk_plane_xyz
    add     rsp, 56
    pop     r14
    pop     r13
    ret

# angle_of(eax=point; rbx, the centre at the caller's frame) -> xmm0 =
#   atan2(p - c)
angle_of:
    imul    eax, eax, PT_SZ
    movsd   xmm0, [rbx+SK_PTS+rax]
    subsd   xmm0, [rsp+8]
    movsd   xmm1, [rbx+SK_PTS+rax+8]
    subsd   xmm1, [rsp+8+8]
    movsd   [rsp+8+24], xmm0            # (the caller's scratch at +24, +32)
    movsd   [rsp+8+32], xmm1
    fld     qword ptr [rsp+8+32]
    fld     qword ptr [rsp+8+24]
    fpatan
    fstp    qword ptr [rsp+8+24]
    movsd   xmm0, [rsp+8+24]
    ret

# display_mesh(rdi=sketch) -> rax = a mesh of 2-point polygons (plane
#   coordinates) for every entity, plus a small origin cross
display_mesh:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 32
    mov     rbx, rdi
    xor     r13d, r13d                  # vertices
    xor     ecx, ecx
1:  cmp     ecx, [rbx+SK_NENT]
    jae     2f
    imul    eax, ecx, EN_SZ
    lea     r12, [rbx+SK_ENTS+rax]
    call    ent_segs
    lea     r13d, [r13+rax+1]
    inc     ecx
    jmp     1b
2:  lea     edi, [r13+4]
    lea     esi, [r13*2+8]
    mov     edx, r13d
    add     edx, 4
    call    mesh_new
    test    rax, rax
    jz      9f
    mov     r15, rax
    xor     r14d, r14d                  # entity
3:  cmp     r14d, [rbx+SK_NENT]
    jae     6f
    imul    eax, r14d, EN_SZ
    lea     r12, [rbx+SK_ENTS+rax]
    call    ent_segs
    mov     [rsp+28], eax
    mov     r13d, [r15+ME_NVERTS]       # its first vertex
    xor     ecx, ecx
4:  cmp     ecx, [rsp+28]
    ja      5f
    push    rcx
    mov     edx, [rsp+8+28]
    lea     rsi, [rsp+8]
    call    ent_at
    movss   xmm0, [rsp+8]
    movss   xmm1, [rsp+12]
    movss   xmm2, [rsp+16]
    mov     rdi, r15
    call    mesh_add_vert
    pop     rcx
    test    ecx, ecx                    # a segment to the previous point
    jz      41f
    lea     eax, [r13+rcx]
    mov     [rsp+20], eax
    dec     eax
    mov     [rsp+16], eax
    push    rcx
    mov     rdi, r15
    lea     rsi, [rsp+8+16]
    mov     edx, 2
    call    mesh_add_poly
    pop     rcx
41: inc     ecx
    jmp     4b
5:  inc     r14d
    jmp     3b
6:  mov     r13d, [r15+ME_NVERTS]       # the origin cross (u, v)
    xor     r14d, r14d
61: cmp     r14d, 2
    jae     7f
    xorpd   xmm0, xmm0
    xorpd   xmm1, xmm1
    mov     rdi, rbx
    lea     rsi, [rsp]
    call    sk_plane_xyz
    movss   xmm0, [rsp]
    movss   xmm1, [rsp+4]
    movss   xmm2, [rsp+8]
    mov     rdi, r15
    call    mesh_add_vert
    cvtss2sd xmm0, [rip+xf_mark]
    xorpd   xmm1, xmm1
    test    r14d, r14d
    jz      62f
    movsd   xmm1, xmm0
    xorpd   xmm0, xmm0
62: mov     rdi, rbx
    lea     rsi, [rsp]
    call    sk_plane_xyz
    movss   xmm0, [rsp]
    movss   xmm1, [rsp+4]
    movss   xmm2, [rsp+8]
    mov     rdi, r15
    call    mesh_add_vert
    lea     eax, [r13+r14*2]
    mov     [rsp+16], eax
    inc     eax
    mov     [rsp+20], eax
    mov     rdi, r15
    lea     rsi, [rsp+16]
    mov     edx, 2
    call    mesh_add_poly
    inc     r14d
    jmp     61b
7:  mov     rdi, r15
    call    mesh_finish
    mov     rax, r15
9:  add     rsp, 32
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# skx_draw(rdi=object, esi=colour or 0 for status colours) - its entities
skx_draw:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 40
    mov     r15, rdi
    mov     ebp, esi
    mov     rbx, [r15+OB_SKETCH]
    test    rbx, rbx
    jz      9f
    mov     rdi, r15
    lea     rsi, [rip+xs_m]
    call    obj_matrix
    xor     r14d, r14d
1:  cmp     r14d, [rbx+SK_NENT]
    jae     9f
    imul    eax, r14d, EN_SZ
    lea     r12, [rbx+SK_ENTS+rax]
    mov     r13d, ebp                   # the colour
    test    r13d, r13d
    jnz     2f
    mov     r13d, COL_UNDER
    test    dword ptr [r12+EN_FLAGS], F_FULL
    jz      11f
    mov     r13d, COL_FULLY
11: test    dword ptr [r12+EN_FLAGS], F_BAD
    jz      2f
    mov     r13d, COL_CONFL
2:  call    ent_segs
    mov     [rsp+32], eax
    xor     ecx, ecx
    mov     edx, eax
    lea     rsi, [rsp]
    push    rcx
    push    rcx
    call    ent_at
    pop     rcx
    pop     rcx
    lea     rdi, [rip+xs_m]             # (world) -> lp1
    lea     rsi, [rsp]
    lea     rdx, [rip+lp1]
    call    xform_point
    mov     dword ptr [rsp+36], 1
3:  mov     ecx, [rsp+36]
    cmp     ecx, [rsp+32]
    ja      5f
    mov     rax, [rip+lp1]              # lp0 = the previous point
    mov     [rip+lp0], rax
    mov     eax, [rip+lp1+8]
    mov     [rip+lp0+8], eax
    mov     edx, [rsp+32]
    lea     rsi, [rsp]
    call    ent_at
    lea     rdi, [rip+xs_m]
    lea     rsi, [rsp]
    lea     rdx, [rip+lp1]
    call    xform_point
    mov     edx, r13d
    call    line3d
    inc     dword ptr [rsp+36]
    jmp     3b
5:  inc     r14d
    jmp     1b
9:  add     rsp, 40
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# cad_rebuild - after parameters or units change: every sketch solves again
#   (its dimensions may be expressions)
cad_rebuild:
    push    rbx
    push    r12
    sub     rsp, 8
    xor     ebx, ebx
1:  cmp     ebx, [rip+obj_count]
    jae     9f
    mov     edi, ebx
    call    obj_at
    cmp     dword ptr [rax+OB_TYPE], OT_SKETCH
    jne     2f
    cmp     qword ptr [rax+OB_SKETCH], 0
    je      2f
    mov     rdi, rax
    call    skx_end
2:  inc     ebx
    jmp     1b
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# ---- files: SKCH = count, then (object index, block) per sketch -------------
sketches_write:
    push    rbx
    push    r12
    sub     rsp, 8
    xor     r12d, r12d                  # count first
    xor     ebx, ebx
1:  cmp     ebx, [rip+obj_count]
    jae     2f
    mov     edi, ebx
    call    obj_at
    cmp     qword ptr [rax+OB_SKETCH], 0
    je      11f
    inc     r12d
11: inc     ebx
    jmp     1b
2:  mov     edi, r12d
    call    wb_u32
    xor     ebx, ebx
3:  cmp     ebx, [rip+obj_count]
    jae     9f
    mov     edi, ebx
    call    obj_at
    mov     r12, [rax+OB_SKETCH]
    test    r12, r12
    jz      31f
    mov     edi, ebx
    call    wb_u32
    mov     rsi, r12
    mov     edx, SK_SZ
    call    wb_bytes
31: inc     ebx
    jmp     3b
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# sketches_read(rdi=chunk data, esi=bytes) - after the objects are back
sketches_read:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     rbx, rdi
    lea     r12, [rdi+rsi]
    cmp     esi, 4
    jb      9f
    mov     r13d, [rbx]
    add     rbx, 4
1:  test    r13d, r13d
    jz      9f
    lea     rax, [rbx+4+SK_SZ]
    cmp     rax, r12
    ja      9f
    mov     eax, [rbx]                  # the object
    cmp     eax, [rip+obj_count]
    jae     8f
    mov     edi, eax
    call    obj_at
    mov     r14, rax
    cmp     dword ptr [r14+OB_TYPE], OT_SKETCH
    jne     8f
    mov     edi, [rbx+4+SK_PLANE]
    call    sk_new
    test    rax, rax
    jz      8f
    mov     rdi, rax                    # its content (counts checked)
    lea     rsi, [rbx+4+8]
    add     rdi, 8
    mov     ecx, SK_SZ-8
    rep     movsb
    sub     rdi, SK_SZ
    cmp     dword ptr [rdi+SK_NPT], 256
    ja      7f
    cmp     dword ptr [rdi+SK_NENT], 256
    ja      7f
    cmp     dword ptr [rdi+SK_NCON], 256
    ja      7f
    mov     rcx, [r14+OB_SKETCH]
    mov     [r14+OB_SKETCH], rdi
    push    rcx
    push    rcx
    mov     rdi, r14                    # solved and shown again
    call    skx_end
    pop     rdi
    pop     rdi
    call    sk_unref
    jmp     8f
7:  call    sk_unref
8:  add     rbx, 4+SK_SZ
    dec     r13d
    jmp     1b
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.section .note.GNU-stack,"",@progbits
