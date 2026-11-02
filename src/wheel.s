# =============================================================================
#  BeeModel - the wheel menu (#420): a right-click in the 3D viewport opens
#  a ring of round, coloured entries around the pointer instead of a list
#  (Preferences > Input > Wheel menu turns it back into the list).
#
#  An entry is an operator or a group. Hovering a group opens its choices
#  on an outer arc beside it; it stays open until another entry of the
#  ring is hovered. A click runs an entry; so does letting go of the right
#  button over one after dragging there from the press that opened the
#  wheel. The centre, a click outside it, the right button and Esc close
#  it. Entries that cannot run now are greyed (op_poll) and say why above
#  the wheel.
#
#  It is drawn in one pass over its square: the distance and the angle of
#  each pixel give the ring, the sector and the anti-aliased edges (the gaps
#  between sectors too), with a soft shadow outside; the icons and labels go
#  on top. ui_tree reports the entries as menu items (with "wheel":1), the
#  open group's choices as level 1, so scripts click them like a list's.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"
.include "icons.inc"

# exports
.globl wh_on
.globl wh_ctx_open
.globl wh_close
.globl wh_hit
.globl wh_hover
.globl wh_press
.globl wh_release
.globl wh_draw
.globl wh_json
.globl wh_key

# the rings (logical px): the hole, the entries, a gap, the group's choices
.equ R0,        50                      # (#440: a little bigger, small labels,
.equ R1,        156                     #  so eleven entries' words fit)
.equ R2,        162
.equ R3,        238
.equ SH,        12                      # the shadow outside the ring
.equ R_MID,     104                     # an entry: its icon over its label here
.equ R_KMID,    200                    #  (a choice: here)
.equ ROOM,      88                      # a label's width at most (a choice's:
.equ KROOM,     88                      #  this; both: less where the arc is narrower)
.equ R_HIT,     R_MID                   # where ui_tree says an entry is
.equ R_KHIT,    R_KMID
.equ INFO_H,    22                      # the line above the wheel
.equ MARGIN_X,  R3+4                    # the centre stays this far inside
.equ MARGIN_T,  R3+INFO_H+10            #  the window
.equ MARGIN_B,  R3+4
.equ DRAG_MIN,  6                       # a right drag this long picks on release
.equ WE_SZ,     40                      # an entry: target, short label, icon, colour,
.equ WE_ARG,    24                      #  the operator's argument (0: none),
.equ WE_POLL,   32                      #  a poll asked before the operator's (0: none)
.equ ICON_INK,  0xfafafb                # (no theme maps it)

# hit: an entry's index, KID+choice, or one of these
.equ H_NONE,   -1
.equ H_CENTRE, -2
.equ KID,      0x100

# a group: what SUBMENU makes (tag, label, entries, count), its entries
#   wheel entries
.macro WGROUP sym, label, items, count
    .pushsection .rodata
.Lwg\@: .asciz "\label"
    .balign 8
\sym:   .quad SUBTAG, .Lwg\@, \items, \count
    .popsection
.endm

.macro WE target, short, icon, colour, arg=0, poll=0
    .quad \target, \short
    .long \icon, \colour
    .quad \arg, \poll
.endm

.section .bss
.align 8
wh_list:        .skip 8                 # the entries
wh_kids:        .skip 8                 # the open group's choices
wh_on:          .skip 4
wh_n:           .skip 4
wh_cx:          .skip 4                 # the centre (logical)
wh_cy:          .skip 4
wh_sel:         .skip 4                 # the lit entry, -1 none
wh_grp:         .skip 4                 # the open group, -1 none
wh_nk:          .skip 4                 #  its choices
wh_ksel:        .skip 4                 # the lit choice, -1 none
wh_fresh:       .skip 4                 # the right button is still down from opening
wh_down:        .skip 4                 # what the left button went down on
wh_px:          .skip 4                 # where the opening press was
wh_py:          .skip 4
# the pass (physical px, floats)
f_cx:           .skip 4
f_cy:           .skip 4
f_r0:           .skip 4
f_r1:           .skip 4
f_r2:           .skip 4
f_r3:           .skip 4
f_rb:           .skip 4                 # the outermost pixel drawn
f_sh:           .skip 4
f_rim:          .skip 4                 # the lit sector's coloured edge
f_gap:          .skip 4                 # half a gap
f_step:         .skip 4                 # an entry's angle
f_kstep:        .skip 4                 # a choice's
f_k0:           .skip 4                 # the group's arc starts here
f_kend:         .skip 4                 #  and is this long
f_sc:           .skip 4                 # logical -> physical
c_bg:           .skip 4                 # themed colours
c_hov:          .skip 4
c_sh:           .skip 4
c_off:          .skip 4
c_rim:          .skip 4*16              # each sector's edge colour
t_ang:          .skip 4                 # (polar's)
t_rad:          .skip 4
t_x:            .skip 4
t_y:            .skip 4
info_buf:       .skip 256
badge_buf:      .skip 4                 # a key's character

.section .rodata
.align 16
m_abs:          .long 0x7fffffff, 0, 0, 0
f_half:         .float 0.5
f_one:          .float 1.0
f_256:          .float 256.0
f_pi:           .float 3.14159265
f_pi2:          .float 1.57079633
f_2pi:          .float 6.28318531
f_at1:          .float -0.0464964749
f_at2:          .float 0.15931422
f_at3:          .float -0.327622764
f_kdeg:         .float 0.663225         # 38 degrees: a choice
f_65536:        .float 65536.0
f_shade:        .float 0.45             # the shadow's darkest
f_gapdark:      .float 0.85             # the gaps'
s_repair:       .asciz "Repair"
s_measure:      .asciz "Measure"
s_inset:        .asciz "Inset"
s_objmode:      .asciz "Object"
s_editmode:     .asciz "Edit"
s_ask:          .asciz "Ask AI"
s_setcam:       .asciz "Camera"
s_hide:         .asciz "Hide"
s_reveal:       .asciz "Reveal"
s_union:        .asciz "Union"
s_diff:         .asciz "Difference"
s_isect:        .asciz "Intersect"
s_center:       .asciz "At Center"
s_collapse:     .asciz "Collapse"
s_bydist:       .asciz "By Distance"
s_verts:        .asciz "Vertices"
s_edges:        .asciz "Edges"
s_faces:        .asciz "Faces"
s_fill:         .asciz "Fill"
s_bridge:       .asciz "Bridge"
s_flip:         .asciz "Flip"
s_normals:      .asciz "Normals"
s_active:       .asciz "Active"
s_passive:      .asciz "Passive"
s_remove:       .asciz "Remove"
a_active:       .asciz "active fit"
a_passive:      .asciz "passive fit"
s_rubber:       .asciz "Rubber"
s_ice:          .asciz "Ice"
s_wood:         .asciz "Wood"
s_metal:        .asciz "Metal"
s_stone:        .asciz "Stone"
a_rubber:       .asciz "material rubber"
a_ice:          .asciz "material ice"
a_wood:         .asciz "material wood"
a_metal:        .asciz "material metal"
a_stone:        .asciz "material stone"
s_gold:         .asciz "Gold"
s_chrome:       .asciz "Chrome"
s_plastic:      .asciz "Plastic"
s_glass:        .asciz "Glass"
s_marble:       .asciz "Marble"
s_emissive:     .asciz "Emissive"
p_gold:         .asciz "gold"
p_chrome:       .asciz "chrome"
p_plastic:      .asciz "plastic"
p_rubber:       .asciz "rubber"
p_glass:        .asciz "glass"
p_wood:         .asciz "wood"
p_marble:       .asciz "marble"
p_emissive:     .asciz "emissive"
s_sep:          .asciz ": "
j_a:            .asciz "{\"name\":"
j_sub:          .asciz "\"submenu\""
j_b:            .asciz ",\"sub\":"
j_c:            .asciz ",\"kind\":\"menuitem\",\"wheel\":1,\"level\":"
j_x:            .asciz ",\"x\":"
j_y:            .asciz ",\"y\":"
j_wh:           .asciz ",\"w\":80,\"h\":24,\"label\":"
j_why:          .asciz ",\"why\":"
j_null:         .asciz "null"
j_end:          .asciz "}"
j_key:          .asciz ",\"key\":\""
j_q:            .asciz "\""
key_chars:      .ascii "1234567890-"        # entry / choice i's key (#440)
.equ NKEYS, 11
# evdev code, the entry it picks: 1-9 0 - on the top row and the keypad
key_map:        .byte 2,0, 3,1, 4,2, 5,3, 6,4, 7,5, 8,6, 9,7, 10,8, 11,9, 12,10
                .byte 79,0, 80,1, 81,2, 75,3, 76,4, 77,5, 71,6, 72,7, 73,8, 82,9, 74,10, 0

