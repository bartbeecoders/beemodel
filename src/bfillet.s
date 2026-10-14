# =============================================================================
#  BeeModel - B-rep fillets and chamfers on straight edges between planes
#
#  The edges the selector picks (all sharp ones, vertical, horizontal, top,
#  bottom - as for meshes) must be lines between two planar faces, no two
#  of them meeting at a vertex (corners where rounded edges meet would need
#  blends: the feature then falls back to the mesh). Each edge's corner is
#  cut off by a boolean: a prism along the edge whose section is the corner
#  between the faces' planes and the rolling ball's arc (a cylinder tangent
#  to both planes) - or the chamfer's line - set back from the edge by
#  r / tan(half the angle between the faces). A convex edge loses that
#  material (difference, the prism reaching past the edge's ends), a
#  concave one gains it (union, the prism exactly as long as the edge).
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "brep.inc"

.globl bk_fillet

.equ MAXFE,     64                      # picked edges
.equ FE_SZ,     112                     # a picked edge
.equ FE_P0,     0                       # its ends
.equ FE_P1,     24
.equ FE_N1,     48                      # its faces' outward normals
.equ FE_N2,     72
.equ FE_D1,     96                      # (unused)
.equ EL_SZ,     96                      # (bbuild.s's profile elements)
.equ EL_TYPE,   0
.equ EL_A,      8
.equ EL_B,      24
.equ EL_C,      40
.equ EL_R,      56
.equ EL_T0,     64
.equ EL_SW,     72
.equ E_LINE,    1
.equ E_ARC,     3

.section .rodata
.align 16
fl_absm:        .quad 0x7fffffffffffffff, 0x7fffffffffffffff
fl_negm:        .quad 0x8000000000000000, 0x8000000000000000
fl_one:         .double 1.0
fl_half:        .double 0.5
fl_pi:          .double 3.14159265358979323846
fl_2pi:         .double 6.28318530717958647692
fl_sharp:       .double 0.9             # faces' normals closer: not an edge
fl_vtol:        .double 0.98            # vertical: dy^2 > 0.98 len^2
fl_htol:        .double 1.0e-4          # horizontal: dy^2 < 1e-4 len^2
fl_ytol:        .double 1.0e-4          # top / bottom: of the height
fl_weld:        .double 1.0e-7
fl_margin:      .double 0.25

.section .bss
.align 8
fe_rec:         .skip FE_SZ*MAXFE
fe_n:           .skip 4
fl_body:        .skip 4
fl_sel:         .skip 4
fl_cham:        .skip 4
fl_r:           .skip 8
fl_ymin:        .skip 8
fl_ymax:        .skip 8
fl_size:        .skip 8
fl_els:         .skip EL_SZ*3
fl_frame:       .skip 96                # O U V W

.text

# bk_fillet(edi=body, esi=selector, edx=1 chamfer, xmm0=radius / distance)
#   -> eax = the new body, or -1
bk_fillet:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 24
    mov     [rip+fl_body], edi
    mov     [rip+fl_sel], esi
    mov     [rip+fl_cham], edx
    movsd   [rip+fl_r], xmm0
    mov     dword ptr [rip+fe_n], 0
    call    bd_reach
    movsd   [rip+fl_size], xmm0
    call    y_range
    # the edges: each once (marks cleared, then set)
    mov     edi, [rip+fl_body]
    lea     rsi, [rip+mark_clear]
    call    body_coedges
    mov     edi, [rip+fl_body]
    lea     rsi, [rip+pick]
    call    body_coedges
    cmp     dword ptr [rip+fe_n], 0
    je      .Lfl_same
    cmp     dword ptr [rip+fe_n], MAXFE
    jae     .Lfl_fail
    call    shared_ends                 # rounded edges meeting: not simple
    test    eax, eax
    jnz     .Lfl_fail
    xor     ebx, ebx
