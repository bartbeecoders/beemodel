# =============================================================================
#  BeeModel - B-rep bodies from sketches: extrusions and revolutions
#
#  bp_place sets up the map from a sketch's plane coordinates (u, v, and w
#  along its normal) to the world, in doubles. bp_build finds the closed
#  loops of a sketch exactly - lines and arcs chained end to end, whole
#  circles - nests them (even-odd: material, holes, material ...) and turns
#  material loops counter-clockwise, holes clockwise; arcs longer than half
#  a turn are split so no face spans more than pi of a periodic surface.
#
#  bp_prism extrudes every region between two heights: a plane or a
#  cylinder per loop element, the profile as caps. bp_revolve turns the
#  loops about the sketch's u or v axis: lines make cylinders, planes or
#  cones, arcs spheres or tori, in patches of at most half a turn, with
#  poles where the profile touches the axis and caps for part turns. The
#  faces are oriented by asking whether a point just off them lies inside
#  the solid, which the profile answers exactly (arcs included).
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "brep.inc"

.globl bp_place
.globl bp_build
.globl bp_points
.globl bp_offset
.globl bp_prism
.globl bp_revolve
.globl bp_count
.globl bp_scale
.globl bm_pt
.globl bm_dir
.globl bm_o
.globl bm_u
.globl bm_v
.globl bm_w
.globl bd_finish
.globl bm_set
.globl bp_custom

.equ SK_PLANE,   8
.equ SK_NPT,     12
.equ SK_NENT,    16
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
.equ F_CONSTR,   4
.equ E_LINE,     1
.equ E_CIRCLE,   2
.equ E_ARC,      3

# profile elements: a line or an arc from a to b
.equ EL_SZ,      96
.equ EL_TYPE,    0
.equ EL_A,       8
.equ EL_B,       24
.equ EL_C,       40                     # arc: centre, radius,
.equ EL_R,       56
.equ EL_T0,      64                     #  start angle, signed sweep
.equ EL_SW,      72
.equ EL_NA,      80                     # end clusters (chaining)
.equ EL_NB,      84
.equ MAXEL,      512
.equ MAXLP,      128
.equ MAXN,       1024
.equ ARCS,       0                      # (unused)

.section .rodata
.align 16
bb_abs:         .quad 0x7fffffffffffffff, 0x7fffffffffffffff
bb_negm:        .quad 0x8000000000000000, 0x8000000000000000
bb_one:         .double 1.0
bb_half:        .double 0.5
bb_pi:          .double 3.14159265358979323846
bb_2pi:         .double 6.28318530717958647692
bb_weld:        .double 1.0e-7
bb_tiny:        .double 1.0e-12
bb_eps:         .double 1.0e-7          # fc_orient's step (of the scale)
bb_axis:        .double 1.0e-9          # on the revolve axis (of the scale)
bb_full:        .double 6.2831853
# sketch planes: Lo (offset direction), Lu, Lv, Lw as (x, y, z)
pl_dirs:        .double 0,0,1,  1,0,0,  0,1,0,  0,0,1       # XY
                .double 0,1,0,  1,0,0,  0,0,-1, 0,1,0       # XZ
                .double 1,0,0,  0,0,-1, 0,1,0,  1,0,0       # YZ

.section .bss
.align 8
bm_o:           .skip 24                # the plane map: O + u U + v V + w W
bm_u:           .skip 24
bm_v:           .skip 24
bm_w:           .skip 24
bm_inv:         .skip 72                # rows of [U V W]^-1
bp_scale:       .skip 8                 # the profile's size (tolerances)
# raw elements, then chained into loops
bp_raw:         .skip EL_SZ*MAXEL
bp_nraw:        .skip 4
bp_used:        .skip MAXEL
bp_el:          .skip EL_SZ*MAXEL
bp_nel:         .skip 4
bp_nl:          .skip 4
bp_lf:          .skip 4*MAXLP
bp_ln:          .skip 4*MAXLP
bp_dep:         .skip 4*MAXLP
bp_par:         .skip 4*MAXLP
.align 8
bp_ar:          .skip 8*MAXLP
bp_nx:          .skip 16*MAXN
bp_nn:          .skip 4
# building
.align 8
bq_w0:          .skip 8
bq_w1:          .skip 8
bq_vb:          .skip 4*MAXEL           # per element of the loop being built
bq_vt:          .skip 4*MAXEL
bq_ve:          .skip 4*MAXEL
bq_be:          .skip 4*MAXEL
bq_te:          .skip 4*MAXEL
# revolve
.align 8
br_ax:          .skip 4                 # 0 about u, 1 about v
br_side:        .skip 4                 # +1 / -1: the profile's side
br_np:          .skip 4                 # patches
br_full:        .skip 4
br_ang:         .skip 8
br_phi:         .skip 8*4               # patch boundaries
br_ao:          .skip 24                # the axis: origin, Ax, Ay, Az (world)
br_axw:         .skip 24
br_ayw:         .skip 24
br_azw:         .skip 24
br_pv:          .skip 4*MAXEL*3         # vertex per point per boundary (0..2)
br_pe:          .skip 4*MAXEL*3         # profile edge per element per boundary
br_ce:          .skip 4*MAXEL*2         # circle edge per point per patch
br_onax:        .skip MAXEL             # point on the axis

.text

# =============================================================================
#  The plane map
# =============================================================================
# bm_pt(rdi=out, xmm0=u, xmm1=v, xmm2=w) - a point; bm_dir: a direction
bm_pt:
    lea     rsi, [rip+bm_o]
    jmp     1f
bm_dir:
    xor     esi, esi
1:  lea     rdx, [rip+bm_u]
    lea     rcx, [rip+bm_v]
    lea     r8, [rip+bm_w]
    jmp     lin3

# fmat(rdi=float[12], rsi=in (3 doubles), rdx=out, ecx=1 point / 0 direction)
fmat:
    push    rbx
    sub     rsp, 32
    movupd  xmm0, [rsi]
    movupd  [rsp], xmm0
    mov     rax, [rsi+16]
    mov     [rsp+16], rax
    xor     r8d, r8d
1:  imul    r9, r8, 16
    cvtss2sd xmm0, [rdi+r9]
    mulsd   xmm0, [rsp]
    cvtss2sd xmm1, [rdi+r9+4]
    mulsd   xmm1, [rsp+8]
    addsd   xmm0, xmm1
    cvtss2sd xmm1, [rdi+r9+8]
    mulsd   xmm1, [rsp+16]
    addsd   xmm0, xmm1
    test    ecx, ecx
    jz      2f
    cvtss2sd xmm1, [rdi+r9+12]
    addsd   xmm0, xmm1
2:  movsd   [rdx+r8*8], xmm0
    inc     r8d
    cmp     r8d, 3
    jb      1b
    add     rsp, 32
    pop     rbx
    ret

# bp_place(rdi=sketch object, rsi=extra transform float[12] or 0)
bp_place:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 128
    mov     rbx, rdi
    mov     r12, rsi
    mov     rax, [rbx+OB_SKETCH]
    mov     ecx, [rax+SK_PLANE]
    cmp     ecx, 2
    jbe     1f
    xor     ecx, ecx
1:  imul    ecx, ecx, 96
    lea     r13, [rip+pl_dirs]
    add     r13, rcx
    lea     rdi, [rsp+48]               # Lo = offset * the offset direction
    mov     rsi, r13
    movsd   xmm0, [rax+SK_OFFSET]
    call    v3scale
    mov     rdi, rbx                    # the object's matrix
    lea     rsi, [rsp]
    call    obj_matrix
    lea     rdi, [rsp]
    lea     rsi, [rsp+48]
    lea     rdx, [rip+bm_o]
    mov     ecx, 1
    call    fmat
    lea     rdi, [rsp]
    lea     rsi, [r13+24]
    lea     rdx, [rip+bm_u]
    xor     ecx, ecx
    call    fmat
    lea     rdi, [rsp]
    lea     rsi, [r13+48]
    lea     rdx, [rip+bm_v]
    xor     ecx, ecx
    call    fmat
    lea     rdi, [rsp]
    lea     rsi, [r13+72]
    lea     rdx, [rip+bm_w]
    xor     ecx, ecx
    call    fmat
    test    r12, r12
    jz      2f
    lea     rbx, [rip+bm_o]             # the extra transform after
    xor     r13d, r13d
3:  mov     rdi, r12
    mov     rsi, rbx
    lea     rdx, [rsp+80]
    xor     ecx, ecx
    test    r13d, r13d
    sete    cl
    call    fmat
    movupd  xmm0, [rsp+80]
    movupd  [rbx], xmm0
    mov     rax, [rsp+96]
    mov     [rbx+16], rax
    add     rbx, 24
    inc     r13d
    cmp     r13d, 4
    jb      3b
2:  call    bm_invert
    add     rsp, 128
    pop     r13
    pop     r12
    pop     rbx
    ret

# bm_set(rdi=O U V W: 12 doubles) - a plane map given directly
bm_set:
    sub     rsp, 8
    mov     rsi, rdi
    lea     rdi, [rip+bm_o]
    mov     ecx, 12
    rep     movsq
    call    bm_invert
    add     rsp, 8
    ret

# bm_invert - bm_inv: rows of [U V W]^-1
bm_invert:
    sub     rsp, 8
    # the inverse: rows V x W, W x U, U x V over det
    lea     rdi, [rip+bm_inv]
    lea     rsi, [rip+bm_v]
    lea     rdx, [rip+bm_w]
    call    v3cross
    lea     rdi, [rip+bm_inv+24]
    lea     rsi, [rip+bm_w]
    lea     rdx, [rip+bm_u]
    call    v3cross
    lea     rdi, [rip+bm_inv+48]
    lea     rsi, [rip+bm_u]
    lea     rdx, [rip+bm_v]
    call    v3cross
    lea     rdi, [rip+bm_u]
    lea     rsi, [rip+bm_inv]
    call    v3dot
    movsd   xmm1, [rip+bb_one]
    divsd   xmm1, xmm0
    lea     rax, [rip+bm_inv]
    mov     ecx, 9
4:  movsd   xmm0, [rax]
    mulsd   xmm0, xmm1
    movsd   [rax], xmm0
    add     rax, 8
    loop    4b
    add     rsp, 8
    ret

# bm_local(rdi=world point, rsi=out (u, v, w))
bm_local:
    push    rbx
    push    r12
    sub     rsp, 40
    mov     r12, rsi
    lea     rsi, [rdi]
    lea     rdi, [rsp]
    lea     rdx, [rip+bm_o]
    call    v3sub
    xor     ebx, ebx
1:  lea     rdi, [rsp]
    lea     rsi, [rip+bm_inv]
    imul    eax, ebx, 24
    add     rsi, rax
    call    v3dot
    movsd   [r12+rbx*8], xmm0
    inc     ebx
    cmp     ebx, 3
    jb      1b
    add     rsp, 40
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Profiles
# =============================================================================
# el_ptr(edi=index) -> rax (bp_el)
el_ptr:
    imul    eax, edi, EL_SZ
    lea     rcx, [rip+bp_el]
    add     rax, rcx
    ret

# bp_count -> eax = loops
bp_count:
    mov     eax, [rip+bp_nl]
    ret

# el_rev(rdi=element) - walked the other way
el_rev:
    movupd  xmm0, [rdi+EL_A]
    movupd  xmm1, [rdi+EL_B]
    movupd  [rdi+EL_A], xmm1
    movupd  [rdi+EL_B], xmm0
    mov     eax, [rdi+EL_NA]
    mov     ecx, [rdi+EL_NB]
    mov     [rdi+EL_NA], ecx
    mov     [rdi+EL_NB], eax
    movsd   xmm0, [rdi+EL_T0]           # arc: t0 + sweep, -sweep
    addsd   xmm0, [rdi+EL_SW]
    movsd   [rdi+EL_T0], xmm0
    movsd   xmm0, [rdi+EL_SW]
    xorpd   xmm0, [rip+bb_negm]
    movsd   [rdi+EL_SW], xmm0
    ret