# ---- the wheels -------------------------------------------------------------------
.align 8
wheel_object:                           # (short labels where neighbours share a row:
                                        #  the top and the bottom)
    WE op_ai_ask,       s_ask,      ICON_SPARKLE,    0x8b5cf6
    WE op_delete,       0,          ICON_TRASH,      0xe5484d
    WE op_duplicate,    0,          ICON_DUPLICATE,  0x3b82f6
    WE wg_vis,          0,          ICON_EYE,        0x14b8a6
    WE wg_bool,         0,          ICON_BOOL_UNION, 0x6366f1
    WE op_edit_toggle,  s_editmode, ICON_EDIT,       0xf59e0b
    WE wg_mat,          0,          ICON_MATERIAL,   0xd946ef
    WE wg_phys,         0,          ICON_PHYSICS,    0xf97316
    WE op_obj_measure,  s_measure,  ICON_WEIGHT,     0x0ea5e9
    WE op_cam_to_view,  s_setcam,   ICON_CAMERA,     0xec4899
    WE op_repair,       s_repair,   ICON_REPAIR,     0x22a55b
.equ wheel_object_n, (. - wheel_object) / WE_SZ
wheel_edit:
    WE op_ai_ask,       s_ask,      ICON_SPARKLE,    0x8b5cf6
    WE op_m_extrude,    0,          ICON_EXTRUDE,    0x22a55b
    WE op_m_inset,      s_inset,    ICON_INSET,      0x14b8a6
    WE op_m_bevel,      0,          ICON_BEVEL,      0x0ea5e9
    WE wg_cut,          0,          ICON_KNIFE,      0xf97316
    WE wg_merge,        0,          ICON_MERGE,      0x6366f1
    WE wg_mdel,         0,          ICON_TRASH,      0xe5484d
    WE wg_more,         0,          ICON_MORE,       0x64748b
    WE op_edit_toggle,  s_objmode,  ICON_OBJECT,     0xf59e0b
.equ wheel_edit_n, (. - wheel_edit) / WE_SZ
# the groups' choices (their colour: the group's)
wk_vis:
    WE op_hide,         s_hide,     ICON_EYE_OFF,    0
    WE op_reveal,       s_reveal,   ICON_EYE,        0
wk_bool:
    WE op_bool_union,   s_union,    ICON_BOOL_UNION, 0
    WE op_bool_diff,    s_diff,     ICON_BOOL_DIFF,  0
    WE op_bool_isect,   s_isect,    ICON_BOOL_ISECT, 0
wk_mat:                                 # (#438: a preset look, one material each)
    WE op_mat_apply,    s_gold,     ICON_MATERIAL,   0, p_gold
    WE op_mat_apply,    s_chrome,   ICON_MATERIAL,   0, p_chrome
    WE op_mat_apply,    s_plastic,  ICON_MATERIAL,   0, p_plastic
    WE op_mat_apply,    s_rubber,   ICON_MATERIAL,   0, p_rubber
    WE op_mat_apply,    s_glass,    ICON_MATERIAL,   0, p_glass
    WE op_mat_apply,    s_wood,     ICON_MATERIAL,   0, p_wood
    WE op_mat_apply,    s_marble,   ICON_MATERIAL,   0, p_marble
    WE op_mat_apply,    s_emissive, ICON_MATERIAL,   0, p_emissive
wk_phys:                                # (#437: Active / Passive make it a body;
    WE op_rb_add,       s_active,   ICON_PHYSICS,    0, a_active     #  the rest
    WE op_rb_add,       s_passive,  ICON_LOCK,       0, a_passive    #  change one)
    WE op_rb_add,       s_rubber,   ICON_DOT,        0, a_rubber, poll_body
    WE op_rb_add,       s_ice,      ICON_DOT,        0, a_ice, poll_body
    WE op_rb_add,       s_wood,     ICON_DOT,        0, a_wood, poll_body
    WE op_rb_add,       s_metal,    ICON_DOT,        0, a_metal, poll_body
    WE op_rb_add,       s_stone,    ICON_DOT,        0, a_stone, poll_body
    WE op_rb_rem,       s_remove,   ICON_TRASH,      0, 0, poll_body
wk_cut:
    WE op_m_loopcut,    0,          ICON_LOOPCUT,    0
    WE op_m_knife,      0,          ICON_KNIFE,      0
wk_merge:
    WE op_m_merge_c,    s_center,   ICON_MERGE,      0
    WE op_m_merge_col,  s_collapse, ICON_DOT,        0
    WE op_m_merge_d,    s_bydist,   ICON_MEASURE,    0
wk_mdel:
    WE op_m_del_v,      s_verts,    ICON_VERTEX,     0
    WE op_m_del_e,      s_edges,    ICON_EDGE,       0
    WE op_m_del_f,      s_faces,    ICON_PLANE,      0
wk_more:
    WE op_m_subdivide,  0,          ICON_SUBDIVIDE,  0
    WE op_m_fill,       s_fill,     ICON_FILL,       0
    WE op_m_bridge,     s_bridge,   ICON_BRIDGE,     0
    WE op_m_flip,       s_flip,     ICON_FLIP,       0
    WE op_m_recalc,     s_normals,  ICON_NORMALS,    0

WGROUP wg_vis,   "Visibility", wk_vis, 2
WGROUP wg_bool,  "Boolean", wk_bool, 3
WGROUP wg_mat,   "Material", wk_mat, 8
WGROUP wg_phys,  "Physics", wk_phys, 8
WGROUP wg_cut,   "Cut", wk_cut, 2
WGROUP wg_merge, "Merge", wk_merge, 3
WGROUP wg_mdel,  "Delete", wk_mdel, 3
WGROUP wg_more,  "More", wk_more, 5

.text

# ---- opening and closing ----------------------------------------------------------
# wh_ctx_open -> eax = 1: the viewport's wheel (edit mode: the mesh's) at
#   the pointer, kept inside the window
wh_ctx_open:
    sub     rsp, 8
    lea     rax, [rip+wheel_object]
    mov     ecx, wheel_object_n
    cmp     dword ptr [rip+edit_obj], 0
    je      1f
    lea     rax, [rip+wheel_edit]
    mov     ecx, wheel_edit_n