.Lfl_edge:
    cmp     ebx, [rip+fe_n]
    jae     .Lfl_done
    mov     edi, ebx
    call    corner_tool                 # -> eax = the tool, edx = op
    test    eax, eax
    js      .Lfl_fail
    mov     esi, eax
    mov     edi, [rip+fl_body]
    call    bk_bool
    test    eax, eax
    js      .Lfl_fail
    mov     [rip+fl_body], eax
    inc     ebx
    jmp     .Lfl_edge
.Lfl_same:
.Lfl_done:
    mov     eax, [rip+fl_body]
    jmp     .Lfl_out
.Lfl_fail:
    mov     eax, -1
.Lfl_out:
    add     rsp, 24
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# body_coedges(edi=body, rsi=function (rax=coedge, edx=index, ecx=face)) -
#   every coedge of every face
body_coedges:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 24
    mov     [rsp], rsi
    call    p_bd
    mov     ebx, [rax+BD_FIRST]
    mov     r12d, [rax+BD_NF]
    add     r12d, ebx
1:  cmp     ebx, r12d
    jae     9f
    mov     edi, ebx
    call    p_fc
    mov     r13d, [rax+FC_LOOP]
    mov     r14d, [rax+FC_NLOOP]
    add     r14d, r13d
2:  cmp     r13d, r14d
    jae     5f
    mov     edi, r13d
    call    p_lp
    mov     r15d, [rax+LP_FIRST]
    mov     ebp, [rax+LP_N]
    add     ebp, r15d
3:  cmp     r15d, ebp
    jae     4f
    mov     edi, r15d
    call    p_ce
    mov     edx, r15d
    mov     ecx, ebx
    call    [rsp]
    inc     r15d
    jmp     3b
4:  inc     r13d
    jmp     2b
5:  inc     ebx
    jmp     1b
9:  add     rsp, 24
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

mark_clear:
    sub     rsp, 8
    mov     edi, [rax+CE_EDGE]
    call    p_ed
    mov     dword ptr [rax+ED_MARK], 0
    add     rsp, 8
    ret

# y_range - fl_ymin / fl_ymax over the body's vertices
y_range:
    sub     rsp, 8
    movsd   xmm0, [rip+fl_size]
    mulsd   xmm0, [rip+fl_size]
    mulsd   xmm0, [rip+fl_size]
    addsd   xmm0, [rip+fl_one]
    movsd   xmm1, xmm0
    xorpd   xmm1, [rip+fl_negm]
    movsd   [rip+fl_ymin], xmm0         # (+big, -big)
    movsd   [rip+fl_ymax], xmm1
    mov     edi, [rip+fl_body]
    lea     rsi, [rip+y_add]
    call    body_coedges
    add     rsp, 8
    ret
y_add:
    sub     rsp, 8
    mov     edi, [rax+CE_EDGE]
    call    p_ed
    mov     edi, [rax+ED_V0]
    call    p_vx
    movsd   xmm0, [rax+8]
    movsd   xmm1, [rip+fl_ymin]
    minsd   xmm1, xmm0
    movsd   [rip+fl_ymin], xmm1
    movsd   xmm1, [rip+fl_ymax]
    maxsd   xmm1, xmm0
    movsd   [rip+fl_ymax], xmm1
    add     rsp, 8
    ret