# el_at(rdi=element, xmm0=s in 0..1, rsi=out (u, v))
el_at:
    cmp     dword ptr [rdi+EL_TYPE], E_ARC
    je      1f
    movsd   xmm1, [rdi+EL_B]            # a + s (b - a)
    subsd   xmm1, [rdi+EL_A]
    mulsd   xmm1, xmm0
    addsd   xmm1, [rdi+EL_A]
    movsd   [rsi], xmm1
    movsd   xmm1, [rdi+EL_B+8]
    subsd   xmm1, [rdi+EL_A+8]
    mulsd   xmm1, xmm0
    addsd   xmm1, [rdi+EL_A+8]
    movsd   [rsi+8], xmm1
    ret
1:  push    rdi
    push    rsi
    sub     rsp, 8
    mulsd   xmm0, [rdi+EL_SW]
    addsd   xmm0, [rdi+EL_T0]
    call    dsincos
    add     rsp, 8
    pop     rsi
    pop     rdi
    mulsd   xmm1, [rdi+EL_R]
    addsd   xmm1, [rdi+EL_C]
    movsd   [rsi], xmm1
    mulsd   xmm0, [rdi+EL_R]
    addsd   xmm0, [rdi+EL_C+8]
    movsd   [rsi+8], xmm0
    ret

# arc_ends(rdi=element) - a, b from the centre, radius, t0, sweep
arc_ends:
    push    rbx
    mov     rbx, rdi
    xorpd   xmm0, xmm0
    lea     rsi, [rbx+EL_A]
    call    el_at
    movsd   xmm0, [rip+bb_one]
    mov     rdi, rbx
    lea     rsi, [rbx+EL_B]
    call    el_at
    pop     rbx
    ret

# raw_new -> rax = a new raw element (cleared), or 0 when full
raw_new:
    mov     eax, [rip+bp_nraw]
    cmp     eax, MAXEL
    jae     8f
    inc     dword ptr [rip+bp_nraw]
    imul    eax, eax, EL_SZ
    lea     rcx, [rip+bp_raw]
    add     rax, rcx
    push    rdi
    mov     rdi, rax
    mov     ecx, EL_SZ/8
    mov     rdx, rax
    xor     eax, eax
    rep     stosq
    mov     rax, rdx
    pop     rdi
    ret
8:  xor     eax, eax
    ret

# node(rsi=(u, v)) -> eax = its cluster (welded)
node:
    movsd   xmm0, [rip+bp_scale]
    mulsd   xmm0, [rip+bb_weld]
    lea     rdx, [rip+bp_nx]
    xor     eax, eax
1:  cmp     eax, [rip+bp_nn]
    jae     2f
    mov     ecx, eax
    shl     ecx, 4
    movsd   xmm1, [rsi]
    subsd   xmm1, [rdx+rcx]
    andpd   xmm1, [rip+bb_abs]
    movsd   xmm2, [rsi+8]
    subsd   xmm2, [rdx+rcx+8]
    andpd   xmm2, [rip+bb_abs]
    maxsd   xmm1, xmm2
    comisd  xmm1, xmm0
    jbe     9f
    inc     eax
    jmp     1b
2:  cmp     eax, MAXN
    jae     8f
    shl     eax, 4
    movupd  xmm1, [rsi]
    movupd  [rdx+rax], xmm1
    mov     eax, [rip+bp_nn]
    inc     dword ptr [rip+bp_nn]
9:  ret
8:  xor     eax, eax
    ret

# skp(rbx=sketch, eax=point, rdi=out (u, v))
skp:
    imul    eax, eax, PT_SZ
    movupd  xmm0, [rbx+SK_PTS+rax]
    movupd  [rdi], xmm0
    ret

# bp_build(rdi=sketch) -> eax = loops (profile filled)
bp_build:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 72
    mov     rbx, rdi
    xor     eax, eax
    mov     [rip+bp_nraw], eax
    mov     [rip+bp_nel], eax
    mov     [rip+bp_nl], eax
    mov     [rip+bp_nn], eax
    # the scale: the largest coordinate
    movsd   xmm0, [rip+bb_tiny]
    xor     ecx, ecx
1:  cmp     ecx, [rbx+SK_NPT]
    jae     2f
    imul    eax, ecx, PT_SZ
    movsd   xmm1, [rbx+SK_PTS+rax]
    andpd   xmm1, [rip+bb_abs]
    maxsd   xmm0, xmm1
    movsd   xmm1, [rbx+SK_PTS+rax+8]
    andpd   xmm1, [rip+bb_abs]
    maxsd   xmm0, xmm1
    inc     ecx
    jmp     1b
2:  xor     r12d, r12d                  # entities with their radii too
3:  cmp     r12d, [rbx+SK_NENT]
    jae     4f
    imul    eax, r12d, EN_SZ
    movsd   xmm1, [rbx+SK_ENTS+rax+EN_R]
    andpd   xmm1, [rip+bb_abs]
    maxsd   xmm0, xmm1
    inc     r12d
    jmp     3b
4:  movsd   [rip+bp_scale], xmm0
    # the elements
    xor     r12d, r12d
.Lbb_ent:
    cmp     r12d, [rbx+SK_NENT]
    jae     .Lbb_chain
    imul    r13d, r12d, EN_SZ
    lea     r13, [rbx+SK_ENTS+r13]
    test    dword ptr [r13+EN_FLAGS], F_CONSTR
    jnz     .Lbb_enext
    mov     eax, [r13+EN_TYPE]
    cmp     eax, E_LINE
    je      .Lbb_line
    cmp     eax, E_ARC
    je      .Lbb_arc
    cmp     eax, E_CIRCLE
    je      .Lbb_circle
    jmp     .Lbb_enext
.Lbb_line:
    call    raw_new
    test    rax, rax
    jz      .Lbb_enext
    mov     r14, rax
    mov     dword ptr [r14+EL_TYPE], E_LINE
    mov     eax, [r13+EN_P0]
    lea     rdi, [r14+EL_A]
    call    skp
    mov     eax, [r13+EN_P1]
    lea     rdi, [r14+EL_B]
    call    skp
    jmp     .Lbb_nodes
.Lbb_arc:
    call    raw_new
    test    rax, rax
    jz      .Lbb_enext
    mov     r14, rax
    mov     dword ptr [r14+EL_TYPE], E_ARC
    mov     eax, [r13+EN_P0]
    lea     rdi, [r14+EL_C]
    call    skp
    movsd   xmm0, [r13+EN_R]
    movsd   [r14+EL_R], xmm0
    mov     eax, [r13+EN_P1]            # angles of start and end
    lea     rdi, [rsp]
    call    skp
    movsd   xmm1, [rsp]
    subsd   xmm1, [r14+EL_C]
    movsd   xmm0, [rsp+8]
    subsd   xmm0, [r14+EL_C+8]
    call    datan2
    movsd   [r14+EL_T0], xmm0
    mov     eax, [r13+EN_P2]
    lea     rdi, [rsp]
    call    skp
    movsd   xmm1, [rsp]
    subsd   xmm1, [r14+EL_C]
    movsd   xmm0, [rsp+8]
    subsd   xmm0, [r14+EL_C+8]
    call    datan2
    subsd   xmm0, [r14+EL_T0]           # counter-clockwise sweep, 0 .. 2 pi
    xorpd   xmm1, xmm1
    comisd  xmm0, xmm1
    ja      5f
    addsd   xmm0, [rip+bb_2pi]
5:  movsd   [r14+EL_SW], xmm0
    mov     rdi, r14
    call    arc_ends
.Lbb_nodes:
    lea     rsi, [r14+EL_A]
    call    node
    mov     [r14+EL_NA], eax
    lea     rsi, [r14+EL_B]
    call    node
    mov     [r14+EL_NB], eax
    jmp     .Lbb_enext
.Lbb_circle:
    mov     eax, [r13+EN_P0]            # a loop of its own: two half arcs
    lea     rdi, [rsp]
    call    skp
    movsd   xmm0, [r13+EN_R]
    call    add_circle
.Lbb_enext:
    inc     r12d
    jmp     .Lbb_ent
.Lbb_chain:
    xor     eax, eax                    # nothing used yet
    lea     rdi, [rip+bp_used]
    mov     ecx, MAXEL
    rep     stosb
    xor     r12d, r12d                  # a start
.Lbb_start:
    cmp     r12d, [rip+bp_nraw]
    jae     .Lbb_nest
    lea     rax, [rip+bp_used]
    cmp     byte ptr [rax+r12], 0
    jne     .Lbb_snext
    mov     eax, [rip+bp_nl]
    cmp     eax, MAXLP
    jae     .Lbb_nest
    mov     r15d, [rip+bp_nel]          # the loop's first element
    mov     r13d, r12d                  # current raw element (forward)
    imul    eax, r12d, EL_SZ
    lea     rcx, [rip+bp_raw]
    mov     ebp, [rcx+rax+EL_NA]        # where the loop must come back to
.Lbb_walk:
    lea     rax, [rip+bp_used]
    mov     byte ptr [rax+r13], 1
    mov     eax, [rip+bp_nel]           # copy it into the loop
    cmp     eax, MAXEL
    jae     .Lbb_drop
    imul    eax, eax, EL_SZ
    lea     rdi, [rip+bp_el]
    add     rdi, rax
    imul    eax, r13d, EL_SZ
    lea     rsi, [rip+bp_raw]
    add     rsi, rax
    mov     ecx, EL_SZ/8
    rep     movsq
    inc     dword ptr [rip+bp_nel]
    sub     rdi, EL_SZ
    mov     r14d, [rdi+EL_NB]           # its end
    cmp     r14d, ebp
    je      .Lbb_closed
    xor     ecx, ecx                    # an unused element touching the end
6:  cmp     ecx, [rip+bp_nraw]
    jae     .Lbb_drop
    lea     rax, [rip+bp_used]
    cmp     byte ptr [rax+rcx], 0
    jne     7f
    imul    eax, ecx, EL_SZ
    lea     rdx, [rip+bp_raw]
    add     rdx, rax
    cmp     [rdx+EL_NA], r14d
    je      8f
    cmp     [rdx+EL_NB], r14d
    jne     7f
    push    rcx
    push    rdx
    mov     rdi, rdx                    # (reversed in place)
    call    el_rev
    pop     rdx
    pop     rcx
8:  mov     r13d, ecx
    jmp     .Lbb_walk
7:  inc     ecx
    jmp     6b
.Lbb_drop:
    mov     [rip+bp_nel], r15d          # not closed: forgotten
    jmp     .Lbb_snext
.Lbb_closed:
    mov     eax, [rip+bp_nl]
    lea     rcx, [rip+bp_lf]
    mov     [rcx+rax*4], r15d
    mov     edx, [rip+bp_nel]
    sub     edx, r15d
    lea     rcx, [rip+bp_ln]
    mov     [rcx+rax*4], edx
    inc     dword ptr [rip+bp_nl]
.Lbb_snext:
    inc     r12d
    jmp     .Lbb_start
.Lbb_nest:
    call    split_arcs
    call    nest
    mov     eax, [rip+bp_nl]
    add     rsp, 72
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# add_circle(rdi=centre (u, v), xmm0=radius) - a loop: two half arcs
add_circle:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 16
    mov     r12, rdi
    movsd   [rsp], xmm0
    mov     eax, [rip+bp_nl]
    cmp     eax, MAXLP
    jae     9f
    mov     eax, [rip+bp_nel]
    add     eax, 2
    cmp     eax, MAXEL
    ja      9f
    mov     r13d, [rip+bp_nel]
    xor     ebx, ebx