1:  mov     [rip+wh_list], rax
    mov     [rip+wh_n], ecx
    mov     eax, [rip+ptr_x]
    mov     [rip+wh_px], eax
    mov     edx, [rip+win_w]
    mov     ecx, MARGIN_X
    sub     edx, ecx
    call    clamp_c
    mov     [rip+wh_cx], eax
    mov     eax, [rip+ptr_y]
    mov     [rip+wh_py], eax
    mov     edx, [rip+win_h]
    sub     edx, MARGIN_B
    mov     ecx, MARGIN_T
    call    clamp_c
    mov     [rip+wh_cy], eax
    mov     dword ptr [rip+wh_sel], -1
    mov     dword ptr [rip+wh_grp], -1
    mov     dword ptr [rip+wh_ksel], -1
    mov     dword ptr [rip+wh_nk], 0
    mov     dword ptr [rip+wh_down], H_NONE
    mov     dword ptr [rip+wh_fresh], 1
    mov     dword ptr [rip+wh_on], 1
    mov     dword ptr [rip+dirty], 1
    mov     edi, [rip+ptr_x]
    mov     esi, [rip+ptr_y]
    call    wh_hover
    mov     eax, 1
    add     rsp, 8
    ret

# clamp_c(eax = v, ecx = low, edx = high) -> eax (both ends crossed: the middle)
clamp_c:
    cmp     edx, ecx
    jge     1f
    lea     eax, [rcx+rdx]
    sar     eax, 1
    ret
1:  cmp     eax, ecx
    cmovl   eax, ecx
    cmp     eax, edx
    cmovg   eax, edx
    ret

wh_close:
    mov     dword ptr [rip+wh_on], 0
    mov     dword ptr [rip+wh_fresh], 0
    mov     dword ptr [rip+dirty], 1
    ret

# ---- entries ----------------------------------------------------------------------
# entry(edi = hit) -> rax = its WE record, 0 for none (an entry, KID + choice)
entry:
    test    edi, edi
    js      8f
    cmp     edi, KID
    jae     1f
    cmp     edi, [rip+wh_n]
    jae     8f
    imul    eax, edi, WE_SZ
    add     rax, [rip+wh_list]
    ret
1:  sub     edi, KID
    cmp     edi, [rip+wh_nk]
    jae     8f
    imul    eax, edi, WE_SZ
    add     rax, [rip+wh_kids]
    ret
8:  xor     eax, eax
    ret

# full_label(rdi = WE) -> rax ; short_label(rdi = WE) -> rax
full_label:
    cmp     qword ptr [rdi+WE_ARG], 0   # (one operator, several arguments:
    je      2f                          #  the entry's own label)
    mov     rax, [rdi+8]
    test    rax, rax
    jnz     9f
2:  mov     rax, [rdi]
    cmp     qword ptr [rax], SUBTAG
    jne     1f
    mov     rax, [rax+SUB_LABEL]
    ret
1:  mov     rax, [rax+OP_LABEL]
9:  ret
short_label:
    mov     rax, [rdi+8]
    test    rax, rax
    jz      full_label
    ret

# why(rdi = WE) -> rax = why it cannot run now, 0 if it can (groups can)
why:
    mov     rax, [rdi+WE_POLL]          # the entry's own poll first
    mov     rdi, [rdi]
    test    rax, rax
    jz      1f
    push    rdi
    call    rax
    pop     rdi
    test    rax, rax
    jnz     9f
1:  xor     eax, eax
    cmp     qword ptr [rdi], SUBTAG
    je      9f
    sub     rsp, 8
    call    op_poll
    add     rsp, 8
9:  ret

# ---- geometry ---------------------------------------------------------------------
# atan2_top(xmm0 = dx, xmm1 = dy, y down) -> xmm0 = the angle from straight
#   up, clockwise, 0 .. 2 pi (a polynomial: within 1e-5)
atan2_top:
    movaps  xmm2, xmm0                  # y = dx, x = -dy
    xorps   xmm3, xmm3
    subss   xmm3, xmm1
    movaps  xmm4, xmm2
    andps   xmm4, [rip+m_abs]           # |y|
    movaps  xmm5, xmm3
    andps   xmm5, [rip+m_abs]           # |x|
    movaps  xmm6, xmm4
    maxss   xmm6, xmm5
    xorps   xmm0, xmm0
    ucomiss xmm6, xmm0
    jbe     9f
    movaps  xmm7, xmm4
    minss   xmm7, xmm5
    divss   xmm7, xmm6                  # a = min / max
    movaps  xmm1, xmm7
    mulss   xmm1, xmm1                  # s
    movss   xmm0, [rip+f_at1]
    mulss   xmm0, xmm1
    addss   xmm0, [rip+f_at2]
    mulss   xmm0, xmm1
    addss   xmm0, [rip+f_at3]
    mulss   xmm0, xmm1
    mulss   xmm0, xmm7
    addss   xmm0, xmm7                  # atan(a)
    ucomiss xmm4, xmm5
    jbe     1f
    movss   xmm1, [rip+f_pi2]           # |y| > |x|: pi/2 - r
    subss   xmm1, xmm0
    movaps  xmm0, xmm1
1:  xorps   xmm1, xmm1
    ucomiss xmm1, xmm3
    jbe     2f
    movss   xmm1, [rip+f_pi]            # x < 0: pi - r
    subss   xmm1, xmm0
    movaps  xmm0, xmm1
2:  xorps   xmm1, xmm1
    ucomiss xmm1, xmm2
    jbe     9f
    movss   xmm1, [rip+f_2pi]           # y < 0: 2 pi - r
    subss   xmm1, xmm0
    movaps  xmm0, xmm1
9:  ret

# sector(xmm0 = angle, xmm1 = arc start, xmm2 = step, ecx = count) -> eax =
#   which (-1: past the arc), xmm0 = how far into it (0..1)
sector:
    subss   xmm0, xmm1
    xorps   xmm3, xmm3
    ucomiss xmm3, xmm0
    jbe     1f
    addss   xmm0, [rip+f_2pi]
1:  divss   xmm0, xmm2
    cvttss2si eax, xmm0
    cvtsi2ss xmm3, eax
    subss   xmm0, xmm3
    cmp     eax, ecx
    jl      2f
    mov     eax, -1
2:  ret

# entry_arc -> xmm1 = where entry 0's sector starts, xmm2 = the step
#   (entry i is centred at i x step from the top); kid_arc: the open
#   group's choices
entry_arc:
    cvtsi2ss xmm2, dword ptr [rip+wh_n]
    movss   xmm3, [rip+f_2pi]
    divss   xmm3, xmm2
    movaps  xmm2, xmm3
    mulss   xmm3, [rip+f_half]
    movss   xmm1, [rip+f_2pi]
    subss   xmm1, xmm3
    ret
kid_arc:
    call    entry_arc                   # the group's centre, less half the arc
    cvtsi2ss xmm1, dword ptr [rip+wh_grp]
    mulss   xmm1, xmm2
    movss   xmm2, [rip+f_kdeg]
    cvtsi2ss xmm3, dword ptr [rip+wh_nk]
    mulss   xmm3, xmm2
    mulss   xmm3, [rip+f_half]
    subss   xmm1, xmm3
    xorps   xmm3, xmm3
    ucomiss xmm3, xmm1
    jbe     1f
    addss   xmm1, [rip+f_2pi]
1:  ret