# pick(rax=coedge, edx=index, ecx=face) - its edge recorded when picked
#   (once, from its first coedge)
.equ PK_CE,   0
.equ PK_F,    8
.equ PK_E,    16
.equ PK_P0,   24
.equ PK_P1,   48
.equ PK_N,    72                        # the two normals
.equ PK_D,    120
.equ PK_T,    144
pick:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 168
    mov     [rsp+PK_CE], rax
    mov     [rsp+PK_F], ecx
    mov     ebx, [rax+CE_EDGE]
    mov     edi, ebx
    call    p_ed
    mov     r12, rax
    cmp     dword ptr [r12+ED_MARK], 0
    jne     .Lpk_out
    mov     dword ptr [r12+ED_MARK], 1
    test    dword ptr [r12+ED_FLAGS], EF_DEGEN
    jnz     .Lpk_out
    mov     edi, [r12+ED_CURVE]
    call    p_cv
    cmp     dword ptr [rax+CV_TYPE], CT_LINE
    jne     .Lpk_out
    mov     edi, [r12+ED_V0]            # its ends
    call    p_vx
    movupd  xmm0, [rax]
    movupd  [rsp+PK_P0], xmm0
    mov     rcx, [rax+16]
    mov     [rsp+PK_P0+16], rcx
    mov     edi, [r12+ED_V1]
    call    p_vx
    movupd  xmm0, [rax]
    movupd  [rsp+PK_P1], xmm0
    mov     rcx, [rax+16]
    mov     [rsp+PK_P1+16], rcx
    # the selector
    lea     rdi, [rsp+PK_D]
    lea     rsi, [rsp+PK_P1]
    lea     rdx, [rsp+PK_P0]
    call    v3sub
    lea     rdi, [rsp+PK_D]
    lea     rsi, [rsp+PK_D]
    call    v3dot
    movsd   [rsp+PK_T], xmm0            # len^2
    mov     eax, [rip+fl_sel]
    test    eax, eax
    jz      .Lpk_faces
    cmp     eax, 3
    jae     .Lpk_level
    movsd   xmm1, [rsp+PK_D+8]
    mulsd   xmm1, xmm1                  # dy^2
    cmp     eax, 1
    jne     1f
    mulsd   xmm0, [rip+fl_vtol]         # vertical
    comisd  xmm1, xmm0
    jbe     .Lpk_out
    jmp     .Lpk_faces
1:  mulsd   xmm0, [rip+fl_htol]         # horizontal
    comisd  xmm1, xmm0
    jae     .Lpk_out
    jmp     .Lpk_faces
.Lpk_level:
    movsd   xmm2, [rip+fl_ymax]
    subsd   xmm2, [rip+fl_ymin]
    mulsd   xmm2, [rip+fl_ytol]
    movsd   xmm0, [rsp+PK_P0+8]
    movsd   xmm1, [rsp+PK_P1+8]
    cmp     eax, 3
    jne     2f
    minsd   xmm0, xmm1                  # top: both ends at the top
    addsd   xmm0, xmm2
    comisd  xmm0, [rip+fl_ymax]
    jb      .Lpk_out
    jmp     .Lpk_faces
2:  maxsd   xmm0, xmm1                  # bottom
    subsd   xmm0, xmm2
    comisd  xmm0, [rip+fl_ymin]
    ja      .Lpk_out
.Lpk_faces:
    # its two faces: this coedge's and the other coedge's; both planes
    mov     edi, [rsp+PK_F]
    call    face_normal
    test    eax, eax
    jz      .Lpk_out
    movupd  xmm0, [rip+fn_n]
    movupd  [rsp+PK_N], xmm0
    mov     rcx, [rip+fn_n+16]
    mov     [rsp+PK_N+16], rcx
    mov     edi, ebx                    # the other face
    mov     esi, [rsp+PK_F]
    call    other_face
    test    eax, eax
    js      .Lpk_out
    mov     edi, eax
    call    face_normal
    test    eax, eax
    jz      .Lpk_out
    movupd  xmm0, [rip+fn_n]
    movupd  [rsp+PK_N+24], xmm0
    mov     rcx, [rip+fn_n+16]
    mov     [rsp+PK_N+40], rcx
    lea     rdi, [rsp+PK_N]             # sharp enough
    lea     rsi, [rsp+PK_N+24]
    call    v3dot
    andpd   xmm0, [rip+fl_absm]
    comisd  xmm0, [rip+fl_sharp]
    jae     .Lpk_out
    mov     eax, [rip+fe_n]             # recorded: P0 -> P1 as this coedge
    cmp     eax, MAXFE                  #  walks it (its face is face 1)
    jae     .Lpk_full
    imul    rdi, rax, FE_SZ
    lea     rcx, [rip+fe_rec]
    add     rdi, rcx
    mov     rax, [rsp+PK_CE]
    lea     rsi, [rsp+PK_P0]
    lea     rdx, [rsp+PK_P1]
    cmp     dword ptr [rax+CE_REV], 0
    je      3f
    xchg    rsi, rdx