1:  mov     edi, [rip+bp_nel]
    call    el_ptr
    mov     rdi, rax
    push    rdi
    mov     ecx, EL_SZ/8
    xor     eax, eax
    rep     stosq
    pop     rdi
    mov     dword ptr [rdi+EL_TYPE], E_ARC
    movupd  xmm0, [r12]
    movupd  [rdi+EL_C], xmm0
    movsd   xmm0, [rsp]
    movsd   [rdi+EL_R], xmm0
    cvtsi2sd xmm0, ebx
    mulsd   xmm0, [rip+bb_pi]
    movsd   [rdi+EL_T0], xmm0
    movsd   xmm0, [rip+bb_pi]
    movsd   [rdi+EL_SW], xmm0
    call    arc_ends
    inc     dword ptr [rip+bp_nel]
    inc     ebx
    cmp     ebx, 2
    jb      1b
    mov     eax, [rip+bp_nl]
    lea     rcx, [rip+bp_lf]
    mov     [rcx+rax*4], r13d
    lea     rcx, [rip+bp_ln]
    mov     dword ptr [rcx+rax*4], 2
    inc     dword ptr [rip+bp_nl]
9:  add     rsp, 16
    pop     r13
    pop     r12
    pop     rbx
    ret

# split_arcs - arcs of more than half a turn become two (bp_el rebuilt)
split_arcs:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r12d, [rip+bp_nel]          # work from the end backwards
    dec     r12d
.Lsa_el:
    test    r12d, r12d
    js      .Lsa_out
    mov     edi, r12d
    call    el_ptr
    mov     rbx, rax
    cmp     dword ptr [rbx+EL_TYPE], E_ARC
    jne     .Lsa_next
    movsd   xmm0, [rbx+EL_SW]
    andpd   xmm0, [rip+bb_abs]
    comisd  xmm0, [rip+bb_pi]
    jbe     .Lsa_next
    cmp     dword ptr [rip+bp_nel], MAXEL
    jae     .Lsa_next
    mov     ecx, [rip+bp_nel]           # move everything after it up one
    imul    eax, ecx, EL_SZ
    lea     rsi, [rip+bp_el]
    add     rsi, rax
    lea     rdi, [rsi+EL_SZ]
    lea     rax, [rbx+EL_SZ]
1:  cmp     rsi, rax
    jbe     2f
    sub     rsi, 8
    sub     rdi, 8
    mov     rdx, [rsi]
    mov     [rdi], rdx
    jmp     1b
2:  inc     dword ptr [rip+bp_nel]
    lea     rdi, [rbx+EL_SZ]            # the copy: the second half
    mov     rsi, rbx
    mov     ecx, EL_SZ/8
    rep     movsq
    movsd   xmm0, [rbx+EL_SW]
    mulsd   xmm0, [rip+bb_half]
    movsd   [rbx+EL_SW], xmm0
    movsd   [rbx+EL_SZ+EL_SW], xmm0
    addsd   xmm0, [rbx+EL_T0]
    movsd   [rbx+EL_SZ+EL_T0], xmm0
    mov     rdi, rbx
    call    arc_ends
    lea     rdi, [rbx+EL_SZ]
    call    arc_ends
    xor     ecx, ecx                    # loops after it move up one; its own
3:  cmp     ecx, [rip+bp_nl]            #  grows
    jae     .Lsa_next
    lea     rdx, [rip+bp_lf]
    mov     eax, [rdx+rcx*4]
    cmp     eax, r12d
    jle     4f
    inc     dword ptr [rdx+rcx*4]
    jmp     5f
4:  lea     r8, [rip+bp_ln]
    add     eax, [r8+rcx*4]
    cmp     eax, r12d
    jle     5f
    inc     dword ptr [r8+rcx*4]
5:  inc     ecx
    jmp     3b
.Lsa_next:
    dec     r12d
    jmp     .Lsa_el
.Lsa_out:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# loop_area(edi=loop) -> xmm0 = its signed area (arcs exactly)
loop_area:
    push    rbx
    push    r12
    push    r13
    lea     rax, [rip+bp_lf]
    mov     ebx, [rax+rdi*4]
    lea     rax, [rip+bp_ln]
    mov     r12d, [rax+rdi*4]
    add     r12d, ebx
    xorpd   xmm6, xmm6
1:  cmp     ebx, r12d
    jae     9f
    mov     edi, ebx
    call    el_ptr
    movsd   xmm0, [rax+EL_A]            # chord: (ax by - bx ay)
    mulsd   xmm0, [rax+EL_B+8]
    movsd   xmm1, [rax+EL_B]
    mulsd   xmm1, [rax+EL_A+8]
    subsd   xmm0, xmm1
    cmp     dword ptr [rax+EL_TYPE], E_ARC
    jne     2f
    # arc: cx (by - ay) - cy (bx - ax) + r^2 sweep instead
    movsd   xmm0, [rax+EL_B+8]
    subsd   xmm0, [rax+EL_A+8]
    mulsd   xmm0, [rax+EL_C]
    movsd   xmm1, [rax+EL_B]
    subsd   xmm1, [rax+EL_A]
    mulsd   xmm1, [rax+EL_C+8]
    subsd   xmm0, xmm1
    movsd   xmm1, [rax+EL_R]
    mulsd   xmm1, xmm1
    mulsd   xmm1, [rax+EL_SW]
    addsd   xmm0, xmm1
2:  addsd   xmm6, xmm0
    inc     ebx
    jmp     1b
9:  movsd   xmm0, xmm6
    mulsd   xmm0, [rip+bb_half]
    pop     r13
    pop     r12
    pop     rbx
    ret

# crossings(edi=loop, xmm0=u, xmm1=v) -> eax = how often a ray from (u, v)
#   towards +u crosses the loop (arcs exactly)
crossings:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    rbp
    sub     rsp, 48
    movsd   [rsp], xmm0
    movsd   [rsp+8], xmm1
    lea     rax, [rip+bp_lf]
    mov     ebx, [rax+rdi*4]
    lea     rax, [rip+bp_ln]
    mov     r12d, [rax+rdi*4]
    add     r12d, ebx
    xor     r13d, r13d
.Lcr_el:
    cmp     ebx, r12d
    jae     .Lcr_out
    mov     edi, ebx
    call    el_ptr
    mov     r14, rax
    cmp     dword ptr [r14+EL_TYPE], E_ARC
    je      .Lcr_arc
    movsd   xmm1, [rsp+8]               # a line: (ay > v) != (by > v)
    xor     eax, eax
    xor     ecx, ecx
    movsd   xmm2, [r14+EL_A+8]
    comisd  xmm2, xmm1
    seta    al
    movsd   xmm3, [r14+EL_B+8]
    comisd  xmm3, xmm1
    seta    cl
    cmp     eax, ecx
    je      .Lcr_next
    movsd   xmm4, xmm1                  # x = ax + (v - ay)(bx - ax)/(by - ay)
    subsd   xmm4, xmm2
    movsd   xmm5, [r14+EL_B]
    subsd   xmm5, [r14+EL_A]
    mulsd   xmm4, xmm5
    subsd   xmm3, xmm2
    divsd   xmm4, xmm3
    addsd   xmm4, [r14+EL_A]
    comisd  xmm4, [rsp]
    jbe     .Lcr_next
    inc     r13d
    jmp     .Lcr_next
.Lcr_arc:
    movsd   xmm0, [rsp+8]               # dy = v - cy, |dy| < r
    subsd   xmm0, [r14+EL_C+8]
    movsd   xmm1, [r14+EL_R]
    movsd   xmm2, xmm1
    mulsd   xmm2, xmm2
    movsd   xmm3, xmm0
    mulsd   xmm3, xmm3
    subsd   xmm2, xmm3
    xorpd   xmm3, xmm3
    comisd  xmm2, xmm3
    jbe     .Lcr_next
    sqrtsd  xmm2, xmm2                  # dx = +- sqrt(r^2 - dy^2)
    movsd   [rsp+16], xmm0
    movsd   [rsp+24], xmm2
    xor     ebp, ebp
.Lcr_two:
    movsd   xmm1, [rsp+24]              # the root's x
    test    ebp, ebp
    jz      1f
    xorpd   xmm1, [rip+bb_negm]
1:  movsd   [rsp+32], xmm1
    addsd   xmm1, [r14+EL_C]
    comisd  xmm1, [rsp]
    jbe     3f
    movsd   xmm0, [rsp+16]              # on the arc? its angle within the sweep
    movsd   xmm1, [rsp+32]
    call    datan2
    subsd   xmm0, [r14+EL_T0]           # (a - t0) into the sweep's direction
    movsd   xmm1, [r14+EL_SW]
    xorpd   xmm2, xmm2
    comisd  xmm1, xmm2
    jae     2f
    xorpd   xmm0, [rip+bb_negm]         # clockwise: measure the other way
    xorpd   xmm1, [rip+bb_negm]
2:  comisd  xmm0, xmm2                  # into [0, 2 pi)
    jae     21f
    addsd   xmm0, [rip+bb_2pi]
    jmp     2b
21: comisd  xmm0, [rip+bb_2pi]
    jb      22f
    subsd   xmm0, [rip+bb_2pi]
    jmp     21b
22: comisd  xmm0, xmm1
    jae     3f
    inc     r13d
3:  inc     ebp
    cmp     ebp, 2
    jb      .Lcr_two
.Lcr_next:
    inc     ebx
    jmp     .Lcr_el
.Lcr_out:
    mov     eax, r13d
    add     rsp, 48
    pop     rbp
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# prof_in(xmm0=u, xmm1=v) -> eax = 1 inside the profile (even-odd)
prof_in:
    push    rbx
    push    r12
    sub     rsp, 24
    movsd   [rsp], xmm0
    movsd   [rsp+8], xmm1
    xor     ebx, ebx
    xor     r12d, r12d
1:  cmp     ebx, [rip+bp_nl]
    jae     2f
    mov     edi, ebx
    movsd   xmm0, [rsp]
    movsd   xmm1, [rsp+8]
    call    crossings
    add     r12d, eax
    inc     ebx
    jmp     1b
2:  mov     eax, r12d
    and     eax, 1
    add     rsp, 24
    pop     r12
    pop     rbx
    ret

# nest - depth and parent of every loop; material loops counter-clockwise,
#   holes clockwise
nest:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 40
    xor     ebx, ebx
.Lne_l:
    cmp     ebx, [rip+bp_nl]
    jae     .Lne_out
    lea     rax, [rip+bp_lf]            # a point on it: its first element's
    mov     edi, [rax+rbx*4]            #  middle
    call    el_ptr
    mov     rdi, rax
    movsd   xmm0, [rip+bb_half]
    lea     rsi, [rsp]
    call    el_at
    xor     r12d, r12d                  # depth
    mov     r13d, -1                    # parent: the smallest one around it
    movsd   xmm0, [rip+bb_tiny]
    mulsd   xmm0, [rip+bb_tiny]         # (+inf stand-in below)
    xor     r14d, r14d
1:  cmp     r14d, [rip+bp_nl]
    jae     3f
    cmp     r14d, ebx
    je      2f
    mov     edi, r14d
    movsd   xmm0, [rsp]
    movsd   xmm1, [rsp+8]
    call    crossings
    test    eax, 1
    jz      2f
    inc     r12d
    mov     edi, r14d
    call    loop_area
    andpd   xmm0, [rip+bb_abs]
    cmp     r13d, -1
    je      11f
    comisd  xmm0, [rsp+16]
    jae     2f
11: movsd   [rsp+16], xmm0
    mov     r13d, r14d
2:  inc     r14d
    jmp     1b
3:  lea     rax, [rip+bp_dep]
    mov     [rax+rbx*4], r12d
    lea     rax, [rip+bp_par]
    mov     [rax+rbx*4], r13d
    mov     edi, ebx                    # its turn: even depth positive
    call    loop_area
    lea     rax, [rip+bp_ar]
    movsd   [rax+rbx*8], xmm0
    xorpd   xmm1, xmm1
    xor     eax, eax
    comisd  xmm0, xmm1
    seta    al
    mov     ecx, r12d
    and     ecx, 1
    xor     ecx, 1                      # want positive?
    cmp     eax, ecx
    je      4f
    mov     edi, ebx
    call    loop_flip_el