# polar(xmm0 = angle from the top, xmm1 = radius) -> eax = x, edx = y
#   (logical, around the centre)
polar:
    movss   [rip+t_ang], xmm0
    movss   [rip+t_rad], xmm1
    fld     dword ptr [rip+t_ang]
    fsincos                             # st0 cos, st1 sin
    fmul    dword ptr [rip+t_rad]
    fistp   dword ptr [rip+t_y]
    fmul    dword ptr [rip+t_rad]
    fistp   dword ptr [rip+t_x]
    mov     eax, [rip+wh_cx]
    add     eax, [rip+t_x]
    mov     edx, [rip+wh_cy]
    sub     edx, [rip+t_y]
    ret

# at_entry(edi = i, esi = radius) -> eax, edx: on entry i's middle line
at_entry:
    push    rbx
    mov     ebx, edi
    cvtsi2ss xmm4, esi
    call    entry_arc
    cvtsi2ss xmm0, ebx
    mulss   xmm0, xmm2
    movaps  xmm1, xmm4
    call    polar
    pop     rbx
    ret

# at_kid(edi = j, esi = radius) -> eax, edx: on choice j's
at_kid:
    push    rbx
    mov     ebx, edi
    cvtsi2ss xmm4, esi
    call    kid_arc
    cvtsi2ss xmm0, ebx
    addss   xmm0, [rip+f_half]
    mulss   xmm0, xmm2
    addss   xmm0, xmm1
    movaps  xmm1, xmm4
    call    polar
    pop     rbx
    ret

# wh_hit(edi = x, esi = y) -> eax = the entry there, KID + a choice, H_CENTRE
#   or H_NONE (the gaps between sectors count as theirs)
wh_hit:
    push    rbx
    push    r12
    sub     rsp, 8
    sub     edi, [rip+wh_cx]
    sub     esi, [rip+wh_cy]
    cvtsi2ss xmm0, edi
    cvtsi2ss xmm1, esi
    movaps  xmm2, xmm0
    mulss   xmm2, xmm2
    movaps  xmm3, xmm1
    mulss   xmm3, xmm3
    addss   xmm2, xmm3
    sqrtss  xmm2, xmm2
    cvttss2si ebx, xmm2                 # the distance
    mov     eax, H_CENTRE
    cmp     ebx, R0
    jl      9f
    call    atan2_top
    movss   [rsp], xmm0
    cmp     ebx, R1
    jg      1f
    call    entry_arc
    mov     ecx, [rip+wh_n]
    call    sector
    jmp     9f
1:  mov     eax, H_NONE
    cmp     dword ptr [rip+wh_grp], 0
    jl      9f
    cmp     ebx, R2
    jl      9f
    cmp     ebx, R3
    jg      9f
    call    kid_arc
    movss   xmm0, [rsp]
    mov     ecx, [rip+wh_nk]
    call    sector
    test    eax, eax
    js      9f
    add     eax, KID
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# ---- input ------------------------------------------------------------------------
# wh_hover(edi = x, esi = y) - the entry under the pointer lights up; a
#   group opens its choices (and keeps them open off the ring)
wh_hover:
    push    rbx
    call    wh_hit
    mov     ebx, eax
    mov     ecx, -1                     # the lit choice
    mov     edx, [rip+wh_grp]           # the lit entry: the open group's
    cmp     ebx, KID
    jl      1f
    lea     ecx, [rbx-KID]
    jmp     5f
1:  test    ebx, ebx
    js      5f
    mov     edx, ebx                    # an entry of the ring: lit, and if
    mov     edi, ebx                    #  a group, open
    call    entry
    mov     rax, [rax]
    mov     edx, ebx
    cmp     qword ptr [rax], SUBTAG
    je      2f
    mov     dword ptr [rip+wh_grp], -1
    mov     dword ptr [rip+wh_nk], 0
    mov     ecx, -1
    jmp     5f
2:  mov     rdi, [rax+SUB_ITEMS]
    mov     [rip+wh_kids], rdi
    mov     edi, [rax+SUB_COUNT]
    mov     [rip+wh_nk], edi
    mov     [rip+wh_grp], ebx
    mov     ecx, -1
5:  cmp     edx, [rip+wh_sel]
    jne     6f
    cmp     ecx, [rip+wh_ksel]
    je      9f
6:  mov     [rip+wh_sel], edx
    mov     [rip+wh_ksel], ecx
    mov     dword ptr [rip+dirty], 1
9:  pop     rbx
    ret

# run(edi = hit) -> eax = 1 if it was an operator that can run now (closed,
#   run); a greyed one leaves the wheel open
run:
    push    rbx
    push    r12
    sub     rsp, 8
    call    entry
    test    rax, rax
    jz      8f
    mov     r12, rax
    mov     rbx, [rax]
    cmp     qword ptr [rbx], SUBTAG
    je      8f
    mov     rdi, rax
    call    why
    test    rax, rax
    jnz     8f
    mov     rax, [rip+op_arg]           # its argument, if any (then back)
    mov     [rsp], rax
    mov     rax, [r12+WE_ARG]
    test    rax, rax
    jz      1f
    mov     [rip+op_arg], rax
1:  call    wh_close
    mov     rdi, rbx
    call    run_op_ui
    mov     rax, [rsp]
    mov     [rip+op_arg], rax
    mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# wh_press(edi = button) - the left button: on an entry, it runs on release
#   there; on the centre or outside, it closes. Any other button closes it.
wh_press:
    cmp     edi, BTN_LEFT
    jne     wh_close
    sub     rsp, 8
    mov     edi, [rip+ptr_x]
    mov     esi, [rip+ptr_y]
    call    wh_hit
    add     rsp, 8
    cmp     eax, H_NONE
    je      wh_close
    cmp     eax, H_CENTRE
    je      wh_close
    mov     [rip+wh_down], eax
    ret

# wh_release(edi = button) - the left button over what it went down on runs
#   it; the right button of the opening press, dragged onto an entry, too
wh_release:
    push    rbx
    mov     ebx, edi
    mov     edi, [rip+ptr_x]
    mov     esi, [rip+ptr_y]
    call    wh_hit
    cmp     ebx, BTN_LEFT
    jne     1f
    mov     ecx, H_NONE
    xchg    ecx, [rip+wh_down]
    cmp     eax, ecx
    jne     9f
    mov     edi, eax
    call    run
    jmp     9f
1:  cmp     ebx, BTN_RIGHT
    jne     9f
    xor     ecx, ecx
    xchg    ecx, [rip+wh_fresh]
    test    ecx, ecx
    jz      9f
    mov     ecx, [rip+ptr_x]            # (far enough from the press)
    sub     ecx, [rip+wh_px]
    mov     edx, ecx
    neg     edx
    cmovl   edx, ecx
    mov     ecx, [rip+ptr_y]
    sub     ecx, [rip+wh_py]
    mov     esi, ecx
    neg     esi
    cmovl   esi, ecx
    add     edx, esi
    cmp     edx, DRAG_MIN
    jl      9f
    mov     edi, eax
    call    run
9:  pop     rbx
    ret