3:  movupd  xmm0, [rsi]
    movupd  [rdi+FE_P0], xmm0
    mov     rcx, [rsi+16]
    mov     [rdi+FE_P0+16], rcx
    movupd  xmm0, [rdx]
    movupd  [rdi+FE_P1], xmm0
    mov     rcx, [rdx+16]
    mov     [rdi+FE_P1+16], rcx
    lea     rsi, [rsp+PK_N]
    lea     rdi, [rdi+FE_N1]
    mov     ecx, 6
    rep     movsq
.Lpk_full:
    inc     dword ptr [rip+fe_n]
.Lpk_out:
    add     rsp, 168
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# face_normal(edi=face) -> eax = 1 if it is a plane: fn_n = its outward normal
face_normal:
    push    rbx
    call    p_fc
    mov     rbx, rax
    mov     edi, [rbx+FC_SURF]
    call    p_sf
    xor     ecx, ecx
    cmp     dword ptr [rax+SF_TYPE], ST_PLANE
    jne     9f
    movupd  xmm0, [rax+SF_Z]
    movupd  [rip+fn_n], xmm0
    mov     rcx, [rax+SF_Z+16]
    mov     [rip+fn_n+16], rcx
    cmp     dword ptr [rbx+FC_SENSE], 0
    je      1f
    movupd  xmm0, [rip+fn_n]
    xorpd   xmm0, [rip+fl_negm]
    movupd  [rip+fn_n], xmm0
    movsd   xmm0, [rip+fn_n+16]
    xorpd   xmm0, [rip+fl_negm]
    movsd   [rip+fn_n+16], xmm0
1:  mov     ecx, 1
9:  mov     eax, ecx
    pop     rbx
    ret

.section .bss
.align 8
fn_n:           .skip 24
of_e:           .skip 4
of_f:           .skip 4
of_r:           .skip 4
.text

# other_face(edi=edge, esi=a face using it) -> eax = the other face, or -1
other_face:
    sub     rsp, 8
    mov     [rip+of_e], edi
    mov     [rip+of_f], esi
    mov     dword ptr [rip+of_r], -1
    mov     edi, [rip+fl_body]
    lea     rsi, [rip+of_look]
    call    body_coedges
    mov     eax, [rip+of_r]
    add     rsp, 8
    ret
of_look:
    mov     edx, [rax+CE_EDGE]
    cmp     edx, [rip+of_e]
    jne     9f
    cmp     ecx, [rip+of_f]
    je      9f
    mov     [rip+of_r], ecx
9:  ret

# shared_ends -> eax = 1 if two picked edges meet at a point
shared_ends:
    push    rbx
    push    r12
    sub     rsp, 8
    movsd   xmm7, [rip+fl_size]
    mulsd   xmm7, [rip+fl_weld]
    xor     ebx, ebx
1:  cmp     ebx, [rip+fe_n]
    jae     8f
    lea     r12d, [rbx+1]
2:  cmp     r12d, [rip+fe_n]
    jae     3f
    xor     ecx, ecx                    # ends (a of i, b of j) all four ways
4:  cmp     ecx, 4
    jae     5f
    imul    rdi, rbx, FE_SZ
    imul    rsi, r12, FE_SZ
    lea     rax, [rip+fe_rec]
    add     rdi, rax
    add     rsi, rax
    test    ecx, 1
    jz      41f
    add     rdi, 24
41: test    ecx, 2
    jz      42f
    add     rsi, 24
42: push    rcx
    sub     rsp, 8
    call    v3dist
    add     rsp, 8
    pop     rcx
    comisd  xmm0, xmm7
    jbe     9f
    inc     ecx
    jmp     4b
5:  inc     r12d
    jmp     2b
3:  inc     ebx
    jmp     1b
8:  xor     eax, eax
    add     rsp, 8
    pop     r12
    pop     rbx
    ret