4:  inc     ebx
    jmp     .Lne_l
.Lne_out:
    add     rsp, 40
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# loop_flip_el(edi=loop) - its elements in the opposite order, each reversed
loop_flip_el:
    push    rbx
    push    r12
    push    r13
    sub     rsp, EL_SZ
    lea     rax, [rip+bp_lf]
    mov     ebx, [rax+rdi*4]
    lea     rax, [rip+bp_ln]
    mov     r12d, [rax+rdi*4]
    lea     r13d, [rbx+r12-1]
    lea     rax, [rip+bp_ar]
    movsd   xmm0, [rax+rdi*8]
    xorpd   xmm0, [rip+bb_negm]
    movsd   [rax+rdi*8], xmm0
1:  cmp     ebx, r13d
    ja      3f
    mov     edi, ebx
    call    el_ptr
    mov     r12, rax
    mov     edi, r13d
    call    el_ptr
    mov     rsi, r12                    # swap through the stack
    lea     rdi, [rsp]
    mov     ecx, EL_SZ/8
    rep     movsq
    mov     rdi, r12
    mov     rsi, rax
    mov     ecx, EL_SZ/8
    rep     movsq
    mov     rdi, rax
    lea     rsi, [rsp]
    mov     ecx, EL_SZ/8
    rep     movsq
    mov     rdi, r12
    call    el_rev
    cmp     ebx, r13d
    je      2f
    mov     edi, r13d
    call    el_ptr
    mov     rdi, rax
    call    el_rev
2:  inc     ebx
    dec     r13d
    jmp     1b
3:  add     rsp, EL_SZ
    pop     r13
    pop     r12
    pop     rbx
    ret

# bp_points(rdi=sketch, xmm0=radius) -> eax = loops: a circle at every
#   point no entity uses (hole centres)
bp_points:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 32
    mov     rbx, rdi
    movsd   [rsp+16], xmm0
    xor     eax, eax
    mov     [rip+bp_nel], eax
    mov     [rip+bp_nl], eax
    movsd   [rip+bp_scale], xmm0
    xor     r12d, r12d
1:  cmp     r12d, [rbx+SK_NPT]
    jae     5f
    xor     ecx, ecx
2:  cmp     ecx, [rbx+SK_NENT]
    jae     3f
    imul    eax, ecx, EN_SZ
    cmp     [rbx+SK_ENTS+rax+EN_P0], r12d
    je      4f
    cmp     [rbx+SK_ENTS+rax+EN_P1], r12d
    je      4f
    cmp     [rbx+SK_ENTS+rax+EN_P2], r12d
    je      4f
    inc     ecx
    jmp     2b
3:  mov     eax, r12d
    lea     rdi, [rsp]
    call    skp
    movsd   xmm0, [rsp]                 # (the scale)
    andpd   xmm0, [rip+bb_abs]
    maxsd   xmm0, [rip+bp_scale]
    movsd   xmm1, [rsp+8]
    andpd   xmm1, [rip+bb_abs]
    maxsd   xmm0, xmm1
    movsd   [rip+bp_scale], xmm0
    lea     rdi, [rsp]
    movsd   xmm0, [rsp+16]
    call    add_circle
4:  inc     r12d
    jmp     1b
5:  call    nest
    mov     eax, [rip+bp_nl]
    add     rsp, 32
    pop     r13
    pop     r12
    pop     rbx
    ret

# bp_offset(xmm0=distance) -> eax = 1, or 0 when a loop cannot be offset:
#   every loop moved towards its material side (shells)
bp_offset:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 104
    movsd   [rsp], xmm0
    xor     ebx, ebx                    # each element moved left
.Lbo_el:
    cmp     ebx, [rip+bp_nel]
    jae     .Lbo_join
    mov     edi, ebx
    call    el_ptr
    mov     r12, rax
    cmp     dword ptr [r12+EL_TYPE], E_ARC
    je      .Lbo_arc
    movsd   xmm0, [r12+EL_B]            # left normal (-dy, dx) / len
    subsd   xmm0, [r12+EL_A]
    movsd   xmm1, [r12+EL_B+8]
    subsd   xmm1, [r12+EL_A+8]
    movsd   xmm2, xmm0
    mulsd   xmm2, xmm2
    movsd   xmm3, xmm1
    mulsd   xmm3, xmm3
    addsd   xmm2, xmm3
    sqrtsd  xmm2, xmm2
    movsd   xmm3, [rsp]
    divsd   xmm3, xmm2
    mulsd   xmm0, xmm3                  # d * dx / len
    mulsd   xmm1, xmm3                  # d * dy / len
    movsd   xmm4, [r12+EL_A]
    subsd   xmm4, xmm1
    movsd   [r12+EL_A], xmm4
    movsd   xmm4, [r12+EL_B]
    subsd   xmm4, xmm1
    movsd   [r12+EL_B], xmm4
    movsd   xmm4, [r12+EL_A+8]
    addsd   xmm4, xmm0
    movsd   [r12+EL_A+8], xmm4
    movsd   xmm4, [r12+EL_B+8]
    addsd   xmm4, xmm0
    movsd   [r12+EL_B+8], xmm4
    jmp     .Lbo_next
.Lbo_arc:
    movsd   xmm0, [r12+EL_R]            # counter-clockwise: towards the
    movsd   xmm1, [rsp]                 #  centre (r - d); clockwise: r + d
    movsd   xmm2, [r12+EL_SW]
    xorpd   xmm3, xmm3
    comisd  xmm2, xmm3
    jb      1f
    subsd   xmm0, xmm1
    jmp     2f
1:  addsd   xmm0, xmm1
2:  comisd  xmm0, [rip+bb_tiny]
    jbe     .Lbo_fail
    movsd   [r12+EL_R], xmm0
    mov     rdi, r12
    call    arc_ends
.Lbo_next:
    inc     ebx
    jmp     .Lbo_el
.Lbo_join:
    # corners that opened: lines meeting at their lines' intersection
    xor     r13d, r13d                  # loop
.Lbo_loop:
    cmp     r13d, [rip+bp_nl]
    jae     .Lbo_ok
    lea     rax, [rip+bp_lf]
    mov     r14d, [rax+r13*4]
    lea     rax, [rip+bp_ln]
    mov     r15d, [rax+r13*4]
    xor     ebp, ebp
.Lbo_corner:
    cmp     ebp, r15d
    jae     .Lbo_lnext
    lea     edi, [r14+rbp]              # element i and the next
    call    el_ptr
    mov     r12, rax
    lea     eax, [rbp+1]
    xor     edx, edx
    div     r15d
    lea     edi, [r14+rdx]
    call    el_ptr
    mov     rbx, rax
    movsd   xmm0, [r12+EL_B]            # already meeting (tangent)?
    subsd   xmm0, [rbx+EL_A]
    andpd   xmm0, [rip+bb_abs]
    movsd   xmm1, [r12+EL_B+8]
    subsd   xmm1, [rbx+EL_A+8]
    andpd   xmm1, [rip+bb_abs]
    addsd   xmm0, xmm1
    movsd   xmm1, [rip+bp_scale]
    mulsd   xmm1, [rip+bb_weld]
    comisd  xmm0, xmm1
    jbe     .Lbo_cnext
    cmp     dword ptr [r12+EL_TYPE], E_LINE
    jne     .Lbo_fail
    cmp     dword ptr [rbx+EL_TYPE], E_LINE
    jne     .Lbo_fail
    # p = a1 + t d1 with cross(d1, d2) t = cross(a2 - a1, d2)
    movsd   xmm0, [r12+EL_B]            # d1
    subsd   xmm0, [r12+EL_A]
    movsd   xmm1, [r12+EL_B+8]
    subsd   xmm1, [r12+EL_A+8]
    movsd   xmm2, [rbx+EL_B]            # d2
    subsd   xmm2, [rbx+EL_A]
    movsd   xmm3, [rbx+EL_B+8]
    subsd   xmm3, [rbx+EL_A+8]
    movsd   xmm4, xmm0                  # cross(d1, d2)
    mulsd   xmm4, xmm3
    movsd   xmm5, xmm1
    mulsd   xmm5, xmm2
    subsd   xmm4, xmm5
    movsd   xmm5, xmm4
    andpd   xmm5, [rip+bb_abs]
    comisd  xmm5, [rip+bb_tiny]
    jbe     .Lbo_fail
    movsd   xmm6, [rbx+EL_A]            # cross(a2 - a1, d2)
    subsd   xmm6, [r12+EL_A]
    movsd   xmm7, [rbx+EL_A+8]
    subsd   xmm7, [r12+EL_A+8]
    mulsd   xmm6, xmm3
    mulsd   xmm7, xmm2
    subsd   xmm6, xmm7
    divsd   xmm6, xmm4                  # t
    mulsd   xmm0, xmm6
    addsd   xmm0, [r12+EL_A]
    mulsd   xmm1, xmm6
    addsd   xmm1, [r12+EL_A+8]
    movsd   [r12+EL_B], xmm0
    movsd   [r12+EL_B+8], xmm1
    movsd   [rbx+EL_A], xmm0
    movsd   [rbx+EL_A+8], xmm1
.Lbo_cnext:
    inc     ebp
    jmp     .Lbo_corner
.Lbo_lnext:
    inc     r13d
    jmp     .Lbo_loop
.Lbo_ok:
    mov     eax, 1
    jmp     .Lbo_out
.Lbo_fail:
    xor     eax, eax
.Lbo_out:
    add     rsp, 104
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# bp_custom(rdi=elements (EL_SZ each: type, a, b; arcs also c, r, t0, sweep),
#   esi=count, xmm0=scale) - the profile is that one closed loop (turned
#   counter-clockwise)
bp_custom:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    mov     r12d, esi
    movsd   [rip+bp_scale], xmm0
    mov     rsi, rdi
    lea     rdi, [rip+bp_el]
    imul    ecx, r12d, EL_SZ/8
    rep     movsq
    mov     [rip+bp_nel], r12d
    mov     dword ptr [rip+bp_nl], 1
    mov     dword ptr [rip+bp_lf], 0
    mov     [rip+bp_ln], r12d
    call    nest
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Building
# =============================================================================
# bd_finish(edi=first face, esi=faces, rdx=classifier) - pcurves, sense and
#   loop turns, boxes
bd_finish:
    push    rbx
    push    r12
    push    r13
    mov     ebx, edi
    lea     r12d, [rdi+rsi]
    mov     r13, rdx
1:  cmp     ebx, r12d
    jae     9f
    mov     edi, ebx
    call    fc_pcurves
    mov     edi, ebx
    mov     rsi, r13
    movsd   xmm0, [rip+bp_scale]
    mulsd   xmm0, [rip+bb_eps]
    call    fc_orient
    mov     edi, ebx
    call    fc_box
    inc     ebx
    jmp     1b
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# vert_at(xmm0=u, xmm1=v, xmm2=w) -> eax = a new vertex at the mapped point
vert_at:
    sub     rsp, 40
    lea     rdi, [rsp]
    call    bm_pt
    lea     rdi, [rsp]
    call    n_vx
    add     rsp, 40
    ret

# el_edge(rdi=element, xmm0=w, esi=v0, edx=v1) -> eax = an edge: the
#   element at height w
el_edge:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 112
    mov     rbx, rdi
    mov     r12d, esi
    mov     r13d, edx
    movsd   [rsp+96], xmm0
    cmp     dword ptr [rbx+EL_TYPE], E_ARC
    je      1f
    movsd   xmm0, [rbx+EL_A]
    movsd   xmm1, [rbx+EL_A+8]
    movsd   xmm2, [rsp+96]
    lea     rdi, [rsp]
    call    bm_pt
    movsd   xmm0, [rbx+EL_B]
    movsd   xmm1, [rbx+EL_B+8]
    movsd   xmm2, [rsp+96]
    lea     rdi, [rsp+24]
    call    bm_pt
    lea     rdi, [rsp]
    lea     rsi, [rsp+24]
    call    mk_line
    movsd   xmm1, xmm0
    xorpd   xmm0, xmm0
    jmp     2f
