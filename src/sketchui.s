# =============================================================================
#  BeeModel - sketch mode: draw, select, drag and constrain in the viewport
#
#  Tab on a sketch object enters sketch mode. Tools: L line (a chain; clicks
#  on existing points reuse them, nearly level / plumb lines become
#  horizontal / vertical), O circle (centre, then a point on it), R
#  rectangle (two corners); Esc ends a tool, then leaves the selection.
#  Without a tool, click picks points and entities (Shift adds) and points
#  can be dragged: the sketch solves as they move. Keys on the selection:
#  C coincident (point + line / circle: on it), H horizontal, V vertical,
#  E equal, P parallel, N perpendicular, T tangent, F fix, M midpoint,
#  D dimension (length, distance, radius / diameter, angle; typed on the
#  command line, expressions welcome), X delete.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

.globl skm_obj
.globl skm_toggle
.globl skm_can
.globl skm_press
.globl skm_drag
.globl skm_release
.globl skm_click
.globl skm_overlay
.globl skm_escape
.globl skm_hover

.equ SK_NPT,     12
.equ SK_NENT,    16
.equ SK_NCON,    20
.equ SK_DOF,     24
.equ SK_NBAD,    28
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
.equ SK_CONS,    SK_ENTS + 256*EN_SZ
.equ CN_SZ,      96
.equ CN_TYPE,    0
.equ CN_A,       4
.equ CN_B,       8
.equ CN_C,       12
.equ CN_VAL,     16
.equ CN_FLAGS,   32
.equ CN_EXPR,    36
.equ F_FULL,     1
.equ F_BAD,      2
.equ E_LINE,     1
.equ E_CIRCLE,   2
.equ E_ARC,      3
.equ C_COINCIDENT, 1
.equ C_HORIZONTAL, 2
.equ C_VERTICAL,   3
.equ C_PARALLEL,   4
.equ C_PERP,       5
.equ C_EQUAL,      6
.equ C_TANGENT,    7
.equ C_FIXED,      8
.equ C_DISTANCE,   9
.equ C_HDIST,      10
.equ C_VDIST,      11
.equ C_RADIUS,     12
.equ C_ANGLE,      13
.equ C_ONLINE,     14
.equ C_ONCIRCLE,   15
.equ C_MIDPOINT,   16
.equ C_LENGTH,     18
.equ C_DIAMETER,   19
.equ T_SELECT,   0
.equ T_LINE,     1
.equ T_CIRCLE,   2
.equ T_RECT,     3
.equ MAX_SEL,    64
.equ K_PT,       1                      # selection kinds (<< 16 | index)
.equ K_ENT,      2
.equ SNAP_PX,    9                      # pick radius (physical pixels)
.equ COL_FULLY,  0xe8eaee
.equ COL_UNDER,  0x5aa9ff
.equ COL_CONFL,  0xff5a5a

.section .data
.align 4
skm_obj:        .long 0                 # the sketch object being edited

.section .bss
.align 8
skm_tool:       .skip 4
skm_stage:      .skip 4                 # 0: waiting for the first click
skm_prev:       .skip 4                 # the chain's last point
skm_first:      .skip 4                 # (a rectangle's snapped first corner)
skm_nsel:       .skip 4
skm_drag_pt:    .skip 4
skm_drag_con:   .skip 4
skm_hx:         .skip 4                 # the pointer (logical) for previews
skm_hy:         .skip 4
skm_hvp:        .skip 4                 # ...over this area
.align 8
skm_p0:         .skip 16                # the first click (u, v)
skm_sel:        .skip 4*MAX_SEL
skm_dimsel:     .skip 4*MAX_SEL         # the selection a pending D measures
skm_ndimsel:    .skip 4
.align 16
sm_m:           .skip 48                # the object's matrix
sm_o:           .skip 12                # plane origin, U, V in world space
sm_u:           .skip 12
sm_v:           .skip 12
sm_t:           .skip 16
sm_c:           .skip 16
sm_s:           .skip 16
sm_txt:         .skip 32

.section .rodata
.align 8
md_one:         .double 1.0
md_half:        .double 0.5
md_tan:         .double 0.035           # |dy| / |dx| below this: horizontal
.align 4
mf_one:         .float 1.0
mf_snap2:       .float 81.0             # SNAP_PX^2
mf_big:         .float 1.0e30
mf_tiny:        .float 1.0e-9
mf_near:        .float 0.05
s_sm_enter:     .asciz "  sketch mode: L line, O circle, R rectangle; C H V E P N T F M constraints, D dimension, X delete; Tab leaves"
s_sm_head:      .asciz "Sketch "
s_sm_dof:       .asciz "  ·  DOF "
s_sm_bad:       .asciz "  ·  conflicts "
s_sm_full:      .asciz "  ·  fully constrained"
s_sm_tools:     .asciz "L line  O circle  R rectangle  ·  C H V E P N T F M  D dimension  X delete  ·  Tab"
s_sm_t_line:    .asciz "Line: click points, Esc ends"
s_sm_t_circ:    .asciz "Circle: click the centre, then a point on it"
s_sm_t_rect:    .asciz "Rectangle: click two corners"
s_sm_need:      .asciz "  sketch: select what to constrain first"
s_sm_dimneed:   .asciz "  sketch.dim <value or expression> (after D on a selection)"
s_sm_pf:        .asciz "sketch.dim "
s_sm_now:       .asciz "  dimension now: "
s_sm_nothing:   .asciz "  sketch: that selection takes no dimension (a line, two points, a circle or two lines)"
s_lbl_h:        .asciz "H"
s_lbl_v:        .asciz "V"
s_lbl_p:        .asciz "//"
s_lbl_n:        .asciz "_|_"
s_lbl_e:        .asciz "="
s_lbl_t:        .asciz "T"
s_lbl_f:        .asciz "F"
s_lbl_m:        .asciz "M"
s_lbl_r:        .asciz "R"
s_lbl_d:        .asciz "D"
s_deg:          .asciz "deg"

OPERATOR op_sk_line,  "sketch.tool_line",   "Line",          do_tool, chk_tool, T_LINE,   key=KEY_L, flags=OPF_AI_SAFE|OPF_QUIET|OPF_SKETCH, doc="Sketch mode: draw lines (click points; Esc ends)"
OPERATOR op_sk_circle,"sketch.tool_circle", "Circle",        do_tool, chk_tool, T_CIRCLE, key=KEY_O, flags=OPF_AI_SAFE|OPF_QUIET|OPF_SKETCH, doc="Sketch mode: draw circles (centre, then a point on it)"
OPERATOR op_sk_rect,  "sketch.tool_rect",   "Rectangle",     do_tool, chk_tool, T_RECT,   key=KEY_R, flags=OPF_AI_SAFE|OPF_QUIET|OPF_SKETCH, doc="Sketch mode: draw rectangles (two corners)"
OPERATOR op_sk_coin,  "sketch.coincident",  "Coincident",    do_con, arg=C_COINCIDENT, key=KEY_C, flags=OPF_AI_SAFE|OPF_UNDO|OPF_SKETCH, doc="Sketch: join two points, or put a point on a line or circle"
OPERATOR op_sk_hor,   "sketch.horizontal",  "Horizontal",    do_con, arg=C_HORIZONTAL, key=KEY_H, flags=OPF_AI_SAFE|OPF_UNDO|OPF_SKETCH, doc="Sketch: make the selected lines (or two points) horizontal"
OPERATOR op_sk_ver,   "sketch.vertical",    "Vertical",      do_con, arg=C_VERTICAL, key=KEY_V, flags=OPF_AI_SAFE|OPF_UNDO|OPF_SKETCH, doc="Sketch: make the selected lines (or two points) vertical"
OPERATOR op_sk_eq,    "sketch.equal",       "Equal",         do_con, arg=C_EQUAL, key=KEY_E, flags=OPF_AI_SAFE|OPF_UNDO|OPF_SKETCH, doc="Sketch: equal lengths (lines) or radii (circles)"
OPERATOR op_sk_par,   "sketch.parallel",    "Parallel",      do_con, arg=C_PARALLEL, key=KEY_P, flags=OPF_AI_SAFE|OPF_UNDO|OPF_SKETCH, doc="Sketch: make two lines parallel"
OPERATOR op_sk_perp,  "sketch.perpendicular","Perpendicular",do_con, arg=C_PERP, key=KEY_N, flags=OPF_AI_SAFE|OPF_UNDO|OPF_SKETCH, doc="Sketch: make two lines perpendicular"
OPERATOR op_sk_tan,   "sketch.tangent",     "Tangent",       do_con, arg=C_TANGENT, key=KEY_T, flags=OPF_AI_SAFE|OPF_UNDO|OPF_SKETCH, doc="Sketch: make a line and a circle (or two circles) tangent"
OPERATOR op_sk_fix,   "sketch.fix",         "Fix",           do_con, arg=C_FIXED, key=KEY_F, flags=OPF_AI_SAFE|OPF_UNDO|OPF_SKETCH, doc="Sketch: fix the selected points where they are"
OPERATOR op_sk_mid,   "sketch.midpoint",    "Midpoint",      do_con, arg=C_MIDPOINT, key=KEY_M, flags=OPF_AI_SAFE|OPF_UNDO|OPF_SKETCH, doc="Sketch: put a point on a line's middle"
OPERATOR op_sk_dimkey,"sketch.dimension",   "Dimension...",  do_dimkey, key=KEY_D, flags=OPF_AI_SAFE|OPF_QUIET|OPF_SKETCH, doc="Sketch: dimension the selection (type the value or an expression)"
OPERATOR op_sk_dim,   "sketch.dim",         "Set Dimension", do_dim, flags=OPF_AI_SAFE|OPF_UNDO, doc="Sketch: give the selection from D a dimension: sketch.dim <value or expression>"
OPERATOR op_sk_del,   "sketch.delete",      "Delete",        do_delete, key=KEY_X, flags=OPF_AI_SAFE|OPF_UNDO|OPF_SKETCH, doc="Sketch: delete the selected entities and points"