9:  mov     eax, 1
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# corner_tool(edi=picked edge) -> eax = the prism cutting (or filling) its
#   corner, edx = the boolean (1 difference: convex, 0 union: concave)
.equ CT_W,    0                         # edge direction, length
.equ CT_L,    24
.equ CT_D1,   32                        # into face 1, face 2 (in their planes)
.equ CT_D2,   56
.equ CT_V,    80
.equ CT_S,    104                       # setback
.equ CT_CVX,  112
.equ CT_A,    120                       # scratch 2D
.equ CT_E,    136
corner_tool:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 160
    imul    rbx, rdi, FE_SZ
    lea     rax, [rip+fe_rec]
    add     rbx, rax
    lea     rdi, [rsp+CT_W]             # W = P1 - P0, L
    lea     rsi, [rbx+FE_P1]
    lea     rdx, [rbx+FE_P0]
    call    v3sub
    lea     rdi, [rsp+CT_W]
    call    v3norm
    movsd   [rsp+CT_L], xmm0
    # into face 1: d1 = n1 x W (the face lies left of its coedge, which walks
    # P0 -> P1); into face 2: d2 = W x n2 (its coedge walks the other way)
    lea     rdi, [rsp+CT_D1]
    lea     rsi, [rbx+FE_N1]
    lea     rdx, [rsp+CT_W]
    call    v3cross
    lea     rdi, [rsp+CT_D2]
    lea     rsi, [rsp+CT_W]
    lea     rdx, [rbx+FE_N2]
    call    v3cross
    # convex: d1 . n2 < 0
    lea     rdi, [rsp+CT_D1]
    lea     rsi, [rbx+FE_N2]
    call    v3dot
    xor     eax, eax
    xorpd   xmm1, xmm1
    comisd  xmm0, xmm1
    setb    al
    mov     [rsp+CT_CVX], eax
    # setback s = r / tan(phi / 2), cos phi = d1 . d2
    lea     rdi, [rsp+CT_D1]
    lea     rsi, [rsp+CT_D2]
    call    v3dot
    movsd   xmm1, [rip+fl_one]          # tan(phi/2) = sqrt((1-c)/(1+c))
    subsd   xmm1, xmm0
    movsd   xmm2, [rip+fl_one]
    addsd   xmm2, xmm0
    divsd   xmm1, xmm2
    sqrtsd  xmm1, xmm1
    movsd   xmm0, [rip+fl_r]
    cmp     dword ptr [rip+fl_cham], 0
    jne     1f
    divsd   xmm0, xmm1
1:  movsd   [rsp+CT_S], xmm0
    # the section's frame: O = P0, U = d1, V = W x U, W
    lea     rdi, [rsp+CT_V]
    lea     rsi, [rsp+CT_W]
    lea     rdx, [rsp+CT_D1]
    call    v3cross
    lea     rdi, [rip+fl_frame]
    lea     rsi, [rbx+FE_P0]
    mov     ecx, 3
    rep     movsq
    lea     rsi, [rsp+CT_D1]
    mov     ecx, 3
    rep     movsq
    lea     rsi, [rsp+CT_V]
    mov     ecx, 3
    rep     movsq
    lea     rsi, [rsp+CT_W]
    mov     ecx, 3
    rep     movsq
    lea     rdi, [rip+fl_frame]
    call    bm_set
    # the section: E (0, 0), T1 = s (1, 0), T2 = s (d2.U, d2.V)
    lea     rdi, [rsp+CT_D2]
    lea     rsi, [rsp+CT_D1]
    call    v3dot
    mulsd   xmm0, [rsp+CT_S]
    movsd   [rsp+CT_A], xmm0            # T2
    lea     rdi, [rsp+CT_D2]
    lea     rsi, [rsp+CT_V]
    call    v3dot
    mulsd   xmm0, [rsp+CT_S]
    movsd   [rsp+CT_A+8], xmm0
    lea     rdi, [rip+fl_els]           # E -> T1
    mov     ecx, EL_SZ*3/8
    xor     eax, eax
    rep     stosq
    lea     r12, [rip+fl_els]
    mov     dword ptr [r12+EL_TYPE], E_LINE
    movsd   xmm0, [rsp+CT_S]
    movsd   [r12+EL_B], xmm0
    lea     r13, [r12+EL_SZ]            # T1 -> T2: the arc or the chamfer
    movsd   [r13+EL_A], xmm0
    movsd   xmm0, [rsp+CT_A]
    movsd   [r13+EL_B], xmm0
    movsd   xmm0, [rsp+CT_A+8]
    movsd   [r13+EL_B+8], xmm0
    mov     dword ptr [r13+EL_TYPE], E_LINE
    cmp     dword ptr [rip+fl_cham], 0
    jne     2f
    call    ct_arc