1:  movsd   xmm0, [rbx+EL_C]            # a circle: centre, U, V (unit)
    movsd   xmm1, [rbx+EL_C+8]
    movsd   xmm2, [rsp+96]
    lea     rdi, [rsp]
    call    bm_pt
    call    plane_xy
    movsd   xmm0, [rip+bm_u]            # R = r |U|
    mulsd   xmm0, xmm0
    movsd   xmm1, [rip+bm_u+8]
    mulsd   xmm1, xmm1
    addsd   xmm0, xmm1
    movsd   xmm1, [rip+bm_u+16]
    mulsd   xmm1, xmm1
    addsd   xmm0, xmm1
    sqrtsd  xmm0, xmm0
    mulsd   xmm0, [rbx+EL_R]
    movsd   xmm1, xmm0
    mov     edi, CT_CIRCLE
    lea     rsi, [rsp]
    call    mk_conic
    movsd   xmm0, [rbx+EL_T0]
    movsd   xmm1, xmm0
    addsd   xmm1, [rbx+EL_SW]
2:  mov     edi, eax
    mov     esi, r12d
    mov     edx, r13d
    call    n_ed
    add     rsp, 112
    pop     r13
    pop     r12
    pop     rbx
    ret

# plane_xy - [rsp+8+24..] (the caller's [rsp+24]) = unit U, [rsp+8+48] =
#   unit V made perpendicular to it
plane_xy:
    lea     rdi, [rsp+8+24]
    lea     rsi, [rip+bm_u]
    movsd   xmm0, [rip+bb_one]
    call    v3scale
    lea     rdi, [rsp+8+24]
    call    v3norm
    lea     rdi, [rsp+8+48]
    lea     rsi, [rip+bm_v]
    movsd   xmm0, [rip+bb_one]
    call    v3scale
    lea     rdi, [rsp+8+48]             # V - (V.X) X
    lea     rsi, [rsp+8+24]
    call    v3dot
    xorpd   xmm0, [rip+bb_negm]
    lea     rdi, [rsp+8+48]
    lea     rsi, [rsp+8+24]
    call    v3axpy
    lea     rdi, [rsp+8+48]
    jmp     v3norm

# prism_in(rdi=point) -> eax = 1 inside the extrusion
prism_in:
    sub     rsp, 40
    lea     rsi, [rsp]
    call    bm_local
    xor     eax, eax
    movsd   xmm0, [rsp+16]
    comisd  xmm0, [rip+bq_w0]
    jbe     9f
    comisd  xmm0, [rip+bq_w1]
    jae     9f
    movsd   xmm0, [rsp]
    movsd   xmm1, [rsp+8]
    call    prof_in
9:  add     rsp, 40
    ret

# bp_prism(xmm0=w0, xmm1=w1) -> eax = a body: the profile from w0 to w1
#   (-1 on failure)
.equ PZ_L,    0                         # loop
.equ PZ_I,    4
.equ PZ_N,    8
.equ PZ_F,    12
.equ PZ_SURF, 16
.equ PZ_A,    24                        # scratch frame (O X Y)
bp_prism:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 136
    movsd   [rip+bq_w0], xmm0
    movsd   [rip+bq_w1], xmm1
    cmp     dword ptr [rip+bp_nl], 0
    je      .Lpz_fail
    call    bb_begin
    xor     r12d, r12d                  # walls, loop by loop
.Lpz_loop:
    cmp     r12d, [rip+bp_nl]
    jae     .Lpz_caps
    lea     rax, [rip+bp_lf]
    mov     r13d, [rax+r12*4]
    lea     rax, [rip+bp_ln]
    mov     r14d, [rax+r12*4]
    xor     ebx, ebx                    # vertices and vertical edges
1:  cmp     ebx, r14d
    jae     2f
    lea     edi, [r13+rbx]
    call    el_ptr
    mov     r15, rax
    movsd   xmm0, [r15+EL_A]
    movsd   xmm1, [r15+EL_A+8]
    movsd   xmm2, [rip+bq_w0]
    call    vert_at
    lea     rcx, [rip+bq_vb]
    mov     [rcx+rbx*4], eax
    movsd   xmm0, [r15+EL_A]
    movsd   xmm1, [r15+EL_A+8]
    movsd   xmm2, [rip+bq_w1]
    call    vert_at
    lea     rcx, [rip+bq_vt]
    mov     [rcx+rbx*4], eax
    movsd   xmm0, [r15+EL_A]            # the vertical edge
    movsd   xmm1, [r15+EL_A+8]
    movsd   xmm2, [rip+bq_w0]
    lea     rdi, [rsp+PZ_A]
    call    bm_pt
    movsd   xmm0, [r15+EL_A]
    movsd   xmm1, [r15+EL_A+8]
    movsd   xmm2, [rip+bq_w1]
    lea     rdi, [rsp+PZ_A+24]
    call    bm_pt
    lea     rdi, [rsp+PZ_A]
    lea     rsi, [rsp+PZ_A+24]
    call    mk_line
    movsd   xmm1, xmm0
    xorpd   xmm0, xmm0
    mov     edi, eax
    lea     rcx, [rip+bq_vb]
    mov     esi, [rcx+rbx*4]
    lea     rcx, [rip+bq_vt]
    mov     edx, [rcx+rbx*4]
    call    n_ed
    lea     rcx, [rip+bq_ve]
    mov     [rcx+rbx*4], eax
    inc     ebx
    jmp     1b
2:  xor     ebx, ebx                    # bottom and top edges
3:  cmp     ebx, r14d
    jae     4f
    lea     eax, [rbx+1]
    xor     edx, edx
    div     r14d
    mov     [rsp+PZ_I], edx             # the next point
    lea     edi, [r13+rbx]
    call    el_ptr
    mov     r15, rax
    mov     rdi, r15
    movsd   xmm0, [rip+bq_w0]
    lea     rcx, [rip+bq_vb]
    mov     esi, [rcx+rbx*4]
    mov     eax, [rsp+PZ_I]
    mov     edx, [rcx+rax*4]
    call    el_edge
    lea     rcx, [rip+bq_be]
    mov     [rcx+rbx*4], eax
    mov     rdi, r15
    movsd   xmm0, [rip+bq_w1]
    lea     rcx, [rip+bq_vt]
    mov     esi, [rcx+rbx*4]
    mov     eax, [rsp+PZ_I]
    mov     edx, [rcx+rax*4]
    call    el_edge
    lea     rcx, [rip+bq_te]
    mov     [rcx+rbx*4], eax
    inc     ebx
    jmp     3b
4:  xor     ebx, ebx                    # a wall per element
5:  cmp     ebx, r14d
    jae     .Lpz_lnext
    lea     edi, [r13+rbx]
    call    el_ptr
    mov     r15, rax
    mov     rdi, r15
    call    wall_surface
    mov     edi, eax
    movsd   xmm0, [rip+ws_hint]
    xorpd   xmm1, xmm1
    call    fb_face
    call    fb_loop
    lea     rcx, [rip+bq_be]
    mov     edi, [rcx+rbx*4]
    xor     esi, esi
    call    fb_ce
    lea     eax, [rbx+1]
    xor     edx, edx
    div     r14d
    lea     rcx, [rip+bq_ve]
    mov     edi, [rcx+rdx*4]
    xor     esi, esi
    call    fb_ce
    lea     rcx, [rip+bq_te]
    mov     edi, [rcx+rbx*4]
    mov     esi, 1
    call    fb_ce
    lea     rcx, [rip+bq_ve]
    mov     edi, [rcx+rbx*4]
    mov     esi, 1
    call    fb_ce
    inc     ebx
    jmp     5b
.Lpz_lnext:
    # remember this loop's bottom / top edges for the caps (in the loop's
    # elements: EL_NA / EL_NB hold them now)
    xor     ebx, ebx
6:  cmp     ebx, r14d
    jae     7f
    lea     edi, [r13+rbx]
    call    el_ptr
    lea     rcx, [rip+bq_be]
    mov     edx, [rcx+rbx*4]
    mov     [rax+EL_NA], edx
    lea     rcx, [rip+bq_te]
    mov     edx, [rcx+rbx*4]
    mov     [rax+EL_NB], edx
    inc     ebx
    jmp     6b
7:  inc     r12d
    jmp     .Lpz_loop
.Lpz_caps:
    xor     ebp, ebp                    # bottom (0) and top (1)
.Lpz_cap:
    cmp     ebp, 2
    jae     .Lpz_done
    xor     r12d, r12d                  # each material loop with its holes
.Lpz_region:
    cmp     r12d, [rip+bp_nl]
    jae     .Lpz_capnext
    lea     rax, [rip+bp_dep]
    test    dword ptr [rax+r12*4], 1
    jnz     .Lpz_rnext
    xorpd   xmm0, xmm0                  # the cap's plane
    xorpd   xmm1, xmm1
    movsd   xmm2, [rip+bq_w0]
    test    ebp, ebp
    jz      8f
    movsd   xmm2, [rip+bq_w1]
8:  lea     rdi, [rsp+PZ_A]
    call    bm_pt
    call    plane_xy_here
    mov     edi, ST_PLANE
    lea     rsi, [rsp+PZ_A]
    xorpd   xmm0, xmm0
    xorpd   xmm1, xmm1
    call    mk_surf
    mov     edi, eax
    xorpd   xmm0, xmm0
    xorpd   xmm1, xmm1
    call    fb_face
    mov     edi, r12d
    mov     esi, ebp
    call    cap_loop
    xor     r13d, r13d                  # its holes
9:  cmp     r13d, [rip+bp_nl]
    jae     .Lpz_rnext
    lea     rax, [rip+bp_par]
    cmp     [rax+r13*4], r12d
    jne     10f
    mov     edi, r13d
    mov     esi, ebp
    call    cap_loop
10: inc     r13d
    jmp     9b
.Lpz_rnext:
    inc     r12d
    jmp     .Lpz_region
.Lpz_capnext:
    inc     ebp
    jmp     .Lpz_cap
.Lpz_done:
    call    bb_end
    mov     ebx, eax
    mov     edi, eax
    call    p_bd
    mov     edi, [rax+BD_FIRST]
    mov     esi, [rax+BD_NF]
    lea     rdx, [rip+prism_in]
    call    bd_finish
    mov     eax, ebx
    jmp     .Lpz_out
.Lpz_fail:
    mov     eax, -1
.Lpz_out:
    add     rsp, 136
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
# plane_xy_here - bp_prism's [rsp+PZ_A+24], [rsp+PZ_A+48] = unit U, V
plane_xy_here:
    push    rbx
    lea     rbx, [rsp+16+PZ_A]          # (the caller's frame)
    lea     rdi, [rbx+24]
    lea     rsi, [rip+bm_u]
    movsd   xmm0, [rip+bb_one]
    call    v3scale
    lea     rdi, [rbx+24]
    call    v3norm
    lea     rdi, [rbx+48]
    lea     rsi, [rip+bm_v]
    movsd   xmm0, [rip+bb_one]
    call    v3scale
    lea     rdi, [rbx+48]
    lea     rsi, [rbx+24]
    call    v3dot
    xorpd   xmm0, [rip+bb_negm]
    lea     rdi, [rbx+48]
    lea     rsi, [rbx+24]
    call    v3axpy
    lea     rdi, [rbx+48]
    call    v3norm
    pop     rbx
    ret