# ---- drawing ----------------------------------------------------------------------
# blend(eax = dst, r8d = src, edx = alpha 0..256) -> eax (clobbers ecx, r9d,
#   r10d)
.macro BLEND
    mov     ecx, eax
    and     eax, 0xff00ff
    mov     r10d, 256
    sub     r10d, edx
    imul    eax, r10d
    mov     r9d, r8d
    and     r9d, 0xff00ff
    imul    r9d, edx
    add     eax, r9d
    shr     eax, 8
    and     eax, 0xff00ff
    and     ecx, 0x00ff00
    imul    ecx, r10d
    mov     r9d, r8d
    and     r9d, 0x00ff00
    imul    r9d, edx
    add     ecx, r9d
    shr     ecx, 8
    and     ecx, 0x00ff00
    or      eax, ecx
.endm

# lg(eax = logical) -> xmm0 = physical (float)
.macro LG reg
    cvtsi2ss \reg, eax
    mulss   \reg, [rip+f_sc]
.endm

# clamp01 xmm (in place)
.macro CLAMP01 reg
    maxss   \reg, [rip+f_zero]
    minss   \reg, [rip+f_one]
.endm

.section .rodata
.align 4
f_zero:         .float 0.0
.text

# wh_draw - the wheel, when open
wh_draw:
    cmp     dword ptr [rip+wh_on], 0
    jne     1f
    ret
1:  push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 56
    call    reset_clip
    mov     r8d, COL_DROP_BG            # the theme's colours
    call    th_map
    mov     [rip+c_bg], r8d
    mov     r8d, COL_BTN_HOVER
    call    th_map
    mov     [rip+c_hov], r8d
    mov     r8d, COL_SHADOW
    call    th_map
    mov     [rip+c_sh], r8d
    mov     r8d, COL_TEXT_OFF
    call    th_map
    mov     [rip+c_off], r8d
    xor     ebx, ebx                    # each sector's edge: its colour, or
2:  cmp     ebx, [rip+wh_n]             #  grey when it cannot run
    jae     3f
    mov     edi, ebx
    call    entry
    mov     rdi, rax
    mov     r12d, [rax+20]
    call    why
    test    rax, rax
    cmovnz  r12d, [rip+c_off]
    lea     rax, [rip+c_rim]
    mov     [rax+rbx*4], r12d
    inc     ebx
    jmp     2b

3:  # the geometry, physical
    mov     rax, [rip+ui_s16q]
    cvtsi2ss xmm0, rax
    divss   xmm0, [rip+f_65536]
    movss   [rip+f_sc], xmm0
    mov     edi, [rip+wh_cx]
    call    to_px
    cvtsi2ss xmm0, eax
    movss   [rip+f_cx], xmm0
    mov     edi, [rip+wh_cy]
    call    to_px
    cvtsi2ss xmm0, eax
    movss   [rip+f_cy], xmm0
    mov     eax, R0
    LG      xmm0
    movss   [rip+f_r0], xmm0
    mov     eax, R1
    LG      xmm0
    movss   [rip+f_r1], xmm0
    mov     eax, R2
    LG      xmm0
    movss   [rip+f_r2], xmm0
    mov     eax, R3
    LG      xmm0
    movss   [rip+f_r3], xmm0
    mov     eax, SH
    LG      xmm0
    movss   [rip+f_sh], xmm0
    mov     eax, 3
    LG      xmm0
    movss   [rip+f_rim], xmm0
    mov     eax, 2
    LG      xmm0
    movss   [rip+f_gap], xmm0
    call    entry_arc
    movss   [rip+f_step], xmm2
    movss   xmm0, [rip+f_r1]            # the pixels to visit: the ring and
    addss   xmm0, [rip+f_sh]            #  its shadow (and the choices)
    cmp     dword ptr [rip+wh_grp], 0
    jl      4f
    call    kid_arc
    movss   [rip+f_k0], xmm1
    movss   [rip+f_kstep], xmm2
    cvtsi2ss xmm3, dword ptr [rip+wh_nk]
    mulss   xmm3, xmm2
    movss   [rip+f_kend], xmm3
    movss   xmm0, [rip+f_r3]
    addss   xmm0, [rip+f_one]
    movss   xmm1, [rip+f_r1]
    addss   xmm1, [rip+f_sh]
    maxss   xmm0, xmm1
4:  movss   [rip+f_rb], xmm0
    cvttss2si eax, xmm0
    inc     eax
    cvttss2si ecx, [rip+f_cx]
    cvttss2si edx, [rip+f_cy]
    mov     r12d, edx                   # rows
    sub     r12d, eax
    lea     r13d, [rdx+rax]
    mov     r14d, ecx                   # columns
    sub     r14d, eax
    lea     r15d, [rcx+rax]
    mov     eax, [rip+clip_y0]
    cmp     r12d, eax
    cmovl   r12d, eax
    mov     eax, [rip+clip_y1]
    cmp     r13d, eax
    cmovg   r13d, eax
    mov     eax, [rip+clip_x0]
    cmp     r14d, eax
    cmovl   r14d, eax
    mov     eax, [rip+clip_x1]
    cmp     r15d, eax
    cmovg   r15d, eax
    movss   xmm0, [rip+f_rb]
    mulss   xmm0, xmm0
    movss   [rsp+16], xmm0              # (the outermost, squared)

.Lwd_row:
    cmp     r12d, r13d
    jge     .Lwd_marks
    mov     eax, r12d
    imul    eax, [rip+fb_w]
    mov     rbp, [rip+fb_ptr]
    lea     rbp, [rbp+rax*4]
    cvtsi2ss xmm0, r12d
    addss   xmm0, [rip+f_half]
    subss   xmm0, [rip+f_cy]
    movss   [rsp+4], xmm0               # dy
    mov     ebx, r14d
.Lwd_px:
    cmp     ebx, r15d
    jge     .Lwd_nrow
    cvtsi2ss xmm0, ebx
    addss   xmm0, [rip+f_half]
    subss   xmm0, [rip+f_cx]
    movss   [rsp], xmm0                 # dx
    movss   xmm1, [rsp+4]
    mulss   xmm0, xmm0
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    ucomiss xmm0, [rsp+16]
    ja      .Lwd_next
    sqrtss  xmm0, xmm0
    movss   [rsp+8], xmm0               # d
    movss   xmm1, [rip+f_r0]
    subss   xmm1, [rip+f_half]
    ucomiss xmm0, xmm1
    jb      .Lwd_hole
    movss   xmm1, [rip+f_r1]
    addss   xmm1, [rip+f_half]
    ucomiss xmm0, xmm1
    ja      .Lwd_outer
    # the ring of entries
    movss   xmm0, [rsp]
    movss   xmm1, [rsp+4]
    call    atan2_top
    movss   xmm2, [rip+f_step]
    movaps  xmm1, xmm2
    mulss   xmm1, [rip+f_half]
    movss   xmm3, [rip+f_2pi]
    subss   xmm3, xmm1
    movaps  xmm1, xmm3
    mov     ecx, [rip+wh_n]
    call    sector
    test    eax, eax
    jns     5f
    xor     eax, eax                    # (the last sliver before the top)
5:  mov     [rsp+12], eax
    movss   xmm1, [rip+f_step]
    movss   xmm2, [rip+f_r0]
    movss   xmm3, [rip+f_r1]
    call    coverage                    # xmm0 = coverage
    call    under
    mov     eax, [rsp+12]
    mov     r8d, [rip+c_bg]
    cmp     eax, [rip+wh_sel]
    jne     6f
    mov     r8d, [rip+c_hov]
    movss   xmm1, [rip+f_r1]            # its outer edge in its colour
    subss   xmm1, [rip+f_rim]
    ucomiss xmm1, [rsp+8]
    ja      6f
    lea     rcx, [rip+c_rim]
    mov     r8d, [rcx+rax*4]