2:  lea     r13, [r12+2*EL_SZ]          # T2 -> E
    mov     dword ptr [r13+EL_TYPE], E_LINE
    movsd   xmm0, [rsp+CT_A]
    movsd   [r13+EL_A], xmm0
    movsd   xmm0, [rsp+CT_A+8]
    movsd   [r13+EL_A+8], xmm0
    lea     rdi, [rip+fl_els]
    mov     esi, 3
    movsd   xmm0, [rsp+CT_S]
    call    bp_custom
    # along the edge: convex past both ends, concave exactly its length
    xorpd   xmm0, xmm0
    movsd   xmm1, [rsp+CT_L]
    cmp     dword ptr [rsp+CT_CVX], 0
    je      3f
    movsd   xmm2, [rsp+CT_L]
    mulsd   xmm2, [rip+fl_margin]
    addsd   xmm2, [rsp+CT_S]
    subsd   xmm0, xmm2
    addsd   xmm1, xmm2
3:  call    bp_prism
    mov     edx, [rsp+CT_CVX]
    add     rsp, 160
    pop     r13
    pop     r12
    pop     rbx
    ret

# ct_arc (corner_tool's frame, r13 = the element) - the rolling ball's arc
#   from T1 to T2: centre (s, -r n1.V convex / +r n1.V concave), the short way
ct_arc:
    push    rbx
    sub     rsp, 32
    lea     rbx, [rsp+48]               # corner_tool's frame
    mov     dword ptr [r13+EL_TYPE], E_ARC
    mov     rax, [rsp+32]               # (corner_tool's rbx: the record)
    lea     rdi, [rax+FE_N1]
    lea     rsi, [rbx+CT_V]
    call    v3dot
    mulsd   xmm0, [rip+fl_r]
    cmp     dword ptr [rbx+CT_CVX], 0
    je      1f
    xorpd   xmm0, [rip+fl_negm]
1:  movsd   [r13+EL_C+8], xmm0          # centre
    movsd   xmm0, [rbx+CT_S]
    movsd   [r13+EL_C], xmm0
    movsd   xmm0, [rip+fl_r]
    movsd   [r13+EL_R], xmm0
    movsd   xmm0, [r13+EL_A+8]          # angles of T1, T2 about the centre
    subsd   xmm0, [r13+EL_C+8]
    movsd   xmm1, [r13+EL_A]
    subsd   xmm1, [r13+EL_C]
    call    datan2
    movsd   [r13+EL_T0], xmm0
    movsd   xmm0, [r13+EL_B+8]
    subsd   xmm0, [r13+EL_C+8]
    movsd   xmm1, [r13+EL_B]
    subsd   xmm1, [r13+EL_C]
    call    datan2
    subsd   xmm0, [r13+EL_T0]           # the sweep into (-pi, pi]
2:  comisd  xmm0, [rip+fl_pi]
    jbe     3f
    subsd   xmm0, [rip+fl_2pi]
    jmp     2b
3:  movsd   xmm1, [rip+fl_pi]
    xorpd   xmm1, [rip+fl_negm]
    comisd  xmm0, xmm1
    ja      4f
    addsd   xmm0, [rip+fl_2pi]
    jmp     3b
4:  movsd   [r13+EL_SW], xmm0
    add     rsp, 32
    pop     rbx
    ret

.section .note.GNU-stack,"",@progbits