# cap_loop(edi=profile loop, esi=0 bottom / 1 top) - a loop of the face being
#   built from the loop's bottom or top edges (kept in EL_NA / EL_NB)
cap_loop:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     r14d, esi
    lea     rax, [rip+bp_lf]
    mov     ebx, [rax+rdi*4]
    lea     rax, [rip+bp_ln]
    mov     r12d, [rax+rdi*4]
    add     r12d, ebx
    call    fb_loop
1:  cmp     ebx, r12d
    jae     9f
    mov     edi, ebx
    call    el_ptr
    mov     edi, [rax+EL_NA]
    test    r14d, r14d
    jz      2f
    mov     edi, [rax+EL_NB]
2:  xor     esi, esi
    call    fb_ce
    inc     ebx
    jmp     1b
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# wall_surface(rdi=element) -> eax = the wall's surface: a plane through the
#   line along the normal, or the cylinder of the arc (from w0)
wall_surface:
    push    rbx
    sub     rsp, 112
    mov     rbx, rdi
    cmp     dword ptr [rbx+EL_TYPE], E_ARC
    je      1f
    movsd   xmm0, [rbx+EL_A]            # O = a at w0, X = along the line,
    movsd   xmm1, [rbx+EL_A+8]          #  Y = the normal made perpendicular
    movsd   xmm2, [rip+bq_w0]
    lea     rdi, [rsp]
    call    bm_pt
    movsd   xmm0, [rbx+EL_B]
    movsd   xmm1, [rbx+EL_B+8]
    movsd   xmm2, [rip+bq_w0]
    lea     rdi, [rsp+72]
    call    bm_pt
    lea     rdi, [rsp+24]
    lea     rsi, [rsp+72]
    lea     rdx, [rsp]
    call    v3sub
    lea     rdi, [rsp+24]
    call    v3norm
    lea     rdi, [rsp+48]
    lea     rsi, [rip+bm_w]
    movsd   xmm0, [rip+bb_one]
    call    v3scale
    lea     rdi, [rsp+48]
    lea     rsi, [rsp+24]
    call    v3dot
    xorpd   xmm0, [rip+bb_negm]
    lea     rdi, [rsp+48]
    lea     rsi, [rsp+24]
    call    v3axpy
    lea     rdi, [rsp+48]
    call    v3norm
    mov     edi, ST_PLANE
    lea     rsi, [rsp]
    xorpd   xmm0, xmm0
    xorpd   xmm1, xmm1
    call    mk_surf
    xorpd   xmm0, xmm0
    movsd   [rip+ws_hint], xmm0
    jmp     9f
1:  movsd   xmm0, [rbx+EL_C]            # O = the centre at w0, X = U, Y = V
    movsd   xmm1, [rbx+EL_C+8]
    movsd   xmm2, [rip+bq_w0]
    lea     rdi, [rsp]
    call    bm_pt
    call    plane_xy
    lea     rdi, [rip+bm_u]
    call    v3len
    mulsd   xmm0, [rbx+EL_R]
    mov     edi, ST_CYL
    lea     rsi, [rsp]
    xorpd   xmm1, xmm1
    call    mk_surf
    push    rax                         # the u hint: the arc's middle angle
    sub     rsp, 8
    movsd   xmm0, [rbx+EL_SW]
    mulsd   xmm0, [rip+bb_half]
    addsd   xmm0, [rbx+EL_T0]
    movsd   [rip+ws_hint], xmm0
    add     rsp, 8
    pop     rax
9:  add     rsp, 112
    pop     rbx
    ret

.section .bss
.align 8
ws_hint:        .skip 8
.text

# =============================================================================
#  Revolutions
# =============================================================================
# rz(rdi=element point (u, v)) -> xmm0 = z along the axis, xmm1 = rho
rz:
    movsd   xmm0, [rdi]
    movsd   xmm1, [rdi+8]
    cmp     dword ptr [rip+br_ax], 0
    je      1f
    movsd   xmm2, xmm0                  # about v: z = v, rho = side u
    movsd   xmm0, xmm1
    movsd   xmm1, xmm2
1:  cvtsi2sd xmm2, dword ptr [rip+br_side]
    mulsd   xmm1, xmm2
    ret

# rot_pt(rdi=out, xmm0=z, xmm1=rho, xmm2=phi) - the point turned by phi
rot_pt:
    push    rbx
    sub     rsp, 32
    mov     rbx, rdi
    movsd   [rsp], xmm0
    movsd   [rsp+8], xmm1
    movsd   xmm0, xmm2
    call    dsincos
    mulsd   xmm1, [rsp+8]
    mulsd   xmm0, [rsp+8]
    movsd   xmm2, [rsp]
    movsd   [rsp+16], xmm0
    movsd   xmm0, xmm1
    movsd   xmm1, [rsp+16]
    mov     rdi, rbx
    lea     rsi, [rip+br_ao]
    lea     rdx, [rip+br_axw]
    lea     rcx, [rip+br_ayw]
    lea     r8, [rip+br_azw]
    call    lin3
    add     rsp, 32
    pop     rbx
    ret

# rot_dir(rdi=out, esi=0 the sketch's u / 1 its v, xmm2=phi) - the direction
#   turned by phi
rot_dir:
    xorpd   xmm0, xmm0                  # (z, rho) of the direction
    xorpd   xmm1, xmm1
    mov     eax, esi
    xor     eax, [rip+br_ax]            # u about u, v about v: along the axis
    jnz     1f
    movsd   xmm0, [rip+bb_one]
    jmp     2f
1:  cvtsi2sd xmm1, dword ptr [rip+br_side]
2:  push    rdi
    sub     rsp, 32
    movsd   [rsp], xmm0
    movsd   [rsp+8], xmm1
    movsd   xmm0, xmm2
    call    dsincos
    mulsd   xmm1, [rsp+8]
    mulsd   xmm0, [rsp+8]
    movsd   [rsp+16], xmm0
    movsd   xmm2, [rsp]
    movsd   xmm0, xmm1
    movsd   xmm1, [rsp+16]
    mov     rdi, [rsp+32]
    xor     esi, esi
    lea     rdx, [rip+br_axw]
    lea     rcx, [rip+br_ayw]
    lea     r8, [rip+br_azw]
    call    lin3
    add     rsp, 32
    pop     rdi
    ret

# revolve_in(rdi=point) -> eax = 1 inside the revolution
revolve_in:
    push    rbx
    sub     rsp, 64
    lea     rsi, [rdi]
    lea     rdi, [rsp]
    lea     rdx, [rip+br_ao]
    call    v3sub
    lea     rdi, [rsp]
    lea     rsi, [rip+br_azw]
    call    v3dot
    movsd   [rsp+24], xmm0              # z
    lea     rdi, [rsp]
    lea     rsi, [rip+br_axw]
    call    v3dot
    movsd   [rsp+32], xmm0              # x
    lea     rdi, [rsp]
    lea     rsi, [rip+br_ayw]
    call    v3dot
    movsd   [rsp+40], xmm0              # y
    xor     ebx, ebx
    cmp     dword ptr [rip+br_full], 0
    jne     1f
    movsd   xmm1, [rsp+32]              # phi in (0, angle)
    call    datan2
    xorpd   xmm1, xmm1
    comisd  xmm0, xmm1
    jae     2f
    addsd   xmm0, [rip+bb_2pi]
2:  comisd  xmm0, xmm1
    jbe     9f
    comisd  xmm0, [rip+br_ang]
    jae     9f
1:  movsd   xmm1, [rsp+32]              # rho
    mulsd   xmm1, xmm1
    movsd   xmm2, [rsp+40]
    mulsd   xmm2, xmm2
    addsd   xmm1, xmm2
    sqrtsd  xmm1, xmm1
    cvtsi2sd xmm2, dword ptr [rip+br_side]
    mulsd   xmm1, xmm2                  # back to the sketch's sign
    movsd   xmm0, [rsp+24]
    cmp     dword ptr [rip+br_ax], 0
    je      3f
    movsd   xmm2, xmm0                  # about v: (u, v) = (rho, z)
    movsd   xmm0, xmm1
    movsd   xmm1, xmm2
3:  call    prof_in
    mov     ebx, eax
9:  mov     eax, ebx
    add     rsp, 64
    pop     rbx
    ret

# onaxis(xmm1=rho) -> eax = 1 if on the axis
onaxis:
    andpd   xmm1, [rip+bb_abs]
    movsd   xmm2, [rip+bp_scale]
    mulsd   xmm2, [rip+bb_axis]
    xor     eax, eax
    comisd  xmm1, xmm2
    setbe   al
    ret

# bp_revolve(edi=axis 0 u / 1 v, xmm0=angle) -> eax = a body: the profile
#   turned about the axis (-1 on failure)
.equ RV_L,    0
.equ RV_FIRST,4
.equ RV_N,    8
.equ RV_I,    12
.equ RV_K,    16
.equ RV_J,    20
.equ RV_T,    24
.equ RV_A,    32                        # O X Y scratch (9 doubles)
.equ RV_B,    104                       # 2 points
.equ RV_ZA,   152
.equ RV_RA,   160
.equ RV_ZB,   168
.equ RV_RB,   176
.equ RV_H,    184
.equ RV_SURF, 192
bp_revolve:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 232
    mov     [rip+br_ax], edi
    cmp     dword ptr [rip+bp_nl], 0
    je      .Lrv_fail
    # the side: the sign of the first point off the axis
    mov     dword ptr [rip+br_side], 1
    xor     ebx, ebx
1:  cmp     ebx, [rip+bp_nel]
    jae     2f
    mov     edi, ebx
    call    el_ptr
    movsd   xmm1, [rax+EL_A+8]          # the radial coordinate (v about u)
    cmp     dword ptr [rip+br_ax], 0
    je      11f
    movsd   xmm1, [rax+EL_A]
11: movsd   [rsp+RV_T], xmm1
    call    onaxis
    test    eax, eax
    jnz     12f
    xorpd   xmm1, xmm1
    comisd  xmm1, [rsp+RV_T]
    jb      2f
    mov     dword ptr [rip+br_side], -1
    jmp     2f
12: inc     ebx
    jmp     1b
2:  # the axis frame in the sketch, then the world
    mov     dword ptr [rip+br_full], 0
    movsd   xmm1, xmm0
    andpd   xmm1, [rip+bb_abs]
    movsd   [rip+br_ang], xmm1
    comisd  xmm1, [rip+bb_full]
    jb      3f
    mov     dword ptr [rip+br_full], 1
    movsd   xmm1, [rip+bb_2pi]
    movsd   [rip+br_ang], xmm1
3:  movsd   [rsp+RV_T], xmm0
    xorpd   xmm0, xmm0
    xorpd   xmm1, xmm1
    xorpd   xmm2, xmm2
    lea     rdi, [rip+br_ao]
    call    bm_pt
    # local directions (u, v, w): about u: Az = u, Ax = side v, Ay = side w;
    # about v: Az = v, Ax = side u, Ay = -side w
    cvtsi2sd xmm7, dword ptr [rip+br_side]
    lea     rdi, [rip+br_azw]
    xorpd   xmm0, xmm0
    xorpd   xmm1, xmm1
    xorpd   xmm2, xmm2
    cmp     dword ptr [rip+br_ax], 0
    jne     4f
    movsd   xmm0, [rip+bb_one]
    call    bm_dir
    lea     rdi, [rip+br_axw]
    xorpd   xmm0, xmm0
    movsd   xmm1, xmm7
    xorpd   xmm2, xmm2
    call    bm_dir
    lea     rdi, [rip+br_ayw]
    xorpd   xmm0, xmm0
    xorpd   xmm1, xmm1
    cvtsi2sd xmm2, dword ptr [rip+br_side]
    call    bm_dir
    jmp     5f