6:  jmp     .Lwd_put

.Lwd_outer:
    cmp     dword ptr [rip+wh_grp], 0   # the open group's choices
    jl      .Lwd_shadow
    movss   xmm1, [rip+f_r2]
    subss   xmm1, [rip+f_half]
    ucomiss xmm0, xmm1
    jb      .Lwd_shadow
    movss   xmm1, [rip+f_r3]
    addss   xmm1, [rip+f_half]
    ucomiss xmm0, xmm1
    ja      .Lwd_next
    movss   xmm0, [rsp]
    movss   xmm1, [rsp+4]
    call    atan2_top
    movss   xmm1, [rip+f_k0]
    movss   xmm2, [rip+f_kstep]
    mov     ecx, [rip+wh_nk]
    call    sector
    test    eax, eax
    js      .Lwd_shadow
    mov     [rsp+12], eax
    movss   xmm1, [rip+f_kstep]
    movss   xmm2, [rip+f_r2]
    movss   xmm3, [rip+f_r3]
    call    coverage
    call    under
    mov     eax, [rsp+12]
    mov     r8d, [rip+c_bg]
    cmp     eax, [rip+wh_ksel]
    jne     .Lwd_put
    mov     r8d, [rip+c_hov]
    movss   xmm1, [rip+f_r3]
    subss   xmm1, [rip+f_rim]
    ucomiss xmm1, [rsp+8]
    ja      .Lwd_put
    mov     eax, [rip+wh_grp]
    lea     rcx, [rip+c_rim]
    mov     r8d, [rcx+rax*4]
    jmp     .Lwd_put

.Lwd_shadow:
    movss   xmm0, [rsp+8]               # outside the ring: dark, fading out
    subss   xmm0, [rip+f_r1]
    divss   xmm0, [rip+f_sh]
    movss   xmm1, [rip+f_one]
    subss   xmm1, xmm0
    CLAMP01 xmm1
    mulss   xmm1, xmm1
    mulss   xmm1, [rip+f_shade]
    movaps  xmm0, xmm1
    mov     r8d, [rip+c_sh]
    jmp     .Lwd_put

.Lwd_hole:
    movss   xmm1, [rip+f_r0]            # the hole: a disc, a little smaller
    subss   xmm1, [rip+f_rim]
    subss   xmm1, [rip+f_rim]
    subss   xmm1, xmm0
    addss   xmm1, [rip+f_half]
    CLAMP01 xmm1
    movaps  xmm0, xmm1
    mov     r8d, [rip+c_bg]

.Lwd_put:                               # xmm0 = coverage, r8d = colour
    mulss   xmm0, [rip+f_256]
    cvttss2si edx, xmm0
    test    edx, edx
    jle     .Lwd_next
    cmp     edx, 256
    jbe     7f
    mov     edx, 256
7:  mov     eax, [rbp+rbx*4]
    BLEND
    mov     [rbp+rbx*4], eax
.Lwd_next:
    inc     ebx
    jmp     .Lwd_px
.Lwd_nrow:
    inc     r12d
    jmp     .Lwd_row

.Lwd_marks:
    # the entries: a coloured disc with its icon, the label under it
    xor     ebx, ebx
.Lwd_ent:
    cmp     ebx, [rip+wh_n]
    jae     .Lwd_kids
    mov     edi, ebx
    call    entry
    mov     r12, rax
    mov     edi, ebx
    mov     esi, R_MID
    call    at_entry
    mov     [rsp+24], eax
    mov     [rsp+28], edx
    sub     dword ptr [rsp+28], 9       # (the icon, its label under it)
    add     edx, 15
    mov     [rsp+36], edx
    lea     rax, [rip+c_rim]
    mov     r8d, [rax+rbx*4]
    mov     edx, 15
    cmp     ebx, [rip+wh_sel]
    jne     1f
    mov     edx, 17
1:  mov     edi, [rsp+24]
    mov     esi, [rsp+28]
    call    fill_circle
    mov     edi, [rsp+24]
    sub     edi, 8
    mov     esi, [rsp+28]
    sub     esi, 8
    mov     edx, [r12+16]
    mov     r8d, ICON_INK
    call    draw_icon
    cmp     dword ptr [rip+wh_grp], 0   # its key (the choices' while a group
    jge     11f                         #  is open)
    mov     edi, ebx
    mov     esi, [rsp+24]
    mov     edx, [rsp+28]
    call    key_badge
11: cmp     ebx, [rip+wh_grp]           # a group: two dots at its outer edge
    je      2f                          #  (when closed)
    mov     rax, [r12]
    cmp     qword ptr [rax], SUBTAG
    jne     2f
    mov     edi, ebx
    mov     esi, R1-9
    call    at_entry
    mov     edi, eax
    mov     esi, edx
    mov     edx, 2
    mov     r8d, COL_TEXT_DIM
    call    fill_circle
2:  mov     edi, ebx                    # the room: up to its neighbours'
    call    ring_room                   #  labels on the same row
    mov     [rsp+32], eax
    mov     rdi, r12
    call    why
    mov     r13d, COL_TEXT
    test    rax, rax
    jz      3f
    mov     r13d, COL_TEXT_OFF
3:  mov     rdi, r12
    call    short_label
    mov     rdi, rax
    mov     esi, [rsp+24]
    mov     edx, [rsp+36]
    mov     ecx, r13d
    mov     r8d, [rsp+32]
    call    label_at
    inc     ebx
    jmp     .Lwd_ent

.Lwd_kids:
    cmp     dword ptr [rip+wh_grp], 0
    jl      .Lwd_centre
    xor     ebx, ebx
.Lwd_kid:
    cmp     ebx, [rip+wh_nk]
    jae     .Lwd_centre
    lea     edi, [rbx+KID]
    call    entry
    mov     r12, rax
    mov     edi, ebx
    mov     esi, R_KMID
    call    at_kid
    mov     [rsp+24], eax
    mov     [rsp+28], edx
    sub     dword ptr [rsp+28], 8
    add     edx, 13
    mov     [rsp+36], edx
    mov     rdi, r12
    call    why
    mov     [rsp+40], rax
    mov     eax, [rip+wh_grp]
    lea     rcx, [rip+c_rim]
    mov     r8d, [rcx+rax*4]
    mov     r13d, COL_TEXT
    cmp     qword ptr [rsp+40], 0
    je      1f
    mov     r8d, [rip+c_off]
    mov     r13d, COL_TEXT_OFF
1:  mov     edx, 12
    cmp     ebx, [rip+wh_ksel]
    jne     2f
    mov     edx, 14
2:  mov     edi, [rsp+24]
    mov     esi, [rsp+28]
    call    fill_circle
    mov     edi, [rsp+24]
    sub     edi, 8
    mov     esi, [rsp+28]
    sub     esi, 8
    mov     edx, [r12+16]
    mov     r8d, ICON_INK
    call    draw_icon
    mov     edi, ebx                    # its key
    mov     esi, [rsp+24]
    mov     edx, [rsp+28]
    call    key_badge
    movss   xmm0, [rip+f_kdeg]
    mov     esi, R_KMID+14
    mov     edx, KROOM
    call    label_room
    mov     [rsp+32], eax
    mov     rdi, r12
    call    short_label
    mov     rdi, rax
    mov     r8d, [rsp+32]
    mov     esi, [rsp+24]
    mov     edx, [rsp+36]
    mov     ecx, r13d
    call    label_at
    inc     ebx
    jmp     .Lwd_kid