.text

# ---- the object --------------------------------------------------------------
# cur -> rax = the sketch object being edited (0, and sketch mode ends, if
#   it is gone or no longer a sketch)
cur:
    mov     edi, [rip+skm_obj]
    test    edi, edi
    jz      8f
    sub     rsp, 8
    call    obj_get
    add     rsp, 8
    test    rax, rax
    jz      7f
    cmp     dword ptr [rax+OB_TYPE], OT_SKETCH
    jne     7f
    cmp     qword ptr [rax+OB_SKETCH], 0
    je      7f
    ret
7:  mov     dword ptr [rip+skm_obj], 0
8:  xor     eax, eax
    ret

# skm_can -> eax = 1 if the active object is a sketch
skm_can:
    sub     rsp, 8
    mov     edi, [rip+active_obj]
    xor     eax, eax
    test    edi, edi
    jz      9f
    call    obj_get
    test    rax, rax
    jz      9f
    cmp     dword ptr [rax+OB_TYPE], OT_SKETCH
    sete    al
    movzx   eax, al
9:  add     rsp, 8
    ret

# skm_toggle - Tab on a sketch: in / out of sketch mode
skm_toggle:
    sub     rsp, 8
    cmp     dword ptr [rip+skm_obj], 0
    je      1f
    mov     dword ptr [rip+skm_obj], 0
    jmp     9f
1:  mov     eax, [rip+active_obj]
    mov     [rip+skm_obj], eax
    mov     dword ptr [rip+skm_tool], T_SELECT
    mov     dword ptr [rip+skm_stage], 0
    mov     dword ptr [rip+skm_nsel], 0
    lea     rdi, [rip+s_sm_enter]
    call    log_line
9:  mov     dword ptr [rip+dirty], 1
    add     rsp, 8
    ret

# skm_escape -> eax = 1 if sketch mode took the Esc (ends a tool, then
#   clears the selection; Esc with nothing to do leaves sketch mode)
skm_escape:
    xor     eax, eax
    cmp     dword ptr [rip+skm_obj], 0
    je      9f
    mov     dword ptr [rip+dirty], 1
    cmp     dword ptr [rip+skm_tool], T_SELECT
    je      1f
    mov     dword ptr [rip+skm_tool], T_SELECT
    mov     dword ptr [rip+skm_stage], 0
    mov     eax, 1
    ret
1:  cmp     dword ptr [rip+skm_nsel], 0
    je      2f
    mov     dword ptr [rip+skm_nsel], 0
    mov     eax, 1
    ret
2:  mov     dword ptr [rip+skm_obj], 0
    mov     eax, 1
9:  ret

# skm_hover(edi=x, esi=y logical, edx=area) - previews follow the pointer
skm_hover:
    cmp     dword ptr [rip+skm_obj], 0
    je      9f
    mov     [rip+skm_hx], edi
    mov     [rip+skm_hy], esi
    mov     [rip+skm_hvp], edx
    cmp     dword ptr [rip+skm_tool], T_SELECT
    je      9f
    mov     dword ptr [rip+dirty], 1
9:  ret

# frame(rdi=object) - its matrix and the plane's world origin / axes
frame:
    push    rbx
    sub     rsp, 32
    mov     rbx, rdi
    lea     rsi, [rip+sm_m]
    call    obj_matrix
    mov     rdi, [rbx+OB_SKETCH]        # origin
    xorpd   xmm0, xmm0
    xorpd   xmm1, xmm1
    lea     rsi, [rsp]
    call    sk_plane_xyz
    lea     rdi, [rip+sm_m]
    lea     rsi, [rsp]
    lea     rdx, [rip+sm_o]
    call    xform_point
    mov     rdi, [rbx+OB_SKETCH]        # U = M(1, 0) - O
    movsd   xmm0, [rip+md_one]
    xorpd   xmm1, xmm1
    lea     rsi, [rsp]
    call    sk_plane_xyz
    lea     rdi, [rip+sm_m]
    lea     rsi, [rsp]
    lea     rdx, [rip+sm_u]
    call    xform_point
    mov     rdi, [rbx+OB_SKETCH]        # V = M(0, 1) - O
    xorpd   xmm0, xmm0
    movsd   xmm1, [rip+md_one]
    lea     rsi, [rsp]
    call    sk_plane_xyz
    lea     rdi, [rip+sm_m]
    lea     rsi, [rsp]
    lea     rdx, [rip+sm_v]
    call    xform_point
    xor     ecx, ecx
1:  lea     rax, [rip+sm_o]
    movss   xmm0, [rax+rcx*4]
    lea     rax, [rip+sm_u]
    movss   xmm1, [rax+rcx*4]
    subss   xmm1, xmm0
    movss   [rax+rcx*4], xmm1
    lea     rax, [rip+sm_v]
    movss   xmm1, [rax+rcx*4]
    subss   xmm1, xmm0
    movss   [rax+rcx*4], xmm1
    inc     ecx
    cmp     ecx, 3
    jb      1b
    add     rsp, 32
    pop     rbx
    ret

# dot3f(rdi, rsi) -> xmm0
dot3f:
    movss   xmm0, [rdi]
    mulss   xmm0, [rsi]
    movss   xmm1, [rdi+4]
    mulss   xmm1, [rsi+4]
    addss   xmm0, xmm1
    movss   xmm1, [rdi+8]
    mulss   xmm1, [rsi+8]
    addss   xmm0, xmm1
    ret

# ray_uv(edi=x, esi=y logical; camera set up, frame done) -> eax = 1,
#   xmm0 = u, xmm1 = v (doubles): the pointer's ray on the sketch plane
ray_uv:
    push    rbx
    sub     rsp, 64
    mov     ebx, esi
    call    to_px                       # physical
    cvtsi2ss xmm6, eax
    mov     edi, ebx
    call    to_px
    cvtsi2ss xmm7, eax
    subss   xmm6, [rip+vp_cx]           # d = right sx + up sy + fwd
    divss   xmm6, [rip+vp_focal]
    movss   xmm5, [rip+vp_cy]
    subss   xmm5, xmm7
    divss   xmm5, [rip+vp_focal]
    xor     ecx, ecx
1:  lea     rax, [rip+right]
    movss   xmm0, [rax+rcx*4]
    mulss   xmm0, xmm6
    lea     rax, [rip+up]
    movss   xmm1, [rax+rcx*4]
    mulss   xmm1, xmm5
    addss   xmm0, xmm1
    lea     rax, [rip+fwd]
    addss   xmm0, [rax+rcx*4]
    movss   [rsp+rcx*4], xmm0           # d at +0
    inc     ecx
    cmp     ecx, 3
    jb      1b
    # n = U x V
    lea     rax, [rip+sm_u]
    lea     rdx, [rip+sm_v]
    movss   xmm0, [rax+4]
    mulss   xmm0, [rdx+8]
    movss   xmm1, [rax+8]
    mulss   xmm1, [rdx+4]
    subss   xmm0, xmm1
    movss   [rsp+16], xmm0
    movss   xmm0, [rax+8]
    mulss   xmm0, [rdx]
    movss   xmm1, [rax]
    mulss   xmm1, [rdx+8]
    subss   xmm0, xmm1
    movss   [rsp+20], xmm0
    movss   xmm0, [rax]
    mulss   xmm0, [rdx+4]
    movss   xmm1, [rax+4]
    mulss   xmm1, [rdx]
    subss   xmm0, xmm1
    movss   [rsp+24], xmm0
    lea     rdi, [rsp]                  # t = (O - eye) . n / d . n
    lea     rsi, [rsp+16]
    call    dot3f
    movss   [rsp+28], xmm0
    andps   xmm0, [rip+mf_abs]
    comiss  xmm0, [rip+mf_tiny]
    jbe     8f
    xor     ecx, ecx