4:  movsd   xmm1, [rip+bb_one]
    call    bm_dir
    lea     rdi, [rip+br_axw]
    cvtsi2sd xmm0, dword ptr [rip+br_side]
    xorpd   xmm1, xmm1
    xorpd   xmm2, xmm2
    call    bm_dir
    lea     rdi, [rip+br_ayw]
    xorpd   xmm0, xmm0
    xorpd   xmm1, xmm1
    cvtsi2sd xmm2, dword ptr [rip+br_side]
    xorpd   xmm2, [rip+bb_negm]
    call    bm_dir
5:  lea     rdi, [rip+br_azw]
    call    v3norm
    lea     rdi, [rip+br_axw]
    call    v3norm
    lea     rdi, [rip+br_ayw]
    call    v3norm
    xorpd   xmm1, xmm1                  # a negative angle turns the other way
    comisd  xmm1, [rsp+RV_T]
    jbe     6f
    lea     rdi, [rip+br_ayw]
    lea     rsi, [rip+br_ayw]
    movsd   xmm0, [rip+bb_one]
    xorpd   xmm0, [rip+bb_negm]
    call    v3scale
    lea     rdi, [rip+br_azw]
    lea     rsi, [rip+br_azw]
    movsd   xmm0, [rip+bb_one]
    xorpd   xmm0, [rip+bb_negm]
    call    v3scale
6:  # patches: a full turn two halves; else 1 (<= pi) or 2
    mov     eax, 2
    cmp     dword ptr [rip+br_full], 0
    jne     7f
    mov     eax, 1
    movsd   xmm0, [rip+br_ang]
    comisd  xmm0, [rip+bb_pi]
    jbe     7f
    mov     eax, 2
7:  mov     [rip+br_np], eax
    cvtsi2sd xmm1, eax
    movsd   xmm0, [rip+br_ang]
    divsd   xmm0, xmm1
    lea     rcx, [rip+br_phi]
    xorpd   xmm2, xmm2
    movsd   [rcx], xmm2
    movsd   [rcx+8], xmm0
    addsd   xmm0, xmm0
    movsd   [rcx+16], xmm0
    call    bb_begin
    xor     r12d, r12d                  # loop
.Lrv_loop:
    cmp     r12d, [rip+bp_nl]
    jae     .Lrv_caps
    lea     rax, [rip+bp_lf]
    mov     r13d, [rax+r12*4]
    lea     rax, [rip+bp_ln]
    mov     r14d, [rax+r12*4]
    mov     [rsp+RV_FIRST], r13d
    mov     [rsp+RV_N], r14d
    call    rv_vertices
    call    rv_edges
    call    rv_faces
    inc     r12d
    jmp     .Lrv_loop
.Lrv_caps:
    cmp     dword ptr [rip+br_full], 0
    jne     .Lrv_done
    xor     ebp, ebp                    # boundary 0 and the last
.Lrv_cap:
    cmp     ebp, 2
    jae     .Lrv_done
    xor     r12d, r12d
.Lrv_region:
    cmp     r12d, [rip+bp_nl]
    jae     .Lrv_capnext
    lea     rax, [rip+bp_dep]
    test    dword ptr [rax+r12*4], 1
    jnz     .Lrv_rnext
    xorpd   xmm2, xmm2                  # the plane: the sketch turned
    test    ebp, ebp
    jz      8f
    movsd   xmm2, [rip+br_ang]
8:  movsd   [rsp+RV_T], xmm2
    lea     rdi, [rsp+RV_A]
    movupd  xmm0, [rip+br_ao]
    movupd  [rdi], xmm0
    mov     rax, [rip+br_ao+16]
    mov     [rdi+16], rax
    lea     rdi, [rsp+RV_A+24]
    xor     esi, esi
    movsd   xmm2, [rsp+RV_T]
    call    rot_dir
    lea     rdi, [rsp+RV_A+48]
    mov     esi, 1
    movsd   xmm2, [rsp+RV_T]
    call    rot_dir
    mov     edi, ST_PLANE
    lea     rsi, [rsp+RV_A]
    xorpd   xmm0, xmm0
    xorpd   xmm1, xmm1
    call    mk_surf
    mov     edi, eax
    xorpd   xmm0, xmm0
    xorpd   xmm1, xmm1
    call    fb_face
    mov     edi, r12d
    mov     esi, ebp
    call    cap_loop                    # (EL_NA / EL_NB: the edges at 0, end)
    xor     r13d, r13d
9:  cmp     r13d, [rip+bp_nl]
    jae     .Lrv_rnext
    lea     rax, [rip+bp_par]
    cmp     [rax+r13*4], r12d
    jne     10f
    mov     edi, r13d
    mov     esi, ebp
    call    cap_loop
10: inc     r13d
    jmp     9b
.Lrv_rnext:
    inc     r12d
    jmp     .Lrv_region
.Lrv_capnext:
    inc     ebp
    jmp     .Lrv_cap
.Lrv_done:
    call    bb_end
    mov     ebx, eax
    mov     edi, eax
    call    p_bd
    mov     edi, [rax+BD_FIRST]
    mov     esi, [rax+BD_NF]
    lea     rdx, [rip+revolve_in]
    call    bd_finish
    mov     eax, ebx
    jmp     .Lrv_out
.Lrv_fail:
    mov     eax, -1
.Lrv_out:
    add     rsp, 232
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# rv_vertices (bp_revolve's frame: loop r13d first, r14d elements) - the
#   vertices at every boundary (one for points on the axis); boundary np of
#   a full turn is boundary 0
rv_vertices:
    push    rbx
    push    r15
    sub     rsp, 40
    xor     ebx, ebx
1:  cmp     ebx, r14d
    jae     9f
    lea     edi, [r13+rbx]
    call    el_ptr
    lea     rdi, [rax+EL_A]
    call    rz
    movsd   [rsp], xmm0
    movsd   [rsp+8], xmm1
    call    onaxis
    lea     rcx, [rip+br_onax]
    mov     [rcx+rbx], al
    xor     r15d, r15d                  # boundary k
2:  cmp     r15d, [rip+br_np]
    ja      8f
    mov     eax, r15d
    cmp     eax, [rip+br_np]
    jne     3f
    cmp     dword ptr [rip+br_full], 0
    je      3f
    lea     rcx, [rip+br_pv]            # full turn: the last is the first
    mov     eax, [rcx+rbx*4]
    jmp     5f
3:  test    r15d, r15d
    jz      4f
    lea     rcx, [rip+br_onax]
    cmp     byte ptr [rcx+rbx], 0
    je      4f
    lea     rcx, [rip+br_pv]            # on the axis: boundary 0's
    mov     eax, [rcx+rbx*4]
    jmp     5f
4:  lea     rcx, [rip+br_phi]
    movsd   xmm2, [rcx+r15*8]
    movsd   xmm0, [rsp]
    movsd   xmm1, [rsp+8]
    lea     rdi, [rsp+16]
    call    rot_pt
    lea     rdi, [rsp+16]
    call    n_vx
5:  imul    ecx, r15d, MAXEL
    add     ecx, ebx
    lea     rdx, [rip+br_pv]
    mov     [rdx+rcx*4], eax
    inc     r15d
    jmp     2b
8:  inc     ebx
    jmp     1b
9:  add     rsp, 40
    pop     r15
    pop     rbx
    ret

# pv(ebx=point, ecx=boundary) -> eax (rv_*: point index wraps at r14d)
pv_at:
    mov     eax, ebx
    cmp     eax, r14d
    jb      1f
    sub     eax, r14d
1:  imul    ecx, ecx, MAXEL
    add     ecx, eax
    lea     rdx, [rip+br_pv]
    mov     eax, [rdx+rcx*4]
    ret

# rv_edges (bp_revolve's frame) - the profile edges at each boundary and the
#   circles each point draws in each patch
rv_edges:
    push    rbx
    push    r15
    push    rbp
    sub     rsp, 128
    xor     ebx, ebx                    # element i
.Lre_el:
    cmp     ebx, r14d
    jae     .Lre_circles
    lea     edi, [r13+rbx]
    call    el_ptr
    mov     rbp, rax
    lea     rdi, [rbp+EL_A]             # on the axis entirely?
    call    rz
    call    onaxis
    mov     [rsp+120], eax
    lea     rdi, [rbp+EL_B]
    call    rz
    call    onaxis
    and     [rsp+120], eax
    cmp     dword ptr [rbp+EL_TYPE], E_ARC    # (an arc is never on it)
    jne     11f
    mov     dword ptr [rsp+120], 0
11: xor     r15d, r15d                  # boundary k
.Lre_k:
    cmp     r15d, [rip+br_np]
    ja      .Lre_elnext
    mov     eax, r15d                   # the full turn's last: the first's
    cmp     eax, [rip+br_np]
    jne     1f
    cmp     dword ptr [rip+br_full], 0
    je      1f
    lea     rcx, [rip+br_pe]
    mov     eax, [rcx+rbx*4]
    jmp     .Lre_store
1:  cmp     dword ptr [rsp+120], 0      # on the axis: one edge for both ends
    je      2f
    test    r15d, r15d
    jz      2f
    lea     rcx, [rip+br_pe]
    mov     eax, [rcx+rbx*4]
    jmp     .Lre_store
2:  lea     rcx, [rip+br_phi]
    movsd   xmm0, [rcx+r15*8]
    movsd   [rsp+112], xmm0
    cmp     dword ptr [rbp+EL_TYPE], E_ARC
    je      3f
    lea     rdi, [rbp+EL_A]             # a line
    call    rz
    lea     rdi, [rsp]
    movsd   xmm2, [rsp+112]
    call    rot_pt
    lea     rdi, [rbp+EL_B]
    call    rz
    lea     rdi, [rsp+24]
    movsd   xmm2, [rsp+112]
    call    rot_pt
    lea     rdi, [rsp]
    lea     rsi, [rsp+24]
    call    mk_line
    movsd   xmm1, xmm0
    xorpd   xmm0, xmm0
    jmp     4f
3:  lea     rdi, [rbp+EL_C]             # an arc: its circle turned
    call    rz
    lea     rdi, [rsp]
    movsd   xmm2, [rsp+112]
    call    rot_pt
    lea     rdi, [rsp+24]
    xor     esi, esi
    movsd   xmm2, [rsp+112]
    call    rot_dir
    lea     rdi, [rsp+48]
    mov     esi, 1
    movsd   xmm2, [rsp+112]
    call    rot_dir
    mov     edi, CT_CIRCLE
    lea     rsi, [rsp]
    movsd   xmm0, [rbp+EL_R]
    movsd   xmm1, xmm0
    call    mk_conic
    movsd   xmm0, [rbp+EL_T0]
    movsd   xmm1, xmm0
    addsd   xmm1, [rbp+EL_SW]
4:  movsd   [rsp+96], xmm0
    movsd   [rsp+104], xmm1
    mov     [rsp+88], eax
    mov     ecx, r15d
    call    pv_at
    mov     [rsp+92], eax
    push    rbx
    inc     ebx
    mov     ecx, r15d
    call    pv_at
    pop     rbx
    mov     edx, eax
    mov     esi, [rsp+92]
    mov     edi, [rsp+88]
    movsd   xmm0, [rsp+96]
    movsd   xmm1, [rsp+104]
    call    n_ed
.Lre_store:
    imul    ecx, r15d, MAXEL
    add     ecx, ebx
    lea     rdx, [rip+br_pe]
    mov     [rdx+rcx*4], eax
    test    r15d, r15d                  # caps: the edges at 0 and at the end
    jnz     5f
    mov     ecx, eax
    lea     edi, [r13+rbx]
    push    rcx
    sub     rsp, 8
    call    el_ptr
    add     rsp, 8
    pop     rcx
    mov     [rax+EL_NA], ecx
5:  cmp     r15d, [rip+br_np]
    jne     6f
    mov     ecx, eax
    push    rcx
    sub     rsp, 8
    lea     edi, [r13+rbx]
    call    el_ptr
    add     rsp, 8
    pop     rcx
    mov     [rax+EL_NB], ecx
6:  inc     r15d
    jmp     .Lre_k