.Lwd_centre:
    mov     edi, [rip+wh_cx]            # the centre: close
    sub     edi, 8
    mov     esi, [rip+wh_cy]
    sub     esi, 8
    mov     edx, ICON_CLOSE
    mov     r8d, COL_TEXT_DIM
    call    draw_icon
    call    info
    add     rsp, 56
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

# coverage(xmm1 = the sector's angle, xmm2 = inner, xmm3 = outer radius;
#   [rsp+8+8] = d, xmm0 = how far into the sector) -> xmm0: the pixel's
#   share inside the ring and away from the gaps, xmm6: inside the ring
coverage:
    movss   xmm4, [rip+f_one]           # the nearer side, as arc length
    subss   xmm4, xmm0
    minss   xmm0, xmm4
    mulss   xmm0, xmm1
    movss   xmm5, [rsp+16]              # (the caller's d)
    mulss   xmm0, xmm5
    subss   xmm0, [rip+f_gap]
    addss   xmm0, [rip+f_half]
    movaps  xmm6, xmm5                  # from the inner edge
    subss   xmm6, xmm2
    addss   xmm6, [rip+f_half]
    movaps  xmm4, xmm3                  # to the outer edge
    subss   xmm4, xmm5
    addss   xmm4, [rip+f_half]
    minss   xmm6, xmm4
    CLAMP01 xmm6
    minss   xmm0, xmm6
    CLAMP01 xmm0
    ret

# under(xmm6 = inside the ring) - the gaps between sectors: darker
#   (keeps r8d, xmm0; rbp + rbx*4 is the pixel)
under:
    movaps  xmm7, xmm6
    mulss   xmm7, [rip+f_gapdark]
    mulss   xmm7, [rip+f_256]
    cvttss2si edx, xmm7
    test    edx, edx
    jle     9f
    mov     r11d, r8d
    mov     r8d, [rip+c_sh]
    mov     eax, [rbp+rbx*4]
    BLEND
    mov     [rbp+rbx*4], eax
    mov     r8d, r11d
9:  ret

# key_badge(edi = entry or choice, esi = x, edx = y: its icon's centre) -
#   the key that picks it, in a small disc on the icon's upper right edge
#   (#440)
key_badge:
    cmp     edi, NKEYS
    jae     9f
    push    rbx
    push    r12
    push    r13
    lea     rax, [rip+key_chars]
    movzx   eax, byte ptr [rax+rdi]
    mov     [rip+badge_buf], al
    mov     byte ptr [rip+badge_buf+1], 0
    lea     ebx, [rsi+11]               # the disc's centre
    lea     r12d, [rdx-11]
    mov     edi, ebx
    mov     esi, r12d
    mov     edx, 8
    mov     r8d, [rip+c_bg]
    call    fill_circle
    lea     rdi, [rip+badge_buf]
    call    text_width_small
    shr     eax, 1
    mov     edi, ebx
    sub     edi, eax
    lea     esi, [r12-8]
    lea     rdx, [rip+badge_buf]
    mov     ecx, COL_TEXT
    call    draw_small
    pop     r13
    pop     r12
    pop     rbx
9:  ret

# wh_key(edi = evdev) -> eax = 1 when the wheel took it (#440): 1-9, 0 and -
#   (or the keypad's) pick that entry - a group opens its choices, which the
#   same keys then pick; Backspace closes the group again. A choice or entry
#   that cannot run leaves the wheel open (lit, its reason above it)
wh_key:
    push    rbx
    cmp     edi, 14                     # Backspace
    jne     1f
    cmp     dword ptr [rip+wh_grp], 0
    jl      7f
    mov     dword ptr [rip+wh_grp], -1
    mov     dword ptr [rip+wh_nk], 0
    mov     dword ptr [rip+wh_ksel], -1
    jmp     6f
1:  lea     rax, [rip+key_map]
2:  movzx   ecx, byte ptr [rax]
    test    ecx, ecx
    jz      8f                          # (not a key of ours)
    cmp     ecx, edi
    je      3f
    add     rax, 2
    jmp     2b
3:  movzx   ebx, byte ptr [rax+1]
    cmp     dword ptr [rip+wh_grp], 0   # a group open: its choices
    jl      4f
    cmp     ebx, [rip+wh_nk]
    jae     7f
    mov     [rip+wh_ksel], ebx
    lea     edi, [rbx+KID]
    call    run
    jmp     6f
4:  cmp     ebx, [rip+wh_n]
    jae     7f
    mov     [rip+wh_sel], ebx
    mov     edi, ebx
    call    entry
    mov     rax, [rax]
    cmp     qword ptr [rax], SUBTAG
    je      5f
    mov     edi, ebx
    call    run
    jmp     6f
5:  mov     rdi, [rax+SUB_ITEMS]        # a group: its choices open
    mov     [rip+wh_kids], rdi
    mov     edi, [rax+SUB_COUNT]
    mov     [rip+wh_nk], edi
    mov     [rip+wh_grp], ebx
    mov     dword ptr [rip+wh_ksel], -1
6:  mov     dword ptr [rip+dirty], 1
7:  mov     eax, 1
    pop     rbx
    ret
8:  xor     eax, eax
    pop     rbx
    ret

# ring_room(edi = entry) -> eax = the width its label has: ROOM, less where
#   a neighbour's label is on the same row and the two texts do not both fit
#   in the distance across between them - then they share it in proportion
#   to their widths (so they never meet). At the sides the neighbours are
#   above and below: the whole ROOM
ring_room:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 24
    mov     ebx, edi
    call    text_w                      # its own text
    mov     [rsp], eax
    mov     edi, ebx
    mov     esi, R_MID
    call    at_entry
    mov     r12d, eax
    mov     r13d, edx
    mov     r14d, ROOM
    mov     r15d, -1
1:  lea     edi, [rbx+r15]              # (-1 and n: the angle goes round)
    mov     esi, R_MID
    call    at_entry
    sub     eax, r12d
    mov     ecx, eax
    sar     ecx, 31
    xor     eax, ecx
    sub     eax, ecx                    # |dx|
    sub     edx, r13d
    mov     ecx, edx
    sar     ecx, 31
    xor     edx, ecx
    sub     edx, ecx                    # |dy|
    cmp     edx, CHAR_H+4
    jge     2f
    lea     ebp, [rax+rax-8]            # what both have: 2 dx, less a margin
    lea     edi, [rbx+r15]
    call    text_w                      # the neighbour's text
    mov     ecx, [rsp]
    add     eax, ecx                    # both
    cmp     eax, ebp
    jle     2f                          # (they fit)
    mov     r8d, eax
    mov     eax, ebp                    # its share: room * its / both
    imul    eax, ecx
    cdq
    idiv    r8d
    cmp     eax, r14d
    cmovl   r14d, eax
2:  add     r15d, 2
    cmp     r15d, 1
    jle     1b
    mov     eax, r14d
    add     rsp, 24
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

# text_w(edi = entry, any: it goes round) -> eax = its label's text width,
#   ROOM at most
text_w:
    sub     rsp, 8
    test    edi, edi
    jns     1f
    add     edi, [rip+wh_n]
1:  cmp     edi, [rip+wh_n]
    jb      2f
    sub     edi, [rip+wh_n]
2:  call    entry
    test    rax, rax
    jz      8f
    mov     rdi, rax
    call    short_label
    mov     rdi, rax
    call    text_width_small            # (as label_at draws it)
    cmp     eax, ROOM
    jle     9f