2:  lea     rax, [rip+sm_o]
    movss   xmm0, [rax+rcx*4]
    lea     rax, [rip+eye]
    subss   xmm0, [rax+rcx*4]
    movss   [rsp+32+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      2b
    lea     rdi, [rsp+32]
    lea     rsi, [rsp+16]
    call    dot3f
    divss   xmm0, [rsp+28]              # t
    xor     ecx, ecx                    # w = eye + t d - O
3:  movss   xmm1, [rsp+rcx*4]
    mulss   xmm1, xmm0
    lea     rax, [rip+eye]
    addss   xmm1, [rax+rcx*4]
    lea     rax, [rip+sm_o]
    subss   xmm1, [rax+rcx*4]
    movss   [rsp+32+rcx*4], xmm1
    inc     ecx
    cmp     ecx, 3
    jb      3b
    # [UU UV; UV VV] [u v] = [U.w V.w]
    lea     rdi, [rip+sm_u]
    lea     rsi, [rip+sm_u]
    call    dot3f
    cvtss2sd xmm2, xmm0                 # a
    lea     rdi, [rip+sm_u]
    lea     rsi, [rip+sm_v]
    call    dot3f
    cvtss2sd xmm3, xmm0                 # b
    lea     rdi, [rip+sm_v]
    lea     rsi, [rip+sm_v]
    call    dot3f
    cvtss2sd xmm4, xmm0                 # c
    lea     rdi, [rip+sm_u]
    lea     rsi, [rsp+32]
    call    dot3f
    cvtss2sd xmm5, xmm0                 # p
    lea     rdi, [rip+sm_v]
    lea     rsi, [rsp+32]
    call    dot3f
    cvtss2sd xmm6, xmm0                 # q
    movsd   xmm7, xmm2                  # det = ac - b^2
    mulsd   xmm7, xmm4
    movsd   xmm0, xmm3
    mulsd   xmm0, xmm3
    subsd   xmm7, xmm0
    movsd   xmm0, xmm5                  # u = (p c - q b) / det
    mulsd   xmm0, xmm4
    movsd   xmm1, xmm6
    mulsd   xmm1, xmm3
    subsd   xmm0, xmm1
    divsd   xmm0, xmm7
    movsd   xmm1, xmm6                  # v = (q a - p b) / det
    mulsd   xmm1, xmm2
    mulsd   xmm5, xmm3
    subsd   xmm1, xmm5
    divsd   xmm1, xmm7
    mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 64
    pop     rbx
    ret

# screen(rdi=sketch, xmm0=u, xmm1=v doubles) -> eax = 1 (in front), xmm0,
#   xmm1 = physical screen position (frame + camera ready)
screen:
    sub     rsp, 40
    lea     rsi, [rsp]
    call    sk_plane_xyz
    lea     rdi, [rip+sm_m]
    lea     rsi, [rsp]
    lea     rdx, [rsp+16]
    call    xform_point
    lea     rdi, [rsp+16]
    lea     rsi, [rsp]
    call    to_cam
    movss   xmm0, [rsp+8]
    comiss  xmm0, [rip+mf_near]
    jb      8f
    lea     rdi, [rsp]
    lea     rsi, [rsp+16]
    call    project
    movss   xmm0, [rsp+16]
    movss   xmm1, [rsp+20]
    mov     eax, 1
    add     rsp, 40
    ret
8:  xor     eax, eax
    add     rsp, 40
    ret

# pscreen(rbx=sketch, eax=point) -> eax = 1, xmm0, xmm1 = its screen spot
pscreen:
    imul    eax, eax, PT_SZ
    movsd   xmm0, [rbx+SK_PTS+rax]
    movsd   xmm1, [rbx+SK_PTS+rax+8]
    mov     rdi, rbx
    jmp     screen

# pick_point(edi=x, esi=y logical) -> eax = the nearest point (or -1)
pick_point:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 16
    call    cur
    mov     rbx, [rax+OB_SKETCH]
    mov     r12d, -1
    movss   xmm0, [rip+mf_snap2]
    movss   [rsp+8], xmm0               # best distance^2
    mov     edi, [rip+skm_px]
    mov     esi, [rip+skm_py]
    cvtsi2ss xmm6, edi
    cvtsi2ss xmm7, esi
    movss   [rsp], xmm6
    movss   [rsp+4], xmm7
    xor     r13d, r13d
1:  cmp     r13d, [rbx+SK_NPT]
    jae     9f
    mov     eax, r13d
    call    pscreen
    test    eax, eax
    jz      2f
    subss   xmm0, [rsp]
    subss   xmm1, [rsp+4]
    mulss   xmm0, xmm0
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    comiss  xmm0, [rsp+8]
    jae     2f
    movss   [rsp+8], xmm0
    mov     r12d, r13d
2:  inc     r13d
    jmp     1b
9:  mov     eax, r12d
    add     rsp, 16
    pop     r13
    pop     r12
    pop     rbx
    ret

# seg_d2(xmm0, xmm1 = a; xmm2, xmm3 = b; [rsp+8..] pointer at caller's
#   [rsp], [rsp+4]) -> xmm0 = distance^2 from the pointer (p in xmm6, xmm7)
seg_d2:
    subss   xmm2, xmm0                  # d = b - a; t = clamp((p - a).d / d.d)
    subss   xmm3, xmm1
    movss   xmm4, xmm6
    subss   xmm4, xmm0
    movss   xmm5, xmm7
    subss   xmm5, xmm1
    movss   [rip+sm_t], xmm4
    movss   [rip+sm_t+4], xmm5
    mulss   xmm4, xmm2
    mulss   xmm5, xmm3
    addss   xmm4, xmm5                  # (p - a).d
    movss   xmm5, xmm2
    mulss   xmm5, xmm2
    movss   [rip+sm_t+8], xmm3
    mulss   xmm3, xmm3
    addss   xmm5, xmm3                  # d.d
    movss   xmm3, [rip+sm_t+8]
    maxss   xmm5, [rip+mf_tiny]
    divss   xmm4, xmm5
    xorps   xmm5, xmm5
    maxss   xmm4, xmm5
    minss   xmm4, [rip+mf_one]
    mulss   xmm2, xmm4                  # (p - a) - t d
    mulss   xmm3, xmm4
    movss   xmm0, [rip+sm_t]
    subss   xmm0, xmm2
    movss   xmm1, [rip+sm_t+4]
    subss   xmm1, xmm3
    mulss   xmm0, xmm0
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    ret

# pick_entity -> eax = the nearest entity to (skm_px, skm_py) or -1
pick_entity:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 32
    call    cur
    mov     rbx, [rax+OB_SKETCH]
    mov     r12d, -1
    movss   xmm0, [rip+mf_snap2]
    movss   [rsp+8], xmm0
    xor     r13d, r13d                  # entity
1:  cmp     r13d, [rbx+SK_NENT]
    jae     9f
    imul    eax, r13d, EN_SZ
    lea     r14, [rbx+SK_ENTS+rax]
    mov     r15d, 1                     # segments: lines 1, others 48
    cmp     dword ptr [r14+EN_TYPE], E_LINE
    je      2f
    mov     r15d, 48
2:  xor     ecx, ecx
    mov     [rsp+20], ecx
    mov     edx, r15d
    call    ent_screen                  # point i of the entity on screen
    test    eax, eax
    jz      6f
    movss   [rsp+12], xmm0
    movss   [rsp+16], xmm1
3:  mov     ecx, [rsp+20]
    inc     ecx
    mov     [rsp+20], ecx
    cmp     ecx, r15d
    ja      6f
    mov     edx, r15d
    call    ent_screen
    test    eax, eax
    jz      6f
    movss   [rsp+24], xmm0
    movss   [rsp+28], xmm1
    movss   xmm2, xmm0
    movss   xmm3, xmm1
    movss   xmm0, [rsp+12]
    movss   xmm1, [rsp+16]
    cvtsi2ss xmm6, dword ptr [rip+skm_px]
    cvtsi2ss xmm7, dword ptr [rip+skm_py]
    call    seg_d2
    comiss  xmm0, [rsp+8]
    jae     4f
    movss   [rsp+8], xmm0
    mov     r12d, r13d
4:  movss   xmm0, [rsp+24]
    movss   [rsp+12], xmm0
    movss   xmm0, [rsp+28]
    movss   [rsp+16], xmm0
    jmp     3b
6:  inc     r13d
    jmp     1b
9:  mov     eax, r12d
    add     rsp, 32
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ent_screen(rbx=sketch, r14=entity, ecx=i, edx=segments) -> eax, xmm0/1
ent_screen:
    sub     rsp, 24
    mov     [rsp], ecx
    mov     [rsp+4], edx
    cmp     dword ptr [r14+EN_TYPE], E_LINE
    jne     2f
    mov     eax, [r14+EN_P0]
    test    ecx, ecx
    jz      1f
    mov     eax, [r14+EN_P1]
1:  add     rsp, 24
    jmp     pscreen
2:  call    round_uv                    # circle / arc: the i-th point
    mov     rdi, rbx
    call    screen
    add     rsp, 24
    ret

# round_uv(rbx, r14; the caller's [rsp] = i, [rsp+4] = n) -> xmm0, xmm1 (u, v)
round_uv:
    sub     rsp, 56
    mov     eax, [r14+EN_P0]
    imul    eax, eax, PT_SZ
    movsd   xmm0, [rbx+SK_PTS+rax]
    movsd   [rsp], xmm0
    movsd   xmm0, [rbx+SK_PTS+rax+8]
    movsd   [rsp+8], xmm0
    xorpd   xmm2, xmm2                  # a0, sweep
    movsd   xmm3, [rip+md_2pi]
    cmp     dword ptr [r14+EN_TYPE], E_ARC
    jne     3f
    mov     eax, [r14+EN_P1]
    call    ang
    movsd   [rsp+16], xmm0
    mov     eax, [r14+EN_P2]
    call    ang
    movsd   xmm2, [rsp+16]
    movsd   xmm3, xmm0
    subsd   xmm3, xmm2
    xorpd   xmm4, xmm4
    comisd  xmm3, xmm4
    ja      3f
    addsd   xmm3, [rip+md_2pi]
3:  cvtsi2sd xmm4, dword ptr [rsp+56+8]
    cvtsi2sd xmm5, dword ptr [rsp+56+12]
    divsd   xmm4, xmm5
    mulsd   xmm4, xmm3
    addsd   xmm4, xmm2
    movsd   [rsp+16], xmm4
    fld     qword ptr [rsp+16]
    fsincos
    fstp    qword ptr [rsp+24]
    fstp    qword ptr [rsp+32]
    movsd   xmm0, [rsp+24]
    mulsd   xmm0, [r14+EN_R]
    addsd   xmm0, [rsp]
    movsd   xmm1, [rsp+32]
    mulsd   xmm1, [r14+EN_R]
    addsd   xmm1, [rsp+8]
    add     rsp, 56
    ret
# ang(eax=point; caller's [rsp+8] = centre) -> xmm0
ang:
    imul    eax, eax, PT_SZ
    movsd   xmm0, [rbx+SK_PTS+rax]
    subsd   xmm0, [rsp+8]
    movsd   xmm1, [rbx+SK_PTS+rax+8]
    subsd   xmm1, [rsp+16]
    movsd   [rsp+8+40], xmm0
    movsd   [rsp+8+48], xmm1
    fld     qword ptr [rsp+8+48]
    fld     qword ptr [rsp+8+40]
    fpatan
    fstp    qword ptr [rsp+8+40]
    movsd   xmm0, [rsp+8+40]
    ret

# ---- clicks -------------------------------------------------------------------
# setup(edi=x, esi=y logical) -> rax = object (0 if none): pointer in
#   physical pixels, the frame ready (the caller set up the viewport)
setup:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     ebx, edi
    mov     r12d, esi
    call    to_px
    mov     [rip+skm_px], eax
    mov     edi, r12d
    call    to_px
    mov     [rip+skm_py], eax
    call    cur
    test    rax, rax
    jz      9f
    push    rax
    mov     rdi, rax
    call    frame
    pop     rax
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# snap(edi, esi) -> eax = a point under the pointer (or -1); xmm0, xmm1 =
#   where (u, v): the point's position, else the ray on the plane
snap:
    push    rbx
    push    r12
    push    r13
    mov     ebx, edi
    mov     r12d, esi
    call    pick_point
    mov     r13d, eax
    test    eax, eax
    js      1f
    call    cur
    mov     rdi, [rax+OB_SKETCH]
    mov     esi, r13d
    call    sk_point_xy
    jmp     9f
1:  mov     edi, ebx
    mov     esi, r12d
    call    ray_uv
9:  mov     eax, r13d
    pop     r13
    pop     r12
    pop     rbx
    ret

# skm_click(edi=x, esi=y logical, edx=modifiers) - a click in sketch mode
skm_click:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 48
    mov     r13d, edi
    mov     r14d, esi
    mov     r15d, edx
    call    setup
    test    rax, rax
    jz      .Lsc_out
    mov     rbx, rax
    mov     eax, [rip+skm_tool]
    cmp     eax, T_SELECT
    je      .Lsc_select
    mov     edi, r13d
    mov     esi, r14d
    call    snap
    mov     r12d, eax                   # snapped point or -1
    movsd   [rsp], xmm0
    movsd   [rsp+8], xmm1
    cmp     dword ptr [rip+skm_stage], 0
    jne     .Lsc_second
    mov     dword ptr [rip+skm_stage], 1    # the first click
    movsd   [rip+skm_p0], xmm0
    movsd   [rip+skm_p0+8], xmm1
    mov     [rip+skm_prev], r12d
    mov     [rip+skm_first], r12d
    jmp     .Lsc_out
.Lsc_second:
    lea     rdi, [rip+s_sm_head]        # an undo step for this click
    call    undo_push
    mov     rdi, rbx
    call    skx_begin
    test    rax, rax
    jz      .Lsc_out
    mov     [rsp+16], rax
    mov     eax, [rip+skm_tool]
    cmp     eax, T_LINE
    je      .Lsc_line
    cmp     eax, T_CIRCLE
    je      .Lsc_circle
    # rectangle: from the first corner to here
    movsd   xmm0, [rip+skm_p0]
    movsd   xmm1, [rip+skm_p0+8]
    movsd   xmm2, [rsp]
    subsd   xmm2, xmm0
    movsd   xmm3, [rsp+8]
    subsd   xmm3, xmm1
    mov     rdi, [rsp+16]
    call    skx_rect
    test    eax, eax
    js      .Lsc_end
    mov     r13d, eax
    mov     eax, [rip+skm_first]        # snapped corners: joined
    test    eax, eax
    js      1f
    mov     rdi, [rsp+16]
    mov     esi, r13d
    xor     edx, edx
    call    sk_ent_point
    mov     edx, eax
    mov     ecx, [rip+skm_first]
    mov     rdi, [rsp+16]
    call    add_coin
1:  test    r12d, r12d
    js      2f
    mov     rdi, [rsp+16]
    lea     esi, [r13+1]
    mov     edx, 1
    call    sk_ent_point
    mov     edx, eax
    mov     ecx, r12d
    mov     rdi, [rsp+16]
    call    add_coin
2:  mov     dword ptr [rip+skm_stage], 0
    jmp     .Lsc_end
.Lsc_line:
    mov     esi, [rip+skm_prev]         # the start: the chain's point
    test    esi, esi
    jns     1f
    mov     rdi, [rsp+16]
    movsd   xmm0, [rip+skm_p0]
    movsd   xmm1, [rip+skm_p0+8]
    call    sk_add_point
    mov     esi, eax
    test    esi, esi
    js      .Lsc_end
1:  mov     [rsp+24], esi
    mov     edx, r12d                   # the end: a snapped point, or new
    test    edx, edx
    jns     2f
    mov     rdi, [rsp+16]
    movsd   xmm0, [rsp]
    movsd   xmm1, [rsp+8]
    call    sk_add_point
    mov     edx, eax
    test    edx, edx
    js      .Lsc_end
2:  mov     [rsp+28], edx
    mov     rdi, [rsp+16]
    mov     esi, [rsp+24]
    call    sk_add_line
    test    eax, eax
    js      .Lsc_end
    mov     r13d, eax
    movsd   xmm0, [rsp]                 # level or plumb: say so
    subsd   xmm0, [rip+skm_p0]
    andpd   xmm0, [rip+md_abs]
    movsd   xmm1, [rsp+8]
    subsd   xmm1, [rip+skm_p0+8]
    andpd   xmm1, [rip+md_abs]
    movsd   xmm2, xmm0
    mulsd   xmm2, [rip+md_tan]
    comisd  xmm1, xmm2
    jae     3f
    mov     esi, C_HORIZONTAL
    jmp     4f
3:  movsd   xmm2, xmm1
    mulsd   xmm2, [rip+md_tan]
    comisd  xmm0, xmm2
    jae     5f
    mov     esi, C_VERTICAL
4:  mov     rdi, [rsp+16]
    mov     edx, r13d
    mov     ecx, -1
    mov     r8d, -1
    xorpd   xmm0, xmm0
    xor     r9d, r9d
    call    sk_add_con
5:  mov     eax, [rsp+28]               # the chain goes on from here
    mov     [rip+skm_prev], eax
    movsd   xmm0, [rsp]
    movsd   [rip+skm_p0], xmm0
    movsd   xmm0, [rsp+8]
    movsd   [rip+skm_p0+8], xmm0
    jmp     .Lsc_end
.Lsc_circle:
    mov     esi, [rip+skm_prev]         # the centre (a snapped one is shared)
    test    esi, esi
    jns     1f
    mov     rdi, [rsp+16]
    movsd   xmm0, [rip+skm_p0]
    movsd   xmm1, [rip+skm_p0+8]
    call    sk_add_point
    mov     esi, eax
    test    esi, esi
    js      .Lsc_end
1:  movsd   xmm0, [rsp]                 # radius
    subsd   xmm0, [rip+skm_p0]
    movsd   xmm1, [rsp+8]
    subsd   xmm1, [rip+skm_p0+8]
    mulsd   xmm0, xmm0
    mulsd   xmm1, xmm1
    addsd   xmm0, xmm1
    sqrtsd  xmm0, xmm0
    mov     rdi, [rsp+16]
    call    sk_add_circle
    mov     dword ptr [rip+skm_stage], 0
.Lsc_end:
    mov     rdi, rbx
    call    skx_end
    jmp     .Lsc_out
.Lsc_select:
    call    pick_point                  # a point, else an entity
    mov     r12d, eax
    test    eax, eax
    js      1f
    or      r12d, K_PT << 16
    jmp     2f
1:  call    pick_entity
    mov     r12d, eax
    test    eax, eax
    js      3f
    or      r12d, K_ENT << 16
2:  test    r15d, MOD_SHIFT
    jnz     21f
    mov     dword ptr [rip+skm_nsel], 0
21: mov     edi, r12d                   # toggle it in the selection
    call    sel_toggle
    jmp     .Lsc_out
3:  test    r15d, MOD_SHIFT             # nothing: clear
    jnz     .Lsc_out
    mov     dword ptr [rip+skm_nsel], 0
.Lsc_out:
    mov     dword ptr [rip+dirty], 1
    add     rsp, 48
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# add_coin(rdi=sketch, edx=point, ecx=point) - coincident (unless the same)
add_coin:
    cmp     edx, ecx
    je      1f
    mov     esi, C_COINCIDENT
    mov     r8d, -1
    xorpd   xmm0, xmm0
    xor     r9d, r9d
    jmp     sk_add_con
1:  ret

# sel_toggle(edi=kind << 16 | index)
sel_toggle:
    lea     rsi, [rip+skm_sel]
    xor     ecx, ecx
1:  cmp     ecx, [rip+skm_nsel]
    jae     3f
    cmp     [rsi+rcx*4], edi
    je      2f
    inc     ecx
    jmp     1b
2:  mov     eax, [rip+skm_nsel]         # there: remove (last one moves in)
    dec     eax
    mov     [rip+skm_nsel], eax
    mov     eax, [rsi+rax*4]
    mov     [rsi+rcx*4], eax
    ret
3:  cmp     ecx, MAX_SEL
    jae     9f
    mov     [rsi+rcx*4], edi
    inc     dword ptr [rip+skm_nsel]
9:  ret

# ---- dragging points ----------------------------------------------------------
# skm_press(edi=x, esi=y logical) -> eax = 1 if a point is grabbed (the
#   caller set up the viewport)
skm_press:
    push    rbx
    push    r12
    push    r13
    mov     r12d, edi
    mov     r13d, esi
    xor     eax, eax
    cmp     dword ptr [rip+skm_obj], 0
    je      9f
    cmp     dword ptr [rip+skm_tool], T_SELECT
    jne     8f
    call    setup
    test    rax, rax
    jz      8f
    mov     rbx, rax
    call    pick_point
    test    eax, eax
    js      8f
    mov     [rip+skm_drag_pt], eax
    mov     dword ptr [rip+skm_drag_con], -1
    lea     rdi, [rip+s_sm_head]
    call    undo_push
    mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# skm_drag(edi, esi) - the grabbed point follows (a temporary fix there)
skm_drag:
    push    rbx
    push    r12
    sub     rsp, 24
    mov     [rsp+16], edi
    mov     [rsp+20], esi
    call    setup
    test    rax, rax
    jz      9f
    mov     rbx, rax
    mov     edi, [rsp+16]
    mov     esi, [rsp+20]
    call    ray_uv
    test    eax, eax
    jz      9f
    movsd   [rsp], xmm0
    movsd   [rsp+8], xmm1
    mov     rdi, rbx
    call    skx_begin
    test    rax, rax
    jz      9f
    mov     r12, rax
    mov     esi, [rip+skm_drag_con]     # drop the last temporary one
    test    esi, esi
    js      1f
    mov     rdi, r12
    call    sk_drop_con
1:  mov     esi, [rip+skm_drag_pt]      # move it there, then hold it there
    imul    eax, esi, PT_SZ
    movsd   xmm0, [rsp]
    movsd   [r12+SK_PTS+rax], xmm0
    movsd   xmm0, [rsp+8]
    movsd   [r12+SK_PTS+rax+8], xmm0
    mov     rdi, r12
    mov     edx, esi
    mov     esi, C_FIXED
    mov     ecx, -1
    mov     r8d, -1
    xorpd   xmm0, xmm0
    xor     r9d, r9d
    call    sk_add_con
    mov     [rip+skm_drag_con], eax
    mov     rdi, rbx
    call    skx_end
9:  add     rsp, 24
    pop     r12
    pop     rbx
    ret

# skm_release - the temporary fix goes; the sketch settles
skm_release:
    push    rbx
    call    cur
    test    rax, rax
    jz      9f
    mov     rbx, rax
    mov     esi, [rip+skm_drag_con]
    test    esi, esi
    js      1f
    mov     rdi, rbx
    call    skx_begin
    mov     rdi, rax
    mov     esi, [rip+skm_drag_con]
    call    sk_drop_con
    mov     dword ptr [rip+skm_drag_con], -1
1:  mov     rdi, rbx
    call    skx_end
9:  pop     rbx
    ret

# ---- operators ----------------------------------------------------------------
chk_tool:
    xor     eax, eax
    cmp     [rip+skm_tool], edi
    sete    al
    ret

do_tool:
    cmp     dword ptr [rip+skm_obj], 0
    je      9f
    mov     [rip+skm_tool], edi
    mov     dword ptr [rip+skm_stage], 0
    mov     dword ptr [rip+skm_nsel], 0
    mov     dword ptr [rip+dirty], 1
9:  ret

# sel_count(edi=kind) -> eax ; sel_nth(edi=kind, esi=n) -> eax = index
sel_count:
    xor     eax, eax
    xor     ecx, ecx
1:  cmp     ecx, [rip+skm_nsel]
    jae     9f
    lea     rdx, [rip+skm_sel]
    mov     edx, [rdx+rcx*4]
    shr     edx, 16
    cmp     edx, edi
    jne     2f
    inc     eax
2:  inc     ecx
    jmp     1b
9:  ret
sel_nth:
    xor     ecx, ecx
1:  cmp     ecx, [rip+skm_nsel]
    jae     8f
    lea     rdx, [rip+skm_sel]
    mov     eax, [rdx+rcx*4]
    mov     edx, eax
    shr     edx, 16
    cmp     edx, edi
    jne     2f
    test    esi, esi
    jz      3f
    dec     esi
2:  inc     ecx
    jmp     1b
3:  and     eax, 0xffff
    ret
8:  mov     eax, -1
    ret

# etype(rbx=sketch, eax=entity) -> eax = its type
etype:
    imul    eax, eax, EN_SZ
    mov     eax, [rbx+SK_ENTS+rax+EN_TYPE]
    ret

# con2(edi=type, esi=a, edx=b) - add to the edited sketch (r12)
con2:
    mov     r8d, -1
    mov     ecx, edx
    mov     edx, esi
    mov     esi, edi
    mov     rdi, r12
    xorpd   xmm0, xmm0
    xor     r9d, r9d
    jmp     sk_add_con

# do_con(edi=type) - a constraint from the selection
do_con:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r15d, edi
    call    cur
    test    rax, rax
    jz      .Ldc_none
    mov     r14, rax
    mov     rdi, rax
    call    skx_begin
    test    rax, rax
    jz      .Ldc_none
    mov     r12, rax
    mov     rbx, rax
    mov     edi, K_PT
    call    sel_count
    mov     r13d, eax                   # points
    mov     edi, K_ENT
    call    sel_count
    shl     eax, 8
    or      r13d, eax                   # entities << 8
    cmp     r15d, C_COINCIDENT
    je      .Ldc_coin
    cmp     r15d, C_HORIZONTAL
    je      .Ldc_hv
    cmp     r15d, C_VERTICAL
    je      .Ldc_hv
    cmp     r15d, C_FIXED
    je      .Ldc_fix
    cmp     r15d, C_MIDPOINT
    je      .Ldc_mid
    cmp     r13d, 2 << 8                # two entities: equal, parallel,
    jne     .Ldc_none                   #  perpendicular, tangent
    mov     edi, K_ENT
    xor     esi, esi
    call    sel_nth
    mov     r13d, eax
    mov     edi, K_ENT
    mov     esi, 1
    call    sel_nth
    mov     edx, eax
    mov     esi, r13d
    mov     edi, r15d
    call    con2
    jmp     .Ldc_done
.Ldc_coin:
    cmp     r13d, 2                     # two points
    jne     1f
    mov     edi, K_PT
    xor     esi, esi
    call    sel_nth
    mov     r13d, eax
    mov     edi, K_PT
    mov     esi, 1
    call    sel_nth
    mov     edx, eax
    mov     esi, r13d
    mov     edi, C_COINCIDENT
    call    con2
    jmp     .Ldc_done
1:  cmp     r13d, (1 << 8) | 1          # a point on a line / circle
    jne     .Ldc_none
    mov     edi, K_ENT
    xor     esi, esi
    call    sel_nth
    mov     r13d, eax
    call    etype
    mov     edi, C_ONLINE
    cmp     eax, E_LINE
    je      2f
    mov     edi, C_ONCIRCLE
2:  push    rdi
    mov     edi, K_PT
    xor     esi, esi
    call    sel_nth
    pop     rdi
    mov     esi, eax
    mov     edx, r13d
    call    con2
    jmp     .Ldc_done
.Ldc_hv:
    mov     eax, r13d                   # lines: each one
    shr     eax, 8
    test    eax, eax
    jz      2f
    xor     r13d, r13d
1:  mov     edi, K_ENT
    mov     esi, r13d
    call    sel_nth
    test    eax, eax
    js      .Ldc_done
    mov     esi, eax
    call    etype_esi
    cmp     eax, E_LINE
    jne     11f
    mov     edi, r15d
    mov     edx, -1
    call    con2
11: inc     r13d
    jmp     1b
2:  cmp     r13d, 2                     # two points: level (vdistance 0) /
    jne     .Ldc_none                   #  plumb (hdistance 0)
    mov     edi, K_PT
    xor     esi, esi
    call    sel_nth
    mov     r13d, eax
    mov     edi, K_PT
    mov     esi, 1
    call    sel_nth
    mov     edx, eax
    mov     esi, r13d
    mov     edi, C_VDIST
    cmp     r15d, C_HORIZONTAL
    je      3f
    mov     edi, C_HDIST
3:  call    con2
    jmp     .Ldc_done
.Ldc_fix:
    mov     eax, r13d
    and     eax, 0xff
    jz      .Ldc_none
    xor     r13d, r13d
1:  mov     edi, K_PT
    mov     esi, r13d
    call    sel_nth
    test    eax, eax
    js      .Ldc_done
    mov     esi, eax
    mov     edi, C_FIXED
    mov     edx, -1
    call    con2
    inc     r13d
    jmp     1b
.Ldc_mid:
    cmp     r13d, (1 << 8) | 1
    jne     .Ldc_none
    mov     edi, K_ENT
    xor     esi, esi
    call    sel_nth
    mov     r13d, eax
    mov     edi, K_PT
    xor     esi, esi
    call    sel_nth
    mov     esi, eax
    mov     edx, r13d
    mov     edi, C_MIDPOINT
    call    con2
.Ldc_done:
    mov     rdi, r14
    call    skx_end
    mov     dword ptr [rip+skm_nsel], 0
    jmp     9f
.Ldc_none:
    lea     rdi, [rip+s_sm_need]
    call    log_line
    call    undo_drop_last
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

etype_esi:
    mov     eax, esi
    jmp     etype

# do_dimkey - D: keep the selection, put "sketch.dim <current>" on the
#   command line
do_dimkey:
    push    rbx
    push    r12
    sub     rsp, 24
    call    cur
    test    rax, rax
    jz      9f
    mov     rbx, [rax+OB_SKETCH]
    mov     ecx, [rip+skm_nsel]         # remember the selection
    mov     [rip+skm_ndimsel], ecx
    lea     rsi, [rip+skm_sel]
    lea     rdi, [rip+skm_dimsel]
    shl     ecx, 2
    rep     movsb
    call    dim_kind                    # what it would measure, and now
    test    eax, eax
    jz      8f
    movsd   [rsp], xmm0
    mov     [rsp+4+4], eax
    call    fmt_reset                   # "  now: 6.038" in the log
    lea     rdi, [rip+s_sm_now]
    call    fmt_str
    movsd   xmm0, [rsp]
    cmp     dword ptr [rsp+8], C_ANGLE
    jne     1f
    mulsd   xmm0, [rip+md_rad2deg]
1:  cvtsd2ss xmm0, xmm0
    call    fmt_val3
    lea     rdi, [rip+fmt_buf]
    call    log_line
    lea     rdi, [rip+s_sm_pf]          # type the value (or an expression)
    call    console_prefill
    jmp     9f
8:  lea     rdi, [rip+s_sm_nothing]
    call    log_line
9:  add     rsp, 24
    pop     r12
    pop     rbx
    ret

# dim_kind(rbx=sketch, skm_dimsel) -> eax = constraint type (0: none),
#   edx = a, ecx = b, xmm0 = the current value (radians for angles)
dim_kind:
    push    r12
    push    r13
    push    r14
    sub     rsp, 48
    xor     r12d, r12d                  # points, entities (from dimsel)
    xor     r13d, r13d
    mov     dword ptr [rsp+32], -1
    mov     dword ptr [rsp+36], -1
    mov     dword ptr [rsp+40], -1
    mov     dword ptr [rsp+44], -1
    xor     ecx, ecx
1:  cmp     ecx, [rip+skm_ndimsel]
    jae     2f
    lea     rax, [rip+skm_dimsel]
    mov     eax, [rax+rcx*4]
    mov     edx, eax
    shr     edx, 16
    and     eax, 0xffff
    cmp     edx, K_PT
    jne     11f
    cmp     r12d, 2
    jae     12f
    mov     [rsp+32+r12*4], eax
    inc     r12d
    jmp     12f
11: cmp     r13d, 2
    jae     12f
    mov     [rsp+40+r13*4], eax
    inc     r13d
12: inc     ecx
    jmp     1b
2:  cmp     r12d, 2                     # two points: distance
    jne     3f
    test    r13d, r13d
    jnz     7f
    mov     eax, [rsp+32]
    call    pv2
    movsd   [rsp], xmm0
    movsd   [rsp+8], xmm1
    mov     eax, [rsp+36]
    call    pv2
    subsd   xmm0, [rsp]
    subsd   xmm1, [rsp+8]
    mulsd   xmm0, xmm0
    mulsd   xmm1, xmm1
    addsd   xmm0, xmm1
    sqrtsd  xmm0, xmm0
    mov     eax, C_DISTANCE
    mov     edx, [rsp+32]
    mov     ecx, [rsp+36]
    jmp     9f
3:  test    r12d, r12d
    jnz     7f
    cmp     r13d, 1
    jne     5f
    mov     r14d, [rsp+40]              # one entity: length or diameter / radius
    imul    eax, r14d, EN_SZ
    lea     r8, [rbx+SK_ENTS+rax]
    cmp     dword ptr [r8+EN_TYPE], E_LINE
    jne     4f
    mov     eax, [r8+EN_P0]
    call    pv2
    movsd   [rsp], xmm0
    movsd   [rsp+8], xmm1
    mov     eax, [r8+EN_P1]
    call    pv2
    subsd   xmm0, [rsp]
    subsd   xmm1, [rsp+8]
    mulsd   xmm0, xmm0
    mulsd   xmm1, xmm1
    addsd   xmm0, xmm1
    sqrtsd  xmm0, xmm0
    mov     eax, C_LENGTH
    mov     edx, r14d
    mov     ecx, -1
    jmp     9f
4:  movsd   xmm0, [r8+EN_R]
    mov     eax, C_RADIUS
    cmp     dword ptr [r8+EN_TYPE], E_CIRCLE
    jne     41f
    addsd   xmm0, xmm0
    mov     eax, C_DIAMETER
41: mov     edx, r14d
    mov     ecx, -1
    jmp     9f
5:  cmp     r13d, 2                     # two lines: the angle between
    jne     7f
    mov     eax, [rsp+40]
    call    ldir2
    movsd   [rsp], xmm0
    movsd   [rsp+8], xmm1
    mov     eax, [rsp+44]
    call    ldir2
    movsd   xmm2, [rsp]                 # cross, dot
    mulsd   xmm2, xmm1
    movsd   xmm3, [rsp+8]
    mulsd   xmm3, xmm0
    subsd   xmm2, xmm3
    movsd   xmm3, [rsp]
    mulsd   xmm3, xmm0
    movsd   xmm4, [rsp+8]
    mulsd   xmm4, xmm1
    addsd   xmm3, xmm4
    movsd   [rsp+16], xmm2
    movsd   [rsp+24], xmm3
    fld     qword ptr [rsp+16]
    fld     qword ptr [rsp+24]
    fpatan
    fstp    qword ptr [rsp+16]
    movsd   xmm0, [rsp+16]
    mov     eax, C_ANGLE
    mov     edx, [rsp+40]
    mov     ecx, [rsp+44]
    jmp     9f
7:  xor     eax, eax
9:  add     rsp, 48
    pop     r14
    pop     r13
    pop     r12
    ret

# pv2(eax=point; rbx) -> xmm0, xmm1
pv2:
    imul    eax, eax, PT_SZ
    movsd   xmm0, [rbx+SK_PTS+rax]
    movsd   xmm1, [rbx+SK_PTS+rax+8]
    ret
# ldir2(eax=line; rbx) -> xmm0, xmm1 = b - a
ldir2:
    imul    eax, eax, EN_SZ
    lea     r9, [rbx+SK_ENTS+rax]
    mov     eax, [r9+EN_P0]
    call    pv2
    movsd   xmm2, xmm0
    movsd   xmm3, xmm1
    mov     eax, [r9+EN_P1]
    call    pv2
    subsd   xmm0, xmm2
    subsd   xmm1, xmm3
    ret

# sketch.dim <value or expression> - on the selection kept by D
do_dim:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 24
    mov     r14, [rip+op_arg]
    test    r14, r14
    jz      .Ldd_need
    cmp     byte ptr [r14], 0
    je      .Ldd_need
    call    cur
    test    rax, rax
    jz      .Ldd_need
    mov     r13, rax
    mov     rbx, [rax+OB_SKETCH]
    call    dim_kind
    test    eax, eax
    jz      .Ldd_nothing
    mov     [rsp], eax
    mov     [rsp+4], edx
    mov     [rsp+8], ecx
    mov     rdi, r14                    # the value now (and kept as text)
    call    expr_eval
    test    eax, eax
    jz      .Ldd_bad
    movsd   [rsp+16], xmm0
    cmp     dword ptr [rsp], C_ANGLE    # angles: plain numbers are degrees
    jne     1f
    mov     rdi, r14
    call    has_unit
    test    eax, eax
    jnz     1f
    movsd   xmm0, [rsp+16]
    mulsd   xmm0, [rip+md_deg]
    movsd   [rsp+16], xmm0
    xor     r14d, r14d                  # (stored as the number then)
1:  mov     rdi, r13
    call    skx_begin
    test    rax, rax
    jz      .Ldd_need
    mov     rdi, rax
    mov     esi, [rsp]
    mov     edx, [rsp+4]
    mov     ecx, [rsp+8]
    mov     r8d, -1
    movsd   xmm0, [rsp+16]
    mov     r9, r14
    call    sk_add_con
    mov     rdi, r13
    call    skx_end
    mov     dword ptr [rip+skm_nsel], 0
    jmp     9f
.Ldd_bad:
    lea     rdi, [rip+s_p_err]
    mov     rsi, [rip+expr_err]
    call    log_pair
    call    undo_drop_last
    jmp     9f
.Ldd_nothing:
    lea     rdi, [rip+s_sm_nothing]
    call    log_line
    call    undo_drop_last
    jmp     9f
.Ldd_need:
    lea     rdi, [rip+s_sm_dimneed]
    call    log_line
    call    undo_drop_last
9:  add     rsp, 24
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# has_unit(rdi=text) -> eax = 1 if it has letters (a unit, a name)
has_unit:
    xor     eax, eax
1:  movzx   ecx, byte ptr [rdi]
    test    ecx, ecx
    jz      9f
    or      ecx, 0x20
    sub     ecx, 'a'
    cmp     ecx, 26
    jb      2f
    inc     rdi
    jmp     1b
2:  mov     eax, 1
9:  ret

# sketch.delete - the selected entities (and loose selected points)
do_delete:
    push    rbx
    push    r12
    sub     rsp, 8
    call    cur
    test    rax, rax
    jz      8f
    cmp     dword ptr [rip+skm_nsel], 0
    je      8f
    mov     rbx, rax
    mov     rdi, rax
    call    skx_begin
    test    rax, rax
    jz      8f
    mov     r12, rax
    lea     rdi, [rip+del_ents]         # the masks
    xor     eax, eax
    mov     ecx, 256
    rep     stosb
    lea     rdi, [rip+del_pts]
    mov     ecx, 256
    rep     stosb
    xor     ecx, ecx
1:  cmp     ecx, [rip+skm_nsel]
    jae     2f
    lea     rax, [rip+skm_sel]
    mov     eax, [rax+rcx*4]
    mov     edx, eax
    shr     edx, 16
    and     eax, 0xffff
    lea     r8, [rip+del_ents]
    cmp     edx, K_ENT
    je      11f
    lea     r8, [rip+del_pts]
11: mov     byte ptr [r8+rax], 1
    inc     ecx
    jmp     1b
2:  mov     rdi, r12
    lea     rsi, [rip+del_ents]
    lea     rcx, [rip+del_pts]
    call    sk_delete
    mov     dword ptr [rip+skm_nsel], 0
    mov     rdi, rbx
    call    skx_end
    jmp     9f
8:  lea     rdi, [rip+s_sm_need]
    call    log_line
    call    undo_drop_last
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# ---- the overlay ---------------------------------------------------------------
# skm_overlay - (viewport_draw, camera set) points, selection, labels, the
#   tool's preview and the status line
skm_overlay:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 56
    call    cur
    test    rax, rax
    jz      .Lov_out
    mov     r15, rax
    mov     rbx, [rax+OB_SKETCH]
    mov     rdi, rax
    call    frame
    # the selected entities, highlighted
    xor     r12d, r12d
1:  cmp     r12d, [rip+skm_nsel]
    jae     2f
    lea     rax, [rip+skm_sel]
    mov     eax, [rax+r12*4]
    mov     edx, eax
    shr     edx, 16
    cmp     edx, K_ENT
    jne     11f
    and     eax, 0xffff
    mov     edi, eax
    mov     esi, COL_ACCENT
    call    draw_ent
11: inc     r12d
    jmp     1b
2:  # points: little squares, coloured by status (selected: accent)
    xor     r12d, r12d
3:  cmp     r12d, [rbx+SK_NPT]
    jae     4f
    mov     eax, r12d
    call    pscreen
    test    eax, eax
    jz      32f
    cvttss2si r13d, xmm0
    cvttss2si r14d, xmm1
    imul    eax, r12d, PT_SZ
    mov     ebp, COL_UNDER
    test    dword ptr [rbx+SK_PTS+rax+16], F_FULL
    jz      31f
    mov     ebp, COL_FULLY
31: mov     edi, r12d
    or      edi, K_PT << 16
    call    sel_has
    test    eax, eax
    jz      311f
    mov     ebp, COL_ACCENT
311:lea     edi, [r13-2]
    lea     esi, [r14-2]
    mov     edx, 5
    mov     ecx, 5
    mov     r8d, ebp
    call    fill_rect_px
32: inc     r12d
    jmp     3b
4:  call    labels                      # constraint labels
    # the tool's preview: from the first click to the pointer
    cmp     dword ptr [rip+skm_tool], T_SELECT
    je      6f
    cmp     dword ptr [rip+skm_stage], 0
    je      6f
    mov     eax, [rip+skm_hvp]
    cmp     eax, [rip+ed_node]
    jne     6f
    mov     edi, [rip+skm_hx]
    mov     esi, [rip+skm_hy]
    call    ray_uv
    test    eax, eax
    jz      6f
    movsd   [rsp], xmm0
    movsd   [rsp+8], xmm1
    movsd   xmm0, [rip+skm_p0]
    movsd   xmm1, [rip+skm_p0+8]
    lea     rsi, [rip+lp0]
    call    world_at
    cmp     dword ptr [rip+skm_tool], T_LINE
    jne     5f
    movsd   xmm0, [rsp]
    movsd   xmm1, [rsp+8]
    lea     rsi, [rip+lp1]
    call    world_at
    mov     edx, COL_ACCENT
    call    line3d
    jmp     6f
5:  cmp     dword ptr [rip+skm_tool], T_RECT
    jne     55f
    movsd   xmm0, [rsp]                 # four sides
    movsd   xmm1, [rip+skm_p0+8]
    call    pv_to
    movsd   xmm0, [rsp]
    movsd   xmm1, [rsp+8]
    call    pv_to
    movsd   xmm0, [rip+skm_p0]
    movsd   xmm1, [rsp+8]
    call    pv_to
    movsd   xmm0, [rip+skm_p0]
    movsd   xmm1, [rip+skm_p0+8]
    call    pv_to
    jmp     6f
55: movsd   xmm0, [rsp]                 # circle: the radius line
    movsd   xmm1, [rsp+8]
    call    pv_to
6:  # the status line
    call    fmt_reset
    lea     rdi, [rip+s_sm_head]
    call    fmt_str
    mov     rdi, r15
    call    fmt_str
    cmp     dword ptr [rbx+SK_NBAD], 0
    je      61f
    lea     rdi, [rip+s_sm_bad]
    call    fmt_str
    mov     edi, [rbx+SK_NBAD]
    call    fmt_int
61: cmp     dword ptr [rbx+SK_DOF], 0
    jne     62f
    lea     rdi, [rip+s_sm_full]
    call    fmt_str
    jmp     63f
62: lea     rdi, [rip+s_sm_dof]
    call    fmt_str
    mov     edi, [rbx+SK_DOF]
    call    fmt_int
63: mov     edi, [rip+cvs_x0]
    add     edi, 10
    mov     esi, [rip+cvs_y0]
    add     esi, 48
    lea     rdx, [rip+fmt_buf]
    mov     ecx, COL_ACCENT
    call    draw_text
    lea     rdx, [rip+s_sm_tools]
    mov     eax, [rip+skm_tool]
    cmp     eax, T_LINE
    jne     64f
    lea     rdx, [rip+s_sm_t_line]
64: cmp     eax, T_CIRCLE
    jne     65f
    lea     rdx, [rip+s_sm_t_circ]
65: cmp     eax, T_RECT
    jne     66f
    lea     rdx, [rip+s_sm_t_rect]
66: mov     edi, [rip+cvs_x0]
    add     edi, 10
    mov     esi, [rip+cvs_y0]
    add     esi, 66
    mov     ecx, COL_TEXT_DIM
    call    draw_text
.Lov_out:
    add     rsp, 56
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# pv_to(xmm0, xmm1) - a preview segment from lp0 to (u, v); then lp0 = there
pv_to:
    sub     rsp, 8
    lea     rsi, [rip+lp1]
    call    world_at
    mov     edx, COL_ACCENT
    call    line3d
    mov     rax, [rip+lp1]
    mov     [rip+lp0], rax
    mov     eax, [rip+lp1+8]
    mov     [rip+lp0+8], eax
    add     rsp, 8
    ret

# world_at(xmm0=u, xmm1=v, rsi=out world float[3]; rbx = sketch)
world_at:
    push    rbx
    push    r12
    sub     rsp, 24
    mov     r12, rsi
    mov     rdi, rbx
    lea     rsi, [rsp]
    call    sk_plane_xyz
    lea     rdi, [rip+sm_m]
    lea     rsi, [rsp]
    mov     rdx, r12
    call    xform_point
    add     rsp, 24
    pop     r12
    pop     rbx
    ret

# sel_has(edi=key) -> eax = 1 if selected
sel_has:
    xor     eax, eax
    xor     ecx, ecx
1:  cmp     ecx, [rip+skm_nsel]
    jae     9f
    lea     rdx, [rip+skm_sel]
    cmp     [rdx+rcx*4], edi
    je      2f
    inc     ecx
    jmp     1b
2:  mov     eax, 1
9:  ret

# draw_ent(edi=entity, esi=colour) - one entity, in world space
draw_ent:
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 40
    mov     r13d, esi
    imul    eax, edi, EN_SZ
    lea     r14, [rbx+SK_ENTS+rax]
    mov     r15d, 1
    cmp     dword ptr [r14+EN_TYPE], E_LINE
    je      1f
    mov     r15d, 48
1:  xor     r12d, r12d
2:  cmp     r12d, r15d
    ja      9f
    mov     [rsp+24], r12d
    mov     [rsp+28], r15d
    cmp     dword ptr [r14+EN_TYPE], E_LINE
    jne     3f
    mov     eax, [r14+EN_P0]
    test    r12d, r12d
    jz      21f
    mov     eax, [r14+EN_P1]
21: call    pv2
    jmp     4f
3:  mov     [rsp], r12d                 # (round_uv reads its caller's
    mov     [rsp+4], r15d               #  [rsp] = i, [rsp+4] = n)
    call    round_uv
4:  lea     rsi, [rip+lp1]
    call    world_at
    test    r12d, r12d
    jz      5f
    mov     edx, r13d
    call    line3d
5:  mov     rax, [rip+lp1]
    mov     [rip+lp0], rax
    mov     eax, [rip+lp1+8]
    mov     [rip+lp0+8], eax
    inc     r12d
    jmp     2b
9:  add     rsp, 40
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    ret
# labels - a short label per constraint at its entity (dimensions: values)
labels:
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 56
    xor     r12d, r12d
.Llb_con:
    cmp     r12d, [rbx+SK_NCON]
    jae     .Llb_out
    imul    eax, r12d, CN_SZ
    lea     r13, [rbx+SK_CONS+rax]
    mov     eax, [r13+CN_TYPE]
    lea     r14, [rip+s_lbl_h]
    cmp     eax, C_HORIZONTAL
    je      .Llb_ent
    lea     r14, [rip+s_lbl_v]
    cmp     eax, C_VERTICAL
    je      .Llb_ent
    lea     r14, [rip+s_lbl_p]
    cmp     eax, C_PARALLEL
    je      .Llb_ent
    lea     r14, [rip+s_lbl_n]
    cmp     eax, C_PERP
    je      .Llb_ent
    lea     r14, [rip+s_lbl_e]
    cmp     eax, C_EQUAL
    je      .Llb_ent
    lea     r14, [rip+s_lbl_t]
    cmp     eax, C_TANGENT
    je      .Llb_ent
    cmp     eax, C_LENGTH
    je      .Llb_val
    cmp     eax, C_RADIUS
    je      .Llb_val
    cmp     eax, C_DIAMETER
    je      .Llb_val
    cmp     eax, C_ANGLE
    je      .Llb_val
    lea     r14, [rip+s_lbl_f]
    cmp     eax, C_FIXED
    je      .Llb_pt
    lea     r14, [rip+s_lbl_m]
    cmp     eax, C_MIDPOINT
    je      .Llb_pt
    cmp     eax, C_DISTANCE
    je      .Llb_dist
    cmp     eax, C_HDIST
    je      .Llb_dist
    cmp     eax, C_VDIST
    je      .Llb_dist
    jmp     .Llb_next
.Llb_val:                               # the value (or its expression)
    call    fmt_reset
    cmp     dword ptr [r13+CN_TYPE], C_RADIUS
    jne     1f
    lea     rdi, [rip+s_lbl_r]
    call    fmt_str
1:  cmp     dword ptr [r13+CN_TYPE], C_DIAMETER
    jne     2f
    lea     rdi, [rip+s_lbl_d]
    call    fmt_str
2:  cmp     byte ptr [r13+CN_EXPR], 0
    je      3f
    lea     rdi, [r13+CN_EXPR]
    call    fmt_str
    jmp     4f
3:  movsd   xmm0, [r13+CN_VAL]
    cmp     dword ptr [r13+CN_TYPE], C_ANGLE
    jne     31f
    mulsd   xmm0, [rip+md_rad2deg]
31: cvtsd2ss xmm0, xmm0
    call    fmt_val3
    cmp     dword ptr [r13+CN_TYPE], C_ANGLE
    jne     4f
    lea     rdi, [rip+s_deg]
    call    fmt_str
4:  lea     r14, [rip+fmt_buf]
.Llb_ent:                               # at the entity's middle
    mov     eax, [r13+CN_A]
    cmp     eax, [rbx+SK_NENT]
    jae     .Llb_next
    imul    eax, eax, EN_SZ
    lea     r15, [rbx+SK_ENTS+rax]
    cmp     dword ptr [r15+EN_TYPE], E_LINE
    jne     5f
    mov     eax, [r15+EN_P0]            # the line's midpoint
    call    pv2
    movsd   [rsp], xmm0
    movsd   [rsp+8], xmm1
    mov     eax, [r15+EN_P1]
    call    pv2
    addsd   xmm0, [rsp]
    addsd   xmm1, [rsp+8]
    mulsd   xmm0, [rip+md_half]
    mulsd   xmm1, [rip+md_half]
    jmp     .Llb_draw
5:  mov     eax, [r15+EN_P0]            # circles: above the centre by r
    call    pv2
    addsd   xmm1, [r15+EN_R]
    jmp     .Llb_draw
.Llb_pt:
    mov     eax, [r13+CN_A]
    cmp     eax, [rbx+SK_NPT]
    jae     .Llb_next
    call    pv2
    jmp     .Llb_draw
.Llb_dist:                              # between the two points
    mov     eax, [r13+CN_A]
    cmp     eax, [rbx+SK_NPT]
    jae     .Llb_next
    call    pv2
    movsd   [rsp], xmm0
    movsd   [rsp+8], xmm1
    mov     eax, [r13+CN_B]
    cmp     eax, [rbx+SK_NPT]
    jae     .Llb_next
    call    pv2
    addsd   xmm0, [rsp]
    addsd   xmm1, [rsp+8]
    mulsd   xmm0, [rip+md_half]
    mulsd   xmm1, [rip+md_half]
    movsd   [rsp+16], xmm0
    movsd   [rsp+24], xmm1
    call    fmt_reset
    cmp     byte ptr [r13+CN_EXPR], 0
    je      6f
    lea     rdi, [r13+CN_EXPR]
    call    fmt_str
    jmp     7f
6:  movsd   xmm0, [r13+CN_VAL]
    cvtsd2ss xmm0, xmm0
    call    fmt_val3
7:  lea     r14, [rip+fmt_buf]
    movsd   xmm0, [rsp+16]
    movsd   xmm1, [rsp+24]
.Llb_draw:
    mov     rdi, rbx
    call    screen
    test    eax, eax
    jz      .Llb_next
    cvttss2si edi, xmm0                 # physical -> logical, a little off
    call    to_lg
    mov     [rsp+40], eax
    cvttss2si edi, xmm1
    call    to_lg
    mov     esi, eax
    mov     edi, [rsp+40]
    add     edi, 6
    sub     esi, 18
    mov     ecx, COL_TEXT
    test    dword ptr [r13+CN_FLAGS], F_BAD
    jz      8f
    mov     ecx, COL_CONFL
8:  mov     rdx, r14
    call    draw_text
.Llb_next:
    inc     r12d
    jmp     .Llb_con
.Llb_out:
    add     rsp, 56
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    ret

.section .rodata
.align 16
mf_abs:         .long 0x7fffffff, 0, 0, 0
md_abs:         .quad 0x7fffffffffffffff, 0
md_2pi:         .double 6.28318530717958647692
md_deg:         .double 0.017453292519943295
md_rad2deg:     .double 57.29577951308232
s_p_err:        .asciz "  sketch.dim: "

.section .bss
.align 4
skm_px:         .skip 4                 # the pointer, physical
skm_py:         .skip 4
del_ents:       .skip 256
del_pts:        .skip 256

.section .note.GNU-stack,"",@progbits