.Lre_elnext:
    inc     ebx
    jmp     .Lre_el
.Lre_circles:
    xor     ebx, ebx                    # point j
.Lre_pt:
    cmp     ebx, r14d
    jae     .Lre_out
    lea     edi, [r13+rbx]
    call    el_ptr
    lea     rdi, [rax+EL_A]
    call    rz
    movsd   [rsp+112], xmm0             # z, rho
    movsd   [rsp+120], xmm1
    xor     r15d, r15d                  # patch k
.Lre_patch:
    cmp     r15d, [rip+br_np]
    jae     .Lre_ptnext
    lea     rcx, [rip+br_onax]
    cmp     byte ptr [rcx+rbx], 0
    je      7f
    mov     ecx, r15d                   # a pole: a degenerate edge
    call    pv_at
    mov     esi, eax
    mov     edx, eax
    xor     edi, edi
    xorpd   xmm0, xmm0
    xorpd   xmm1, xmm1
    call    n_ed
    push    rax
    sub     rsp, 8
    mov     edi, eax
    call    p_ed
    or      dword ptr [rax+ED_FLAGS], EF_DEGEN
    add     rsp, 8
    pop     rax
    jmp     8f
7:  lea     rdi, [rsp]                  # a circle about the axis
    movsd   xmm0, [rsp+112]
    lea     rsi, [rip+br_azw]
    lea     rdi, [rsp]
    lea     rsi, [rip+br_ao]
    lea     rdx, [rip+br_azw]
    xor     ecx, ecx
    xor     r8d, r8d
    call    lin3
    lea     rdi, [rsp+24]
    movupd  xmm0, [rip+br_axw]
    movupd  [rdi], xmm0
    mov     rax, [rip+br_axw+16]
    mov     [rdi+16], rax
    lea     rdi, [rsp+48]
    movupd  xmm0, [rip+br_ayw]
    movupd  [rdi], xmm0
    mov     rax, [rip+br_ayw+16]
    mov     [rdi+16], rax
    mov     edi, CT_CIRCLE
    lea     rsi, [rsp]
    movsd   xmm0, [rsp+120]
    movsd   xmm1, xmm0
    call    mk_conic
    mov     [rsp+88], eax
    mov     ecx, r15d
    call    pv_at
    mov     [rsp+92], eax
    lea     ecx, [r15+1]
    call    pv_at
    mov     edx, eax
    mov     esi, [rsp+92]
    mov     edi, [rsp+88]
    lea     rcx, [rip+br_phi]
    movsd   xmm0, [rcx+r15*8]
    movsd   xmm1, [rcx+r15*8+8]
    call    n_ed
8:  imul    ecx, r15d, MAXEL
    add     ecx, ebx
    lea     rdx, [rip+br_ce]
    mov     [rdx+rcx*4], eax
    inc     r15d
    jmp     .Lre_patch
.Lre_ptnext:
    inc     ebx
    jmp     .Lre_pt
.Lre_out:
    add     rsp, 128
    pop     rbp
    pop     r15
    pop     rbx
    ret

# rv_faces (bp_revolve's frame) - a face per element (off the axis) per patch
rv_faces:
    push    rbx
    push    r15
    push    rbp
    sub     rsp, 160
    xor     ebx, ebx
.Lrf_el:
    cmp     ebx, r14d
    jae     .Lrf_out
    lea     edi, [r13+rbx]
    call    el_ptr
    mov     rbp, rax
    lea     rdi, [rbp+EL_A]
    call    rz
    movsd   [rsp+96], xmm0              # za, ra
    movsd   [rsp+104], xmm1
    lea     rdi, [rbp+EL_B]
    call    rz
    movsd   [rsp+112], xmm0             # zb, rb
    movsd   [rsp+120], xmm1
    movsd   xmm1, [rsp+104]
    call    onaxis
    mov     [rsp+152], eax
    movsd   xmm1, [rsp+120]
    call    onaxis
    and     eax, [rsp+152]
    cmp     dword ptr [rbp+EL_TYPE], E_ARC
    je      1f
    test    eax, eax
    jnz     .Lrf_elnext                 # a line on the axis: no face
1:
    xor     r15d, r15d
.Lrf_patch:
    cmp     r15d, [rip+br_np]
    jae     .Lrf_elnext
    lea     rcx, [rip+br_phi]           # the u hint: the patch's middle
    movsd   xmm0, [rcx+r15*8]
    addsd   xmm0, [rcx+r15*8+8]
    mulsd   xmm0, [rip+bb_half]
    movsd   [rsp+128], xmm0
    xorpd   xmm0, xmm0
    movsd   [rsp+136], xmm0             # v hint
    call    rv_surface
    mov     edi, eax
    movsd   xmm0, [rsp+128]
    movsd   xmm1, [rsp+136]
    call    fb_face
    call    fb_loop
    imul    ecx, r15d, MAXEL            # PE(i, k) forwards
    add     ecx, ebx
    lea     rdx, [rip+br_pe]
    mov     edi, [rdx+rcx*4]
    xor     esi, esi
    call    fb_ce
    lea     eax, [rbx+1]                # CE(i+1, k) forwards
    cmp     eax, r14d
    jb      1f
    xor     eax, eax
1:  imul    ecx, r15d, MAXEL
    add     ecx, eax
    lea     rdx, [rip+br_ce]
    mov     edi, [rdx+rcx*4]
    xor     esi, esi
    call    fb_ce
    lea     ecx, [r15+1]                # PE(i, k+1) backwards
    imul    ecx, ecx, MAXEL
    add     ecx, ebx
    lea     rdx, [rip+br_pe]
    mov     edi, [rdx+rcx*4]
    mov     esi, 1
    call    fb_ce
    imul    ecx, r15d, MAXEL            # CE(i, k) backwards
    add     ecx, ebx
    lea     rdx, [rip+br_ce]
    mov     edi, [rdx+rcx*4]
    mov     esi, 1
    call    fb_ce
    inc     r15d
    jmp     .Lrf_patch
.Lrf_elnext:
    inc     ebx
    jmp     .Lrf_el
.Lrf_out:
    add     rsp, 160
    pop     rbp
    pop     r15
    pop     rbx
    ret

# rv_surface (rv_faces' frame: rbp=element, za ra zb rb at [rsp+8+96..]) ->
#   eax = the surface the element sweeps; may change the hints
rv_surface:
    push    rbx
    sub     rsp, 96
    lea     rbx, [rsp+112]              # rv_faces' frame
    cmp     dword ptr [rbp+EL_TYPE], E_ARC
    je      .Lrs_arc
    movsd   xmm1, [rbx+104]             # ra - rb tiny: a cylinder
    subsd   xmm1, [rbx+120]
    call    onaxis
    test    eax, eax
    jz      1f
    lea     rdi, [rsp]
    call    axis_frame
    mov     edi, ST_CYL
    lea     rsi, [rsp]
    movsd   xmm0, [rbx+104]
    xorpd   xmm1, xmm1
    call    mk_surf
    jmp     .Lrs_out
1:  movsd   xmm1, [rbx+96]              # za - zb tiny: a plane across the axis
    subsd   xmm1, [rbx+112]
    call    onaxis
    test    eax, eax
    jz      2f
    lea     rdi, [rsp]
    call    axis_frame
    lea     rdi, [rsp]                  # O = Ao + z Az
    lea     rsi, [rip+br_azw]
    movsd   xmm0, [rbx+96]
    call    v3axpy
    mov     edi, ST_PLANE
    lea     rsi, [rsp]
    xorpd   xmm0, xmm0
    xorpd   xmm1, xmm1
    call    mk_surf
    jmp     .Lrs_out
2:  # a cone: from the narrow end s to the wide end l, Z towards l
    movsd   xmm0, [rbx+96]              # s = a, l = b unless rb < ra
    movsd   xmm1, [rbx+104]
    movsd   xmm2, [rbx+112]
    movsd   xmm3, [rbx+120]
    comisd  xmm3, xmm1
    jae     3f
    movsd   xmm4, xmm0
    movsd   xmm0, xmm2
    movsd   xmm2, xmm4
    movsd   xmm4, xmm1
    movsd   xmm1, xmm3
    movsd   xmm3, xmm4
3:  movsd   [rsp+72], xmm0              # zs, rs, dz = zl - zs, dr = rl - rs
    movsd   [rsp+80], xmm1
    subsd   xmm2, xmm0
    subsd   xmm3, xmm1
    movsd   [rsp+88], xmm3
    movsd   xmm0, xmm2
    movsd   [rbx+152], xmm2             # (dz kept for the sign)
    lea     rdi, [rsp]
    call    axis_frame
    lea     rdi, [rsp]                  # O = Ao + zs Az
    lea     rsi, [rip+br_azw]
    movsd   xmm0, [rsp+72]
    call    v3axpy
    xorpd   xmm0, xmm0                  # dz < 0: Y = -Ay (Z = X x Y = -Az),
    comisd  xmm0, [rbx+152]             #  u = -phi
    jbe     4f
    lea     rdi, [rsp+48]
    lea     rsi, [rsp+48]
    movsd   xmm0, [rip+bb_one]
    xorpd   xmm0, [rip+bb_negm]
    call    v3scale
    movsd   xmm0, [rbx+128]
    xorpd   xmm0, [rip+bb_negm]
    movsd   [rbx+128], xmm0
4:  movsd   xmm0, [rsp+88]              # half angle atan2(dr, |dz|)
    movsd   xmm1, [rbx+152]
    andpd   xmm1, [rip+bb_abs]
    call    datan2
    movsd   xmm1, xmm0
    mov     edi, ST_CONE
    lea     rsi, [rsp]
    movsd   xmm0, [rsp+80]
    call    mk_surf
    jmp     .Lrs_out
.Lrs_arc:
    lea     rdi, [rbp+EL_C]
    call    rz
    movsd   [rsp+72], xmm0              # zc, rc
    movsd   [rsp+80], xmm1
    lea     rdi, [rsp]
    call    axis_frame
    lea     rdi, [rsp]
    lea     rsi, [rip+br_azw]
    movsd   xmm0, [rsp+72]
    call    v3axpy
    movsd   xmm1, [rsp+80]
    call    onaxis
    test    eax, eax
    jz      5f
    mov     edi, ST_SPHERE
    lea     rsi, [rsp]
    movsd   xmm0, [rbp+EL_R]
    xorpd   xmm1, xmm1
    call    mk_surf
    jmp     .Lrs_out
5:  # a torus; the v hint: the arc's middle seen from its centre
    movsd   xmm0, [rip+bb_half]
    mov     rdi, rbp
    lea     rsi, [rsp+88]
    sub     rsp, 16
    lea     rsi, [rsp]
    call    el_at
    lea     rdi, [rsp]
    call    rz
    add     rsp, 16
    subsd   xmm0, [rsp+72]              # (dz, drho)
    subsd   xmm1, [rsp+80]
    call    datan2
    movsd   [rbx+136], xmm0
    mov     edi, ST_TORUS
    lea     rsi, [rsp]
    movsd   xmm0, [rsp+80]
    movsd   xmm1, [rbp+EL_R]
    call    mk_surf
.Lrs_out:
    add     rsp, 96
    pop     rbx
    ret

# axis_frame(rdi=out O X Y) - the axis origin, Ax, Ay
axis_frame:
    movupd  xmm0, [rip+br_ao]
    movupd  [rdi], xmm0
    mov     rax, [rip+br_ao+16]
    mov     [rdi+16], rax
    movupd  xmm0, [rip+br_axw]
    movupd  [rdi+24], xmm0
    mov     rax, [rip+br_axw+16]
    mov     [rdi+40], rax
    movupd  xmm0, [rip+br_ayw]
    movupd  [rdi+48], xmm0
    mov     rax, [rip+br_ayw+16]
    mov     [rdi+64], rax
    ret

.section .note.GNU-stack,"",@progbits