8:  mov     eax, ROOM
9:  add     rsp, 8
    ret

# label_room(esi = radius, xmm0 = the sector's angle, edx = at most) ->
#   eax = the width a label has there: the chord, less a margin
label_room:
    mulss   xmm0, [rip+f_half]
    movss   [rip+t_ang], xmm0
    cvtsi2ss xmm1, esi
    movss   [rip+t_rad], xmm1
    fld     dword ptr [rip+t_ang]
    fsin
    fmul    dword ptr [rip+t_rad]
    fadd    st(0), st(0)
    fistp   dword ptr [rip+t_x]
    mov     eax, [rip+t_x]
    sub     eax, 6
    cmp     eax, edx
    cmovg   eax, edx
    ret

# label_at(rdi = text, esi = x, edx = y (its middle), ecx = colour, r8d =
#   room) - centred there, cut to the room
label_at:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    qword ptr [rip+cur_font]    # (the small font)
    mov     dword ptr [rip+cur_font], FONT_SMALL
    sub     rsp, 8
    mov     rbx, rdi
    mov     r12d, esi
    mov     r13d, edx
    mov     r14d, ecx
    mov     r15d, r8d
    call    text_width
    cmp     eax, r15d
    cmovg   eax, r15d
    shr     eax, 1
    mov     edi, r12d
    sub     edi, eax
    mov     esi, r13d
    sub     esi, CHAR_H/2
    mov     rdx, rbx
    mov     ecx, r14d
    mov     r8d, r15d
    call    draw_text_fit
    add     rsp, 8
    pop     rax
    mov     [rip+cur_font], eax
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# info - above the wheel: the lit entry's whole label, and why it cannot
#   run now when it cannot
info:
    push    rbx
    push    r12
    push    r13
    mov     edi, [rip+wh_ksel]
    add     edi, KID
    cmp     dword ptr [rip+wh_ksel], 0
    jge     1f
    mov     edi, [rip+wh_sel]
1:  call    entry
    test    rax, rax
    jz      9f
    mov     r12, rax
    mov     rdi, rax                    # the label (and ": why")
    call    full_label
    lea     rdi, [rip+info_buf]
    mov     rsi, rax
    mov     ecx, 120
    call    cpy
    mov     rbx, rdi
    mov     rdi, r12
    call    why
    test    rax, rax
    jz      2f
    mov     r13, rax
    mov     rdi, rbx
    lea     rsi, [rip+s_sep]
    mov     ecx, 4
    call    cpy
    mov     rsi, r13
    mov     ecx, 120
    call    cpy
2:  lea     rdi, [rip+info_buf]
    call    text_width
    add     eax, 20
    mov     ebx, eax                    # the pill's width
    mov     edi, [rip+wh_cx]
    mov     ecx, ebx
    shr     ecx, 1
    sub     edi, ecx
    mov     esi, [rip+wh_cy]
    sub     esi, R3+INFO_H+4
    mov     edx, ebx
    mov     ecx, INFO_H
    mov     r8d, COL_DROP_BORDER
    mov     r13d, edi
    call    popup_frame
    lea     edi, [r13+10]
    mov     esi, [rip+wh_cy]
    sub     esi, R3+INFO_H+4-(INFO_H-CHAR_H)/2
    lea     rdx, [rip+info_buf]
    mov     ecx, COL_TEXT
    call    draw_text
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# cpy(rdi = to, rsi = from, ecx = at most) -> rdi = its end (0 there)
cpy:
1:  test    ecx, ecx
    jz      2f
    mov     al, [rsi]
    test    al, al
    jz      2f
    mov     [rdi], al
    inc     rdi
    inc     rsi
    dec     ecx
    jmp     1b
2:  mov     byte ptr [rdi], 0
    ret

# ---- ui_tree ----------------------------------------------------------------------
# wh_json(edi = entries before) -> eax = entries written: the entries (level
#   0) and the open group's choices (level 1)
wh_json:
    xor     eax, eax
    cmp     dword ptr [rip+wh_on], 0
    jne     1f
    ret
1:  push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r15d, edi
    xor     r14d, r14d
    xor     ebx, ebx
2:  cmp     ebx, [rip+wh_n]
    jae     3f
    mov     edi, ebx
    mov     esi, ebx
    xor     edx, edx
    call    jentry
    inc     ebx
    jmp     2b
3:  cmp     dword ptr [rip+wh_grp], 0
    jl      8f
    xor     ebx, ebx
4:  cmp     ebx, [rip+wh_nk]
    jae     8f
    lea     edi, [rbx+KID]
    mov     esi, ebx
    mov     edx, 1
    call    jentry
    inc     ebx
    jmp     4b
8:  mov     eax, r14d
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# jentry(edi = hit, esi = its index, edx = level) - one (r14d counts)
jentry:
    push    rbx
    push    r12
    push    r13
    push    rbp
    sub     rsp, 8
    mov     r13d, edi
    mov     r12d, esi
    mov     ebp, edx
    call    entry
    mov     rbx, rax
    lea     eax, [r14+r15]
    inc     r14d
    test    eax, eax
    jz      1f
    mov     edi, ','
    call    wb_char
1:  lea     rsi, [rip+j_a]
    call    wb_str
    mov     rax, [rbx]
    cmp     qword ptr [rax], SUBTAG
    jne     2f
    lea     rsi, [rip+j_sub]
    call    wb_str
    jmp     3f
2:  mov     rsi, [rax+OP_NAME]
    call    jb_q
3:  lea     rsi, [rip+j_b]
    call    wb_str
    movsxd  rdi, r12d
    call    wb_int
    lea     rsi, [rip+j_c]
    call    wb_str
    movsxd  rdi, ebp
    call    wb_int
    mov     edi, r12d                   # an 80 x 24 box on its middle
    test    ebp, ebp
    jnz     4f
    mov     esi, R_HIT
    call    at_entry
    jmp     5f
4:  mov     esi, R_KHIT
    call    at_kid
5:  sub     eax, 40
    sub     edx, 12
    mov     [rsp], edx
    mov     [rsp+4], eax
    lea     rsi, [rip+j_x]
    call    wb_str
    movsxd  rdi, dword ptr [rsp+4]
    call    wb_int
    lea     rsi, [rip+j_y]
    call    wb_str
    movsxd  rdi, dword ptr [rsp]
    call    wb_int
    lea     rsi, [rip+j_wh]
    call    wb_str
    mov     rdi, rbx
    call    full_label
    mov     rsi, rax
    call    jb_q
    mov     rax, [rbx]
    cmp     qword ptr [rax], SUBTAG
    je      7f
    lea     rsi, [rip+j_why]
    call    wb_str
    mov     rdi, rbx
    call    why
    mov     rsi, rax
    test    rsi, rsi
    jz      6f
    call    jb_q
    jmp     7f
6:  lea     rsi, [rip+j_null]
    call    wb_str
7:  cmp     r12d, NKEYS                 # ,"key":"1" (#440)
    jae     71f
    lea     rsi, [rip+j_key]
    call    wb_str
    lea     rax, [rip+key_chars]
    movzx   edi, byte ptr [rax+r12]
    call    wb_char
    lea     rsi, [rip+j_q]
    call    wb_str
71: lea     rsi, [rip+j_end]
    call    wb_str
    add     rsp, 8
    pop     rbp
    pop     r13
    pop     r12
    pop     rbx
    ret

.section .note.GNU-stack,"",@progbits
