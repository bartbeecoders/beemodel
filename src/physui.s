# =============================================================================
#  BeeModel - the Physics section of the Properties area (W4: widgets).
#
#  For the active mesh object, under a status line ("Active Convex Hull,
#  4.2 kg, 2 joints"; "Piece of Wall"; "Not a rigid body"), sections that
#  fold:
#    - Rigid Body: not a body yet, its type and shape, then Add Rigid Body
#      (rigid.add on the selection). A body: type, shape, the object or its
#      instances, a material preset, mass, friction, bounce, damping, its
#      start velocity and collision group, Remove. A change goes to every
#      selected body (one undo step).
#    - Joints: the object's joints as a list; the one picked has its type,
#      the other object (or the world), pivot, axis, limits, motor and the
#      force that breaks it. Add Joint... (the form), Remove.
#    - Shatter (closed at first): pattern, preset, count, seed, glue (and
#      painting the glued faces), the blow it breaks at, the bricks' gap,
#      the cut faces' colour; Shatter, or Re-cut on a piece.
#    - World (closed at first): gravity as a vector, steps a second,
#      iterations, substeps.
#  Values come from the animation block each frame (an_cur) into the
#  fields' own copies; the callbacks write them into an owned block
#  (an_own_g) after the widget's undo step.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"
.include "widgets.inc"

.globl rb_props_draw
.globl rb_get
.globl sp_sync

.equ RB_UID,    0
.equ RB_TYPE,   4
.equ RB_SHAPE,  8
.equ RB_MASS,   12
.equ RB_FLAGS,  28
.equ RB_INIT_,  32                      # (where it starts: loc rot scale)
.equ RB_VEL,    68
.equ RW_GRAV,   0
.equ RW_RATE,   12
.equ RW_ITER,   16
.equ RW_SET,    20
.equ RW_SUB,    24
.equ JT_TYPE,   0
.equ JT_A,      4
.equ JT_B,      8
.equ JT_PIV,    16
.equ JT_AXIS,   28
.equ JT_BRK,    40
.equ JT_LO,     44
.equ JT_HI,     48
.equ JT_MSPD,   52
.equ JT_MFOR,   56
.equ JT_FLG,    60
.equ SO_PS_SZ,  44                      # (shatterop.s so_pdata rows)
.equ MAXJROW,   8                       # joints listed (glued pieces have many)
.equ MAXOLBL,   1024                    # the other-object list

.section .rodata
s_undo:         .asciz "Physics"
s_st_none:      .asciz "Not a rigid body"
s_st_piece:     .asciz "Piece of "
s_st_sep:       .asciz ", "
s_st_kg:        .asciz " kg"
s_st_joint:     .asciz " joint"
s_st_joints:    .asciz " joints"
s_st_inst:      .asciz "each instance a body"
s_st_run:       .asciz "Running: "
s_bodies:       .asciz " bodies, "
s_awake:        .asciz " awake, "
s_ms:           .asciz " ms"
s_more:         .asciz " more joints (glue)"
s_to:           .asciz " to "
s_world:        .asciz "world"
s_h_body:       .asciz "Rigid Body"
s_h_joint:      .asciz "Joints"
s_h_shat:       .asciz "Shatter"
s_h_world:      .asciz "World"
s_c_type:       .asciz "Type"
s_c_shape:      .asciz "Shape"
s_c_bodies:     .asciz "Bodies"
s_c_mat:        .asciz "Material"
s_c_vel:        .asciz "Velocity (m/s)"
s_c_grav:       .asciz "Gravity"
s_c_other:      .asciz "Tied to"
s_c_pivot:      .asciz "Pivot"
s_c_axis:       .asciz "Axis"
s_c_pattern:    .asciz "Pattern"
s_c_preset:     .asciz "Preset"
s_c_inner:      .asciz "Cut faces"
s_no_joint:     .asciz "No joints. Select two objects (or one, tied to the world) and Add Joint."
s_active:       .asciz "Active"
s_passive:      .asciz "Passive"
s_b_object:     .asciz "The object"
s_b_inst:       .asciz "Its instances"
sh_box:         .asciz "Box"
sh_sphere:      .asciz "Sphere"
sh_capsule:     .asciz "Capsule"
sh_hull:        .asciz "Convex Hull"
sh_compound:    .asciz "Compound"
sh_mesh:        .asciz "Mesh"
sh_plane:       .asciz "Plane"
k_box:          .asciz "box"
k_sphere:       .asciz "sphere"
k_capsule:      .asciz "capsule"
k_hull:         .asciz "hull"
k_compound:     .asciz "compound"
k_mesh:         .asciz "mesh"
k_plane:        .asciz "plane"
k_active:       .asciz "active "
k_passive:      .asciz "passive "
pm_l0:          .asciz "Default"
pm_l1:          .asciz "Rubber"
pm_l2:          .asciz "Ice"
pm_l3:          .asciz "Wood"
pm_l4:          .asciz "Metal"
pm_l5:          .asciz "Stone"
pm_custom:      .asciz "Custom"
jt_fixed:       .asciz "Fixed"
jt_hinge:       .asciz "Hinge"
jt_point:       .asciz "Point"
jt_slider:      .asciz "Slider"
s_shards:       .asciz "Shards"
s_bricks:       .asciz "Bricks"
s_balls:        .asciz "Balls"
s_pre0:         .asciz "No preset"
s_pre1:         .asciz "Brick wall"
s_pre2:         .asciz "Glass"
s_pre3:         .asciz "Stone"
s_pre4:         .asciz "Gravel balls"
k_shards:       .asciz "shards "
k_bricks:       .asciz "bricks "
k_balls:        .asciz "balls "
k_none:         .asciz ""
k_pre1:         .asciz "preset brickwall "
k_pre2:         .asciz "preset glass "
k_pre3:         .asciz "preset stone "
k_pre4:         .asciz "preset gravel "
k_again:        .asciz "again "
k_count:        .asciz "count "
k_seed:         .asciz " seed "
k_glue:         .asciz " glue "
k_paint:        .asciz " paint"
k_impact:       .asciz " impact "
k_gap:          .asciz " gap "
k_inner:        .asciz " inner "
k_sp:           .asciz " "
s_sh_op:        .asciz "object.shatter"
s_rb_add:       .asciz "rigid.add"
.align 8
l_type:         .quad s_active, s_passive
l_shape:        .quad sh_box, sh_sphere, sh_capsule, sh_hull, sh_compound, sh_mesh, sh_plane
kw_shape:       .quad k_box, k_sphere, k_capsule, k_hull, k_compound, k_mesh, k_plane
l_bodies:       .quad s_b_object, s_b_inst
l_mat:          .quad pm_l0, pm_l1, pm_l2, pm_l3, pm_l4, pm_l5, pm_custom
l_jtype:        .quad jt_fixed, jt_hinge, jt_point, jt_slider
sp_pat_lbl:     .quad s_shards, s_bricks, s_balls
sp_pat_kw:      .quad k_shards, k_bricks, k_balls
sp_pre_lbl:     .quad s_pre0, s_pre1, s_pre2, s_pre3, s_pre4
sp_pre_kw:      .quad k_none, k_pre1, k_pre2, k_pre3, k_pre4
.align 4
pm_fb:          .float 0.5, 0.0,  0.9, 0.8,  0.02, 0.05,  0.5, 0.3,  0.35, 0.15,  0.7, 0.1
pf_g:           .float -9.81
pf_255:         .float 255.0

.data
.align 4
sp_val:         .float 50.0, 0.0, 0.0   # the panel's shatter settings: count,
sp_pat:         .long 0                 #  glue, impact; the pattern, preset
sp_pre:         .long 0
sp_seed:        .long 1
sp_gap:         .float 0.0
sp_inner_on:    .long 0
sp_paint:       .long 0
sp_inner:       .float 0.36, 0.34, 0.31 # (linear: about #99958e)
rp_nshape:      .long 3                 # a new body: active, a convex hull
rp_ntype:       .long 0

.section .bss
.align 8
rp_olbl:        .skip 8*MAXOLBL         # the other-object list's labels
sp_recut:       .skip 4
rp_type:        .skip 4                 # the active body's values, as shown
rp_shape:       .skip 4
rp_inst:        .skip 4
rp_mat:         .skip 4
rp_vals:        .skip 16                # mass friction bounce damping
rp_vel:         .skip 12
rp_grp:         .skip 4
rp_grav:        .skip 12                # the world's
rp_gon:         .skip 4                 #  gravity on (not all 0)
rp_rate:        .skip 4
rp_iter:        .skip 4
rp_sub:         .skip 4
rp_jsel:        .skip 4                 # the joint picked (in the list)
rp_jidx:        .skip 4                 #  its index in the block
rp_jside:       .skip 4                 #  1: this object is its B
rp_juid:        .skip 4                 #  this object's uid
rp_jtype:       .skip 4                 # its values, as shown
rp_jother:      .skip 4
rp_jpiv:        .skip 12
rp_jaxis:       .skip 12
rp_jlim:        .skip 4
rp_jlo:         .skip 4
rp_jhi:         .skip 4
rp_jmot:        .skip 4
rp_jspd:        .skip 4
rp_jfor:        .skip 4
rp_jbrk:        .skip 4
rp_argbuf:      .skip 160

.text
WIDGET wd_ph_sbody,  WK_SECTION, "physics.section.body", "Rigid Body"
WIDGET wd_ph_sjoint, WK_SECTION, "physics.section.joints", "Joints"
WIDGET wd_ph_sshat,  WK_SECTION, "physics.section.shatter", "Shatter", flags=WGF_SHUT
WIDGET wd_ph_sworld, WK_SECTION, "physics.section.world", "World", flags=WGF_SHUT
WIDGET wd_rb_ntype,  WK_ENUM, "rigid.new_type", aux=l_type, n=2, tip="Active bodies fall and collide, passive ones stay put and are collided with"
WIDGET wd_rb_nshape, WK_ENUM, "rigid.new_shape", aux=l_shape, n=7, tip="The shape it collides as (Mesh and Plane: passive only)"
WIDGET wd_rb_add,    WK_BUTTON, "rigid.add", "Add Rigid Body", flags=WGF_PRIMARY, tip="Make the selected objects rigid bodies of this type and shape"
WIDGET wd_rb_type,   WK_ENUM, "rigid.type", cb=type_cb, undo="Physics", aux=l_type, n=2, tip="Active bodies fall and collide, passive ones stay put and are collided with"
WIDGET wd_rb_shape,  WK_ENUM, "rigid.shape", cb=shape_cb, undo="Physics", aux=l_shape, n=7, tip="The shape it collides as: a box, sphere or capsule is fastest, a hull fits a convex mesh, compound a concave one"
WIDGET wd_rb_inst,   WK_ENUM, "rigid.bodies", cb=inst_cb, undo="Physics", aux=l_bodies, n=2, tip="Geometry nodes instances: the object as one body, or each instance a body"
WIDGET wd_rb_mat,    WK_ENUM, "rigid.material", cb=mat_cb, undo="Physics", aux=l_mat, n=7, tip="Friction and bounce of a material (Custom: your own values)"
WIDGET wd_rb_mass,   WK_FLOAT, "rigid.mass", "Mass (kg)", 0.001, 1000000000.0, 0.05, 3, WGF_CLAMP, cb=val_cb, undo="Physics", def=1.0
WIDGET wd_rb_fric,   WK_FLOAT, "rigid.friction", "Friction", 0.0, 2.0, 0.005, 3, WGF_CLAMP, cb=val_cb, undo="Physics", def=0.5, tip="How much it grips (0 ice, 1 rubber)"
WIDGET wd_rb_bounce, WK_FLOAT, "rigid.bounce", "Bounce", 0.0, 1.0, 0.005, 3, WGF_CLAMP, cb=val_cb, undo="Physics", def=0.0, tip="How much speed it keeps from a hit (0 none, 1 all)"
WIDGET wd_rb_damp,   WK_FLOAT, "rigid.damping", "Damping", 0.0, 10.0, 0.005, 3, WGF_CLAMP, cb=val_cb, undo="Physics", def=0.0, tip="Air drag: speed lost a second"
WIDGET wd_rb_vel,    WK_FLOAT, "rigid.velocity", step=0.05, dec=2, cb=vel_cb, undo="Physics", def=0.0, tip="Its velocity when the run begins (m/s, X Y Z)"
WIDGET wd_rb_grp,    WK_INT, "rigid.group", "Collision group", 0.0, 15.0, 0.1, 0, WGF_CLAMP, cb=grp_cb, undo="Physics", def=0.0, tip="Its group, 0 to 15 (rigid.add collide picks the groups it meets)"
WIDGET wd_rb_rem,    WK_BUTTON, "rigid.remove", "Remove Rigid Body", aux=op_rb_rem
WIDGET wd_jt_row,    WK_ROW, "rigid.joint_row", tip="A joint of this object: click to edit it"
WIDGET wd_jt_type,   WK_ENUM, "rigid.joint_type", cb=jtype_cb, undo="Physics", aux=l_jtype, n=4, tip="Fixed: held together. Hinge: turns about an axis. Point: a ball joint. Slider: moves along an axis"
WIDGET wd_jt_other,  WK_ENUM, "rigid.joint_other", cb=jother_cb, undo="Physics", aux=jt_others, flags=WGF_DYN, tip="The other body, or the world"
WIDGET wd_jt_piv,    WK_FLOAT, "rigid.joint_pivot", step=0.01, dec=3, cb=jpiv_cb, undo="Physics", tip="Where it is (world, at the start)"
WIDGET wd_jt_axis,   WK_FLOAT, "rigid.joint_axis", step=0.01, dec=3, cb=jaxis_cb, undo="Physics", tip="The axis it turns about or slides along (world)"
WIDGET wd_jt_lim,    WK_TOGGLE, "rigid.joint_limited", "Limits", cb=jflag_cb, undo="Physics", tip="Stop it between two values"
WIDGET wd_jt_loa,    WK_FLOAT, "rigid.joint_lo", "From", step=0.01, dec=1, flags=WGF_DEG, cb=jlo_cb, undo="Physics", tip="The lowest angle (degrees)"
WIDGET wd_jt_hia,    WK_FLOAT, "rigid.joint_hi", "To", step=0.01, dec=1, flags=WGF_DEG, cb=jhi_cb, undo="Physics", tip="The highest angle (degrees)"
WIDGET wd_jt_lom,    WK_FLOAT, "rigid.joint_lo", "From (m)", step=0.01, dec=3, cb=jlo_cb, undo="Physics", tip="The lowest place along the axis"
WIDGET wd_jt_him,    WK_FLOAT, "rigid.joint_hi", "To (m)", step=0.01, dec=3, cb=jhi_cb, undo="Physics", tip="The highest place along the axis"
WIDGET wd_jt_mot,    WK_TOGGLE, "rigid.joint_motor", "Motor", cb=jflag_cb, undo="Physics", tip="Drive it at a speed"
WIDGET wd_jt_spda,   WK_FLOAT, "rigid.joint_speed", "Speed (deg/s)", step=0.01, dec=1, flags=WGF_DEG, cb=jspd_cb, undo="Physics"
WIDGET wd_jt_spdm,   WK_FLOAT, "rigid.joint_speed", "Speed (m/s)", step=0.01, dec=3, cb=jspd_cb, undo="Physics"
WIDGET wd_jt_for,    WK_FLOAT, "rigid.joint_force", "Force at most", 0.0, 1000000000.0, 1.0, 1, WGF_CLAMP, cb=jfor_cb, undo="Physics", tip="The torque (N m) or force (N) the motor gives at most"
WIDGET wd_jt_brk,    WK_FLOAT, "rigid.joint_break", "Breaks at (N, 0 never)", 0.0, 1000000000.0, 10.0, 0, WGF_CLAMP, cb=jbrk_cb, undo="Physics", def=0.0
WIDGET wd_jt_add,    WK_BUTTON, "rigid.add_joint", "Add Joint...", aux=op_rb_joint
WIDGET wd_jt_rem,    WK_BUTTON, "rigid.joint_remove", "Remove Joint", tip="Remove the joint picked above"
WIDGET wd_sh_pat,    WK_ENUM, "shatter.pattern", cb=pat_cb, aux=sp_pat_lbl, n=3, tip="Shards (Voronoi cells), bricks (a running bond) or balls"
WIDGET wd_sh_pre,    WK_ENUM, "shatter.preset", cb=pre_cb, aux=sp_pre_lbl, n=5, tip="A pattern and values to start from"
WIDGET wd_sh_cnt,    WK_INT, "shatter.count", "Count", 1.0, 4096.0, 0.25, 0, WGF_CLAMP, cb=cnt_cb, tip="Shards: cells. Bricks: a row (in half as many rows). Balls: about how many"
WIDGET wd_sh_seed,   WK_INT, "shatter.seed", "Seed", 0.0, 100000.0, 0.1, 0, WGF_CLAMP, tip="Another seed: other cells"
WIDGET wd_sh_glue,   WK_FLOAT, "shatter.glue", "Glue (N/m2)", 0.0, 100000000.0, 200.0, 0, WGF_CLAMP, tip="Joints between touching pieces, this strong per square metre of shared face (0: none). A blow breaks those near it"
WIDGET wd_sh_paint,  WK_TOGGLE, "shatter.paint", "Show glued faces", tip="Colour the faces the glue holds"
WIDGET wd_sh_imp,    WK_FLOAT, "shatter.impact", "Breaks at (N s, 0 now)", 0.0, 1000000.0, 0.5, 1, WGF_CLAMP, tip="Whole until a blow of this size, then it breaks while the simulation runs"
WIDGET wd_sh_gap,    WK_FLOAT, "shatter.gap", "Gap (m)", 0.0, 1.0, 0.001, 3, WGF_CLAMP, tip="Bricks: a mortar gap taken off every face"
WIDGET wd_sh_inon,   WK_TOGGLE, "shatter.inner_on", "Colour the cut faces", tip="The faces the cut makes get a colour of their own"
WIDGET wd_sh_inner,  WK_COLOR, "shatter.inner", tip="The cut faces' colour"
WIDGET wd_sh_run,    WK_BUTTON, "shatter.run", "Shatter", flags=WGF_PRIMARY, tip="Break it with these settings (on a piece: Re-cut, the original broken again)", sect=.data
WIDGET wd_w_gon,     WK_TOGGLE, "physics.gravity_on", "Gravity", cb=wgon_cb, undo="Physics", tip="Off: nothing falls (space scenes - force fields still pull)"
WIDGET wd_w_grav,    WK_FLOAT, "physics.gravity", step=0.02, dec=2, cb=wgrav_cb, undo="Physics", tip="Gravity (m/s2, X Y Z, -9.81 Y on Earth)"
WIDGET wd_w_rate,    WK_INT, "physics.rate", "Steps a second", 1.0, 1000.0, 0.5, 0, WGF_CLAMP, cb=wnum_cb, undo="Physics", def=120.0, tip="More steps: fast things collide better, slower to run"
WIDGET wd_w_iter,    WK_INT, "physics.iterations", "Iterations", 1.0, 200.0, 0.1, 0, WGF_CLAMP, cb=wnum_cb, undo="Physics", def=10.0, tip="Solver passes a step: stiffer stacks and joints"
WIDGET wd_w_sub,     WK_INT, "physics.substeps", "Substeps", 1.0, 64.0, 0.05, 0, WGF_CLAMP, cb=wnum_cb, undo="Physics", def=4.0, tip="Soft steps a step"

.section .rodata
.align 8
rb_fields:      .quad wd_rb_mass, wd_rb_fric, wd_rb_bounce, wd_rb_damp
.text

# ---- the entry of the active object ----------------------------------------------
# rp_obj -> rax = the active mesh object, or 0
rp_obj:
    sub     rsp, 8
    mov     edi, [rip+active_obj]
    call    obj_get
    test    rax, rax
    jz      9f
    cmp     dword ptr [rax+OB_TYPE], OT_MESH
    je      9f
    xor     eax, eax
9:  add     rsp, 8
    ret

# rp_entry(rdi=block or 0, esi=uid) -> rax = its rigid body entry, or 0
rp_entry:
    xor     eax, eax
    test    rdi, rdi
    jz      9f
    xor     ecx, ecx
1:  cmp     ecx, [rdi+AN_NRB_]
    jae     8f
    imul    rax, rcx, RB_SZ_
    lea     rax, [rdi+AN_RB_+rax]
    cmp     [rax+RB_UID], esi
    je      9f
    inc     ecx
    jmp     1b
8:  xor     eax, eax
9:  ret

# rb_get(edi=object uid, rsi=property name) -> xmm0 = its rigid body's
#   type (1 active, 2 passive), shape (0 box .. 4 compound), mass,
#   friction, bounce or damping; eax = 0 when it is not a body (or no such
#   property)
rb_get:
    push    rbx
    push    r12
    push    r13
    mov     r12, rsi
    mov     esi, edi
    mov     rdi, [rip+an_cur]
    call    rp_entry
    test    rax, rax
    jz      8f
    mov     rbx, rax
    xor     r13d, r13d
1:  cmp     r13d, 10
    jae     8f
    lea     rax, [rip+get_names]
    mov     rsi, [rax+r13*8]
    mov     rdi, r12
    call    str_eq
    test    eax, eax
    jnz     2f
    inc     r13d
    jmp     1b
2:  cmp     r13d, 7                     # x0 y0 z0: where it started (while
    jb      20f                         #  it runs: nil otherwise)
    test    dword ptr [rbx+RB_FLAGS], 1
    jz      8f
    movss   xmm0, [rbx+RB_INIT_+r13*4-28]
    jmp     4f
20: cmp     r13d, 6                     # group: RB_FLAGS bits 4-7
    jne     21f
    mov     eax, [rbx+RB_FLAGS]
    shr     eax, 4
    and     eax, 15
    cvtsi2ss xmm0, eax
    jmp     4f
21: cmp     r13d, 2
    jae     3f
    cvtsi2ss xmm0, dword ptr [rbx+RB_TYPE+r13*4]
    jmp     4f
3:  movss   xmm0, [rbx+RB_MASS-8+r13*4]
4:  mov     eax, 1
    jmp     9f
8:  xorps   xmm0, xmm0
    xor     eax, eax
9:  pop     r13
    pop     r12
    pop     rbx
    ret

.section .rodata
.align 8
get_names:      .quad g_type, g_shape, s_g_mass, g_fric, g_bounce, g_damp, g_group
                .quad g_x0, g_y0, g_z0
g_type:         .asciz "type"
g_shape:        .asciz "shape"
s_g_mass:       .asciz "mass"
g_fric:         .asciz "friction"
g_bounce:       .asciz "bounce"
g_damp:         .asciz "damping"
g_group:        .asciz "group"
g_x0:           .asciz "x0"
g_y0:           .asciz "y0"
g_z0:           .asciz "z0"
.text

# pm_which(rdi=entry) -> eax = the material preset its friction and bounce
#   are (6: its own)
pm_which:
    xor     eax, eax
    lea     rcx, [rip+pm_fb]
1:  mov     edx, [rcx+rax*8]
    cmp     edx, [rdi+RB_MASS+4]
    jne     2f
    mov     edx, [rcx+rax*8+4]
    cmp     edx, [rdi+RB_MASS+8]
    je      9f
2:  inc     eax
    cmp     eax, 6
    jb      1b
9:  ret

# ---- rows --------------------------------------------------------------------------
# rp_cap(rdi=desc, r8=ptr, rdx=caption) -> eax (wg's): the caption at the
#   left, the field at the right; r12d moves down
rp_cap:
    push    rbx
    push    r13
    sub     rsp, 8
    mov     rbx, rdi
    mov     r13, r8
    call    pnl_caption
    mov     rdi, rbx
    mov     r8, r13
    call    pnl_right
    add     r12d, WG_H+4
    add     rsp, 8
    pop     r13
    pop     rbx
    ret

# rp_vec3(rdi=desc, r8=float[3], rdx=caption) - three fields at the right
#   (sub 0 1 2: X Y Z)
rp_vec3:
    push    rbx
    push    rbp
    push    r13
    push    r14
    push    r15
    mov     rbx, rdi
    mov     r13, r8
    call    pnl_caption
    mov     eax, [rip+pnl_w]
    shr     eax, 1
    mov     r14d, eax
    sub     eax, 3+8
    xor     edx, edx
    mov     ecx, 3
    div     ecx
    mov     r15d, eax
    xor     ebp, ebp
1:  mov     rdi, rbx
    mov     esi, [rip+pnl_x]
    add     esi, r14d
    add     esi, 3
    lea     eax, [r15+4]
    imul    eax, ebp
    add     esi, eax
    mov     edx, r12d
    mov     ecx, r15d
    lea     r8, [r13+rbp*4]
    mov     r9d, ebp
    call    wg
    inc     ebp
    cmp     ebp, 3
    jb      1b
    add     r12d, WG_H+4
    pop     r15
    pop     r14
    pop     r13
    pop     rbp
    pop     rbx
    ret

# rp_section(rdi=desc) -> eax = 1 open; r12d moves down
rp_section:
    sub     rsp, 8
    mov     esi, [rip+pnl_x]
    sub     esi, 6
    mov     ecx, [rip+pnl_w]
    add     ecx, 12
    mov     edx, r12d
    xor     r8d, r8d
    xor     r9d, r9d
    call    wg
    add     r12d, 28
    add     rsp, 8
    ret

# ---- writing: every selected body (the active one at least) ------------------------
# rp_each(rdi=fn(rdi=entry)) - fn for each body of the selection, in an owned
#   block (the widget's undo step was taken)
rp_each:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r15, rdi
    xor     edi, edi
    call    an_own_g
    test    rax, rax
    jz      9f
    mov     r14, rax
    mov     edi, [rip+active_obj]
    call    obj_get
    mov     r13, rax
    xor     ebx, ebx
1:  cmp     ebx, [rip+obj_count]
    jae     9f
    mov     edi, ebx
    call    obj_at
    test    rax, rax
    jz      3f
    cmp     rax, r13
    je      2f
    test    dword ptr [rax+OB_FLAGS], OBF_SELECTED
    jz      3f
2:  cmp     dword ptr [rax+OB_TYPE], OT_MESH
    jne     3f
    mov     rdi, r14
    mov     esi, [rax+OB_UID]
    call    rp_entry
    test    rax, rax
    jz      3f
    mov     rdi, rax
    call    r15
3:  inc     ebx
    jmp     1b
9:  mov     dword ptr [rip+dirty], 1
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

type_cb:
    lea     rdi, [rip+put_type]
    jmp     rp_each
put_type:
    mov     eax, [rip+rp_type]
    inc     eax
    mov     [rdi+RB_TYPE], eax
    ret
shape_cb:
    lea     rdi, [rip+put_shape]
    jmp     rp_each
put_shape:
    mov     eax, [rip+rp_shape]
    mov     [rdi+RB_SHAPE], eax
    ret
inst_cb:
    sub     rsp, 8
    call    rb_back                     # (the objects back at the start)
    add     rsp, 8
    lea     rdi, [rip+put_inst]
    jmp     rp_each
put_inst:
    and     dword ptr [rdi+RB_FLAGS], ~2
    mov     eax, [rip+rp_inst]
    and     eax, 1
    add     eax, eax
    or      [rdi+RB_FLAGS], eax
    ret
mat_cb:
    cmp     dword ptr [rip+rp_mat], 6   # (Custom: the values stay)
    jae     9f
    lea     rdi, [rip+put_mat]
    jmp     rp_each
9:  ret
put_mat:
    mov     eax, [rip+rp_mat]
    lea     rcx, [rip+pm_fb]
    mov     edx, [rcx+rax*8]
    mov     [rdi+RB_MASS+4], edx
    mov     edx, [rcx+rax*8+4]
    mov     [rdi+RB_MASS+8], edx
    ret
val_cb:                                 # esi = 0 mass .. 3 damping
    mov     [rip+rp_argbuf], esi
    lea     rdi, [rip+put_val]
    jmp     rp_each
put_val:
    mov     ecx, [rip+rp_argbuf]
    lea     rax, [rip+rp_vals]
    mov     eax, [rax+rcx*4]
    mov     [rdi+RB_MASS+rcx*4], eax
    ret
vel_cb:
    lea     rdi, [rip+put_vel]
    jmp     rp_each
put_vel:
    mov     rax, [rip+rp_vel]
    mov     [rdi+RB_VEL], rax
    mov     eax, [rip+rp_vel+8]
    mov     [rdi+RB_VEL+8], eax
    ret
grp_cb:
    lea     rdi, [rip+put_grp]
    jmp     rp_each
put_grp:
    and     dword ptr [rdi+RB_FLAGS], ~(15 << 4)
    mov     eax, [rip+rp_grp]
    and     eax, 15
    shl     eax, 4
    or      [rdi+RB_FLAGS], eax
    ret

# the world
wgrav_cb:
    sub     rsp, 8
    xor     edi, edi
    call    an_own_g
    add     rsp, 8
    test    rax, rax
    jz      9f
    mov     rcx, [rip+rp_grav]
    mov     [rax+AN_RW_+RW_GRAV], rcx
    mov     ecx, [rip+rp_grav+8]
    mov     [rax+AN_RW_+RW_GRAV+8], ecx
    mov     dword ptr [rax+AN_RW_+RW_SET], 1
    mov     dword ptr [rip+dirty], 1
9:  ret
wgon_cb:                                # on: Earth's again, off: none
    xor     eax, eax
    mov     [rip+rp_grav], eax
    mov     [rip+rp_grav+8], eax
    cmp     dword ptr [rip+rp_gon], 0
    je      1f
    mov     eax, [rip+pf_g]
1:  mov     [rip+rp_grav+4], eax
    jmp     wgrav_cb
wnum_cb:
    sub     rsp, 8
    xor     edi, edi
    call    an_own_g
    add     rsp, 8
    test    rax, rax
    jz      9f
    mov     ecx, [rip+rp_rate]
    mov     [rax+AN_RW_+RW_RATE], ecx
    mov     ecx, [rip+rp_iter]
    mov     [rax+AN_RW_+RW_ITER], ecx
    mov     ecx, [rip+rp_sub]
    mov     [rax+AN_RW_+RW_SUB], ecx
    mov     dword ptr [rip+dirty], 1
9:  ret

# the joint picked: jt_own -> rax = it in an owned block, or 0
jt_own:
    sub     rsp, 8
    xor     edi, edi
    call    an_own_g
    add     rsp, 8
    test    rax, rax
    jz      9f
    mov     ecx, [rip+rp_jidx]
    cmp     ecx, [rax+AN_NJT_]
    jae     8f
    imul    rcx, rcx, JT_SZ_
    lea     rax, [rax+AN_JT_+rcx]
    mov     dword ptr [rip+dirty], 1
    ret
8:  xor     eax, eax
9:  ret

jtype_cb:
    sub     rsp, 8
    call    jt_own
    add     rsp, 8
    test    rax, rax
    jz      9f
    mov     ecx, [rip+rp_jtype]
    inc     ecx
    mov     [rax+JT_TYPE], ecx
9:  ret
jother_cb:                              # 0 the world, i + 1 the i-th object
    push    rbx
    call    jt_own
    test    rax, rax
    jz      9f
    mov     rbx, rax
    mov     edi, [rip+rp_jother]
    test    edi, edi
    jnz     1f
    mov     eax, [rip+rp_juid]          # the world: always B
    mov     [rbx+JT_A], eax
    mov     dword ptr [rbx+JT_B], 0
    jmp     9f
1:  dec     edi
    call    obj_at
    test    rax, rax
    jz      9f
    mov     eax, [rax+OB_UID]
    cmp     eax, [rip+rp_juid]          # (not to itself)
    je      9f
    mov     ecx, [rip+rp_juid]
    mov     [rbx+JT_A], ecx
    mov     [rbx+JT_B], eax
9:  pop     rbx
    ret
jpiv_cb:
    sub     rsp, 8
    call    jt_own
    add     rsp, 8
    test    rax, rax
    jz      9f
    mov     rcx, [rip+rp_jpiv]
    mov     [rax+JT_PIV], rcx
    mov     ecx, [rip+rp_jpiv+8]
    mov     [rax+JT_PIV+8], ecx
9:  ret
jaxis_cb:
    sub     rsp, 8
    call    jt_own
    add     rsp, 8
    test    rax, rax
    jz      9f
    mov     rcx, [rip+rp_jaxis]
    mov     [rax+JT_AXIS], rcx
    mov     ecx, [rip+rp_jaxis+8]
    mov     [rax+JT_AXIS+8], ecx
9:  ret
jflag_cb:                               # limits (1), motor (2)
    sub     rsp, 8
    call    jt_own
    add     rsp, 8
    test    rax, rax
    jz      9f
    and     dword ptr [rax+JT_FLG], ~3
    mov     ecx, [rip+rp_jlim]
    and     ecx, 1
    mov     edx, [rip+rp_jmot]
    and     edx, 1
    add     edx, edx
    or      ecx, edx
    or      [rax+JT_FLG], ecx
9:  ret
.macro JT_PUT name, var, off
\name:
    sub     rsp, 8
    call    jt_own
    add     rsp, 8
    test    rax, rax
    jz      9f
    mov     ecx, [rip+\var]
    mov     [rax+\off], ecx
9:  ret
.endm
JT_PUT jlo_cb, rp_jlo, JT_LO
JT_PUT jhi_cb, rp_jhi, JT_HI
JT_PUT jspd_cb, rp_jspd, JT_MSPD
JT_PUT jfor_cb, rp_jfor, JT_MFOR
JT_PUT jbrk_cb, rp_jbrk, JT_BRK

# jt_others -> rax = labels, edx = how many: World, then every object
jt_others:
    sub     rsp, 8
    lea     rdi, [rip+rp_olbl]
    lea     rsi, [rip+s_world]
    mov     edx, [rip+obj_count]
    lea     rcx, [rip+obj_name_at]
    mov     r8d, MAXOLBL
    call    pnl_list
    mov     edx, eax
    lea     rax, [rip+rp_olbl]
    add     rsp, 8
    ret
obj_name_at:                            # edi = i -> rax = its name
    sub     rsp, 8
    call    obj_at
    add     rsp, 8
    test    rax, rax
    jz      1f
    add     rax, OB_NAME
    ret
1:  lea     rax, [rip+k_none]
    ret

# jt_remove - the joint picked goes (the last into its place)
jt_remove:
    push    rbx
    sub     rsp, 16
    call    rb_back
    lea     rdi, [rip+s_undo]
    call    undo_push
    xor     edi, edi
    call    an_own_g
    test    rax, rax
    jz      9f
    mov     rbx, rax
    mov     esi, [rip+rp_jidx]
    cmp     esi, [rbx+AN_NJT_]
    jae     9f
    mov     eax, [rbx+AN_NJT_]
    dec     eax
    mov     [rbx+AN_NJT_], eax
    imul    rdi, rsi, JT_SZ_
    lea     rdi, [rbx+AN_JT_+rdi]
    imul    rsi, rax, JT_SZ_
    lea     rsi, [rbx+AN_JT_+rsi]
    mov     ecx, JT_SZ_
    rep     movsb
    mov     dword ptr [rip+rp_jsel], 0
    mov     dword ptr [rip+dirty], 1
9:  add     rsp, 16
    pop     rbx
    ret

# rb_back - no simulation: objects back where they began (before removing)
rb_back:
    sub     rsp, 8
    xorps   xmm0, xmm0                  # (frame 0: at or before any start)
    call    rb_frame
    add     rsp, 8
    ret

# ---- shatter: the panel's own values -------------------------------------------------
pat_cb:
    mov     dword ptr [rip+sp_pre], 0
    ret
cnt_cb:                                 # rdi = the count (an int)
    cvtsi2ss xmm0, dword ptr [rdi]
    movss   [rip+sp_val], xmm0
    ret
pre_cb:                                 # a preset: its pattern and values shown
    mov     eax, [rip+sp_pre]
    test    eax, eax
    jz      9f
    dec     eax
    imul    eax, eax, SO_PS_SZ
    lea     rcx, [rip+so_pdata]
    add     rcx, rax
    mov     eax, [rcx]                  # pattern 0 shards, 1 bricks, 2 balls
    mov     [rip+sp_pat], eax
    cvtsi2ss xmm0, dword ptr [rcx+4]
    movss   [rip+sp_val], xmm0
    mov     eax, [rcx+8]
    mov     [rip+sp_val+4], eax
    mov     eax, [rcx+12]
    mov     [rip+sp_val+8], eax
9:  ret

# sp_run - object.shatter [again] [preset p] pattern count n [seed s] [glue g
#   [paint]] [impact i] [gap g] [inner r g b] (what differs from the preset)
sp_run:
    push    rbx
    push    r12
    sub     rsp, 8
    call    fmt_reset
    cmp     dword ptr [rip+sp_recut], 0
    je      1f
    lea     rdi, [rip+k_again]
    call    fmt_str
1:  mov     eax, [rip+sp_pre]
    lea     rcx, [rip+sp_pre_kw]
    mov     rdi, [rcx+rax*8]
    call    fmt_str
    xor     ebx, ebx                    # rbx = the preset's row, or 0
    mov     eax, [rip+sp_pre]
    test    eax, eax
    jz      2f
    dec     eax
    imul    eax, eax, SO_PS_SZ
    lea     rbx, [rip+so_pdata]
    add     rbx, rax
2:  mov     eax, [rip+sp_pat]
    test    rbx, rbx
    jz      3f
    cmp     eax, [rbx]
    je      4f
3:  lea     rcx, [rip+sp_pat_kw]
    mov     rdi, [rcx+rax*8]
    call    fmt_str
4:  lea     rdi, [rip+k_count]          # count (always: the field shows it)
    call    fmt_str
    cvtss2si edi, dword ptr [rip+sp_val]
    call    fmt_int
    cmp     dword ptr [rip+sp_seed], 1
    je      5f
    lea     rdi, [rip+k_seed]
    call    fmt_str
    mov     edi, [rip+sp_seed]
    call    fmt_int
5:  mov     eax, [rip+sp_val+4]         # glue: when set and not the preset's,
    cmp     dword ptr [rip+sp_paint], 0 #  or to paint it
    jne     51f
    test    rbx, rbx
    jz      52f
    cmp     eax, [rbx+8]
    je      6f
    jmp     51f
52: test    eax, eax
    jz      6f
51: lea     rdi, [rip+k_glue]
    call    fmt_str
    movss   xmm0, [rip+sp_val+4]
    call    fmt_val3
    cmp     dword ptr [rip+sp_paint], 0
    je      6f
    lea     rdi, [rip+k_paint]
    call    fmt_str
6:  mov     eax, [rip+sp_val+8]         # impact: the same
    test    rbx, rbx
    jz      61f
    cmp     eax, [rbx+12]
    je      7f
    jmp     62f
61: test    eax, eax
    jz      7f
62: lea     rdi, [rip+k_impact]
    call    fmt_str
    movss   xmm0, [rip+sp_val+8]
    call    fmt_val3
7:  cmp     dword ptr [rip+sp_pat], 1   # bricks: the gap
    jne     8f
    xorps   xmm0, xmm0
    ucomiss xmm0, [rip+sp_gap]
    je      8f
    lea     rdi, [rip+k_gap]
    call    fmt_str
    movss   xmm0, [rip+sp_gap]
    call    fmt_val3
8:  cmp     dword ptr [rip+sp_inner_on], 0
    je      10f
    lea     rdi, [rip+k_inner]          # the cut faces: r g b, 0..1 as shown
    call    fmt_str
    lea     rdi, [rip+sp_inner]
    call    cpk_rgb_of
    mov     r12d, eax
    mov     ebx, 16
81: mov     eax, r12d
    mov     ecx, ebx
    shr     eax, cl
    and     eax, 255
    cvtsi2ss xmm0, eax
    divss   xmm0, [rip+pf_255]
    call    fmt_val3
    sub     ebx, 8
    js      10f
    lea     rdi, [rip+k_sp]
    call    fmt_str
    jmp     81b
10: lea     rdi, [rip+s_sh_op]
    call    rp_exec
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# rp_exec(rdi=operator name) - it runs with fmt_buf as its argument (its own
#   undo step, on the selection)
rp_exec:
    push    rbx
    sub     rsp, 16
    mov     rbx, rdi
    lea     rsi, [rip+fmt_buf]
    lea     rdi, [rip+rp_argbuf]
    mov     ecx, 159
    rep     movsb
    mov     byte ptr [rdi], 0
    mov     rdi, rbx
    call    find_op_by_name
    test    rax, rax
    jz      9f
    push    qword ptr [rip+op_arg]
    lea     rcx, [rip+rp_argbuf]
    mov     [rip+op_arg], rcx
    mov     rdi, rax
    call    run_op
    pop     qword ptr [rip+op_arg]
    mov     dword ptr [rip+dirty], 1
9:  add     rsp, 16
    pop     rbx
    ret

# rb_add_new - rigid.add <active|passive> <shape> on the selection
rb_add_new:
    sub     rsp, 8
    call    fmt_reset
    lea     rdi, [rip+k_active]
    cmp     dword ptr [rip+rp_ntype], 0
    je      1f
    lea     rdi, [rip+k_passive]
1:  call    fmt_str
    mov     eax, [rip+rp_nshape]
    lea     rcx, [rip+kw_shape]
    mov     rdi, [rcx+rax*8]
    call    fmt_str
    lea     rdi, [rip+s_rb_add]
    call    rp_exec
    add     rsp, 8
    ret

# sp_sync(edi=pattern, esi=preset, edx=count, xmm0=glue, xmm1=impact) - the
#   last shatter's settings, shown for a re-cut
sp_sync:
    mov     [rip+sp_pat], edi
    mov     [rip+sp_pre], esi
    cvtsi2ss xmm2, edx
    movss   [rip+sp_val], xmm2
    movss   [rip+sp_val+4], xmm0
    movss   [rip+sp_val+8], xmm1
    ret

# =============================================================================
#  Drawing
# =============================================================================
# rb_props_draw(edi=y) -> eax = y below the section
rb_props_draw:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 24
    mov     r12d, edi
    call    pnl_begin
    call    rp_obj
    test    rax, rax
    jnz     10f
    call    fl_active                   # a force field: its section, the world
    test    rax, rax
    jz      .Lpd_out
    add     r12d, 8
    mov     edi, r12d
    call    fl_props
    mov     r12d, eax
    mov     r14, [rip+an_cur]
    jmp     .Lpd_world
10: mov     rbx, rax                    # the object
    add     r12d, 8
    mov     r14, [rip+an_cur]           # the block (0: none yet)
    mov     rdi, r14
    mov     esi, [rbx+OB_UID]
    call    rp_entry
    mov     r13, rax                    # its entry, or 0
    mov     rdi, rbx                    # a piece: its original hidden
    call    par_of
    xor     ecx, ecx
    test    rax, rax
    jz      1f
    test    dword ptr [rax+OB_FLAGS], OBF_HIDDEN
    jz      1f
    mov     [rsp], rax
    inc     ecx
1:  mov     [rip+sp_recut], ecx
    call    rp_status
    lea     rdi, [rip+wd_ph_sbody]
    call    rp_section
    test    eax, eax
    jz      .Lpd_joints
    test    r13, r13
    jnz     .Lpd_body
    lea     rdi, [rip+wd_rb_ntype]      # not a body: type, shape, Add
    lea     r8, [rip+rp_ntype]
    lea     rdx, [rip+s_c_type]
    call    rp_cap
    lea     rdi, [rip+wd_rb_nshape]
    lea     r8, [rip+rp_nshape]
    lea     rdx, [rip+s_c_shape]
    call    rp_cap
    lea     rdi, [rip+wd_rb_add]
    xor     r8d, r8d
    call    pnl_full
    test    eax, eax
    jz      .Lpd_joints
    call    rb_add_new
    jmp     .Lpd_joints
.Lpd_body:
    mov     eax, [r13+RB_TYPE]          # the values, as they are
    dec     eax
    and     eax, 1
    mov     [rip+rp_type], eax
    mov     eax, [r13+RB_SHAPE]
    cmp     eax, 6
    jbe     2f
    xor     eax, eax
2:  mov     [rip+rp_shape], eax
    mov     eax, [r13+RB_FLAGS]
    shr     eax, 1
    and     eax, 1
    mov     [rip+rp_inst], eax
    mov     rdi, r13
    call    pm_which
    mov     [rip+rp_mat], eax
    movups  xmm0, [r13+RB_MASS]
    movups  [rip+rp_vals], xmm0
    mov     rax, [r13+RB_VEL]
    mov     [rip+rp_vel], rax
    mov     eax, [r13+RB_VEL+8]
    mov     [rip+rp_vel+8], eax
    mov     eax, [r13+RB_FLAGS]
    shr     eax, 4
    and     eax, 15
    mov     [rip+rp_grp], eax
    lea     rdi, [rip+wd_rb_type]
    lea     r8, [rip+rp_type]
    lea     rdx, [rip+s_c_type]
    call    rp_cap
    lea     rdi, [rip+wd_rb_shape]
    lea     r8, [rip+rp_shape]
    lea     rdx, [rip+s_c_shape]
    call    rp_cap
    mov     rdi, rbx                    # instances (geometry nodes): the
    call    obj_eval                    #  object, or each of them, a body
    mov     rdi, rax
    call    inst_count
    test    eax, eax
    jz      3f
    lea     rdi, [rip+wd_rb_inst]
    lea     r8, [rip+rp_inst]
    lea     rdx, [rip+s_c_bodies]
    call    rp_cap
3:  lea     rdi, [rip+wd_rb_mat]
    lea     r8, [rip+rp_mat]
    lea     rdx, [rip+s_c_mat]
    call    rp_cap
    xor     r15d, r15d                  # mass, friction, bounce, damping
4:  lea     rax, [rip+rb_fields]
    mov     rdi, [rax+r15*8]
    mov     esi, [rip+pnl_x]
    mov     ecx, [rip+pnl_w]
    mov     edx, r12d
    lea     r8, [rip+rp_vals]
    lea     r8, [r8+r15*4]
    mov     r9d, r15d
    call    wg
    add     r12d, WG_H+4
    inc     r15d
    cmp     r15d, 4
    jb      4b
    lea     rdi, [rip+wd_rb_vel]
    lea     r8, [rip+rp_vel]
    lea     rdx, [rip+s_c_vel]
    call    rp_vec3
    lea     rdi, [rip+wd_rb_grp]
    lea     r8, [rip+rp_grp]
    call    pnl_full
    lea     rdi, [rip+wd_rb_rem]
    xor     r8d, r8d
    call    pnl_full

.Lpd_joints:
    lea     rdi, [rip+wd_ph_sjoint]
    call    rp_section
    test    eax, eax
    jz      .Lpd_shatter
    call    rp_joints

.Lpd_shatter:
    lea     rdi, [rip+wd_ph_sshat]
    call    rp_section
    test    eax, eax
    jz      .Lpd_world
    call    rp_shatter

.Lpd_world:
    lea     rdi, [rip+wd_ph_sworld]
    call    rp_section
    test    eax, eax
    jz      .Lpd_out
    call    rp_world
.Lpd_out:
    mov     eax, r12d
    add     rsp, 24
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# rp_status (rbx=object, r13=entry or 0, r14=block, [rsp+8]=original when a
#   piece) - one line: what it is; while it runs, what the simulation does
rp_status:
    push    rbp
    sub     rsp, 16
    call    fmt_reset
    cmp     dword ptr [rip+sp_recut], 0
    je      1f
    lea     rdi, [rip+s_st_piece]       # Piece of Wall,
    call    fmt_str
    mov     rax, [rsp+16+8+8]           # (the caller's [rsp])
    lea     rdi, [rax+OB_NAME]
    call    fmt_str
    lea     rdi, [rip+s_st_sep]
    call    fmt_str
1:  test    r13, r13
    jnz     2f
    lea     rdi, [rip+s_st_none]
    call    fmt_str
    jmp     8f
2:  mov     eax, [r13+RB_TYPE]          # Active Convex Hull, 4.2 kg
    lea     rdi, [rip+s_active]
    cmp     eax, 2
    jne     3f
    lea     rdi, [rip+s_passive]
3:  call    fmt_str
    mov     edi, ' '
    call    fmt_char
    mov     eax, [r13+RB_SHAPE]
    cmp     eax, 6
    jbe     4f
    xor     eax, eax
4:  lea     rcx, [rip+l_shape]
    mov     rdi, [rcx+rax*8]
    call    fmt_str
    cmp     dword ptr [r13+RB_TYPE], 2
    je      5f
    lea     rdi, [rip+s_st_sep]
    call    fmt_str
    movss   xmm0, [r13+RB_MASS]
    call    fmt_val3
    lea     rdi, [rip+s_st_kg]
    call    fmt_str
5:  test    dword ptr [r13+RB_FLAGS], 2
    jz      6f
    lea     rdi, [rip+s_st_sep]
    call    fmt_str
    lea     rdi, [rip+s_st_inst]
    call    fmt_str
6:  call    rp_njoints                  # , 2 joints
    test    eax, eax
    jz      8f
    mov     ebp, eax
    lea     rdi, [rip+s_st_sep]
    call    fmt_str
    mov     edi, ebp
    call    fmt_int
    lea     rdi, [rip+s_st_joint]
    cmp     ebp, 1
    je      7f
    lea     rdi, [rip+s_st_joints]
7:  call    fmt_str
8:  lea     rdx, [rip+fmt_buf]
    call    pnl_text
    xor     edi, edi                    # running: what it is doing
    call    rb_info
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    jbe     9f
    call    fmt_reset
    lea     rdi, [rip+s_st_run]
    call    fmt_str
    xor     edi, edi
    call    rb_info
    cvttss2si edi, xmm0
    call    fmt_int
    lea     rdi, [rip+s_bodies]
    call    fmt_str
    mov     edi, 2
    call    rb_info
    cvttss2si edi, xmm0
    call    fmt_int
    lea     rdi, [rip+s_awake]
    call    fmt_str
    mov     edi, 4
    call    rb_info
    cvttss2si edi, xmm0
    call    fmt_int
    lea     rdi, [rip+s_ms]
    call    fmt_str
    lea     rdx, [rip+fmt_buf]
    call    pnl_hint
9:  add     r12d, 4
    add     rsp, 16
    pop     rbp
    ret

# rp_njoints (rbx=object, r14=block) -> eax = the joints it is in (not the
#   impact markers)
rp_njoints:
    xor     eax, eax
    test    r14, r14
    jz      9f
    xor     ecx, ecx
    mov     edx, [rbx+OB_UID]
1:  cmp     ecx, [r14+AN_NJT_]
    jae     9f
    imul    r8, rcx, JT_SZ_
    lea     r8, [r14+AN_JT_+r8]
    mov     r9d, [r8+JT_TYPE]
    and     r9d, 7
    cmp     r9d, 4
    ja      3f
    cmp     [r8+JT_A], edx
    je      2f
    cmp     [r8+JT_B], edx
    jne     3f
2:  inc     eax
3:  inc     ecx
    jmp     1b
9:  ret

# rp_joints (rbx=object, r14=block) - the list, the one picked, Add / Remove
rp_joints:
    push    rbp
    push    r15
    sub     rsp, 24
    mov     eax, [rbx+OB_UID]
    mov     [rip+rp_juid], eax
    xor     r15d, r15d                  # the joint (block index)
    xor     ebp, ebp                    # listed
    mov     dword ptr [rsp], -1         # the picked one's block index
    mov     dword ptr [rsp+4], 0        # more than listed
1:  test    r14, r14
    jz      5f
    cmp     r15d, [r14+AN_NJT_]
    jae     5f
    imul    rax, r15, JT_SZ_
    lea     rcx, [r14+AN_JT_+rax]
    mov     eax, [rcx+JT_TYPE]
    and     eax, 7
    cmp     eax, 4
    ja      4f
    mov     eax, [rbx+OB_UID]
    cmp     [rcx+JT_A], eax
    je      2f
    cmp     [rcx+JT_B], eax
    jne     4f
2:  cmp     ebp, MAXJROW
    jb      21f
    inc     dword ptr [rsp+4]
    jmp     4f
21: cmp     ebp, [rip+rp_jsel]
    jne     22f
    mov     [rsp], r15d
22: mov     [rsp+8], rcx
    lea     rdi, [rip+wd_jt_row]        # a row: Hinge to world
    mov     esi, [rip+pnl_x]
    mov     edx, r12d
    mov     ecx, [rip+pnl_w]
    lea     r8, [rip+rp_jsel]
    mov     r9d, ebp
    call    wg
    call    fmt_reset
    mov     rcx, [rsp+8]
    mov     eax, [rcx+JT_TYPE]
    and     eax, 7
    dec     eax
    and     eax, 3
    lea     rdx, [rip+l_jtype]
    mov     rdi, [rdx+rax*8]
    call    fmt_str
    lea     rdi, [rip+s_to]
    call    fmt_str
    mov     rcx, [rsp+8]                # the other one
    mov     edi, [rcx+JT_B]
    cmp     edi, [rbx+OB_UID]
    jne     3f
    mov     edi, [rcx+JT_A]
3:  lea     rdx, [rip+s_world]
    test    edi, edi
    jz      31f
    call    obj_by_uid
    lea     rdx, [rip+s_world]
    test    rax, rax
    jz      31f
    lea     rdx, [rax+OB_NAME]
31: mov     rdi, rdx
    call    fmt_str
    mov     edi, [rip+pnl_x]
    add     edi, 8
    lea     esi, [r12+4]
    lea     rdx, [rip+fmt_buf]
    mov     ecx, COL_TEXT
    call    draw_small
    add     r12d, WG_H+2
    inc     ebp
4:  inc     r15d
    jmp     1b
5:  test    ebp, ebp
    jnz     6f
    lea     rdx, [rip+s_no_joint]
    call    pnl_hint
    jmp     .Ljt_buttons
6:  cmp     dword ptr [rsp+4], 0        # and 120 more joints (glue)
    je      61f
    call    fmt_reset
    mov     edi, [rsp+4]
    call    fmt_int
    lea     rdi, [rip+s_more]
    call    fmt_str
    lea     rdx, [rip+fmt_buf]
    call    pnl_hint
61: mov     eax, [rsp]                  # (the pick gone: the first)
    test    eax, eax
    jns     62f
    mov     dword ptr [rip+rp_jsel], 0
    jmp     .Ljt_buttons
62: mov     [rip+rp_jidx], eax
    imul    rax, rax, JT_SZ_
    lea     r15, [r14+AN_JT_+rax]       # the joint picked: its values
    add     r12d, 4
    mov     eax, [r15+JT_TYPE]
    and     eax, 7
    dec     eax
    and     eax, 3
    mov     [rip+rp_jtype], eax
    mov     eax, [r15+JT_B]             # the other one: the world, or the
    xor     ecx, ecx                    #  object's place in the list + 1
    mov     dword ptr [rip+rp_jside], 0
    cmp     eax, [rbx+OB_UID]
    jne     63f
    mov     eax, [r15+JT_A]
    mov     dword ptr [rip+rp_jside], 1
63: test    eax, eax
    jz      65f
    lea     rdx, [rip+obj_list]
64: cmp     ecx, [rip+obj_count]
    jae     66f
    mov     edi, [rdx+rcx*4]
    push    rax
    push    rcx
    push    rdx
    push    rdx
    call    obj_get
    mov     r8, rax
    pop     rdx
    pop     rdx
    pop     rcx
    pop     rax
    test    r8, r8
    jz      641f
    cmp     [r8+OB_UID], eax
    je      642f
641:inc     ecx
    jmp     64b
642:inc     ecx
    jmp     65f
66: xor     ecx, ecx
65: mov     [rip+rp_jother], ecx
    mov     rax, [r15+JT_PIV]
    mov     [rip+rp_jpiv], rax
    mov     eax, [r15+JT_PIV+8]
    mov     [rip+rp_jpiv+8], eax
    mov     rax, [r15+JT_AXIS]
    mov     [rip+rp_jaxis], rax
    mov     eax, [r15+JT_AXIS+8]
    mov     [rip+rp_jaxis+8], eax
    mov     eax, [r15+JT_FLG]
    mov     ecx, eax
    and     ecx, 1
    mov     [rip+rp_jlim], ecx
    shr     eax, 1
    and     eax, 1
    mov     [rip+rp_jmot], eax
    mov     eax, [r15+JT_LO]
    mov     [rip+rp_jlo], eax
    mov     eax, [r15+JT_HI]
    mov     [rip+rp_jhi], eax
    mov     eax, [r15+JT_MSPD]
    mov     [rip+rp_jspd], eax
    mov     eax, [r15+JT_MFOR]
    mov     [rip+rp_jfor], eax
    mov     eax, [r15+JT_BRK]
    mov     [rip+rp_jbrk], eax
    lea     rdi, [rip+wd_jt_type]
    lea     r8, [rip+rp_jtype]
    lea     rdx, [rip+s_c_type]
    call    rp_cap
    lea     rdi, [rip+wd_jt_other]
    lea     r8, [rip+rp_jother]
    lea     rdx, [rip+s_c_other]
    call    rp_cap
    lea     rdi, [rip+wd_jt_piv]
    lea     r8, [rip+rp_jpiv]
    lea     rdx, [rip+s_c_pivot]
    call    rp_vec3
    mov     eax, [rip+rp_jtype]         # hinge (1), slider (3): axis, limits,
    cmp     eax, 1                      #  motor
    je      7f
    cmp     eax, 3
    jne     8f
7:  lea     rdi, [rip+wd_jt_axis]
    lea     r8, [rip+rp_jaxis]
    lea     rdx, [rip+s_c_axis]
    call    rp_vec3
    lea     rdi, [rip+wd_jt_lim]
    lea     r8, [rip+rp_jlim]
    call    pnl_full
    cmp     dword ptr [rip+rp_jlim], 0
    je      71f
    lea     rdi, [rip+wd_jt_loa]
    lea     rax, [rip+wd_jt_lom]
    cmp     dword ptr [rip+rp_jtype], 3
    cmove   rdi, rax
    lea     r8, [rip+rp_jlo]
    call    pnl_left
    lea     rdi, [rip+wd_jt_hia]
    lea     rax, [rip+wd_jt_him]
    cmp     dword ptr [rip+rp_jtype], 3
    cmove   rdi, rax
    lea     r8, [rip+rp_jhi]
    call    pnl_right
    add     r12d, WG_H+4
71: lea     rdi, [rip+wd_jt_mot]
    lea     r8, [rip+rp_jmot]
    call    pnl_full
    cmp     dword ptr [rip+rp_jmot], 0
    je      8f
    lea     rdi, [rip+wd_jt_spda]
    lea     rax, [rip+wd_jt_spdm]
    cmp     dword ptr [rip+rp_jtype], 3
    cmove   rdi, rax
    lea     r8, [rip+rp_jspd]
    call    pnl_left
    lea     rdi, [rip+wd_jt_for]
    lea     r8, [rip+rp_jfor]
    call    pnl_right
    add     r12d, WG_H+4
8:  lea     rdi, [rip+wd_jt_brk]
    lea     r8, [rip+rp_jbrk]
    call    pnl_full
.Ljt_buttons:
    lea     rdi, [rip+wd_jt_add]
    xor     r8d, r8d
    call    pnl_left
    test    ebp, ebp
    jz      9f
    lea     rdi, [rip+wd_jt_rem]
    xor     r8d, r8d
    call    pnl_right
    test    eax, eax
    jz      9f
    call    jt_remove
9:  add     r12d, WG_H+4
    add     rsp, 24
    pop     r15
    pop     rbp
    ret

# rp_shatter - pattern, preset, count, seed, glue, impact, gap, cut faces, run
rp_shatter:
    sub     rsp, 8
    lea     rdi, [rip+wd_sh_pat]
    lea     r8, [rip+sp_pat]
    lea     rdx, [rip+s_c_pattern]
    call    rp_cap
    lea     rdi, [rip+wd_sh_pre]
    lea     r8, [rip+sp_pre]
    lea     rdx, [rip+s_c_preset]
    call    rp_cap
    cvtss2si eax, dword ptr [rip+sp_val]   # (count: the panel keeps a float)
    mov     [rip+rp_argbuf+128], eax
    lea     rdi, [rip+wd_sh_cnt]
    lea     r8, [rip+rp_argbuf+128]
    call    pnl_left
    lea     rdi, [rip+wd_sh_seed]
    lea     r8, [rip+sp_seed]
    call    pnl_right
    add     r12d, WG_H+4
    lea     rdi, [rip+wd_sh_glue]
    lea     r8, [rip+sp_val+4]
    call    pnl_full
    xorps   xmm0, xmm0
    ucomiss xmm0, [rip+sp_val+4]
    je      1f
    lea     rdi, [rip+wd_sh_paint]
    lea     r8, [rip+sp_paint]
    call    pnl_full
1:  lea     rdi, [rip+wd_sh_imp]
    lea     r8, [rip+sp_val+8]
    call    pnl_full
    cmp     dword ptr [rip+sp_pat], 1
    jne     2f
    lea     rdi, [rip+wd_sh_gap]
    lea     r8, [rip+sp_gap]
    call    pnl_full
2:  lea     rdi, [rip+wd_sh_inon]
    lea     r8, [rip+sp_inner_on]
    call    pnl_left
    cmp     dword ptr [rip+sp_inner_on], 0
    je      3f
    lea     rdi, [rip+wd_sh_inner]
    lea     r8, [rip+sp_inner]
    call    pnl_right
3:  add     r12d, WG_H+4
    lea     rax, [rip+s_h_shat]         # Shatter / Re-cut
    cmp     dword ptr [rip+sp_recut], 0
    je      4f
    lea     rax, [rip+s_recut]
4:  mov     [rip+wd_sh_run+WD_LABEL], rax
    lea     rdi, [rip+wd_sh_run]
    xor     r8d, r8d
    call    pnl_full
    test    eax, eax
    jz      9f
    call    sp_run
9:  add     rsp, 8
    ret

# rp_world (r14=block) - gravity, steps a second, iterations, substeps
rp_world:
    sub     rsp, 8
    xor     eax, eax                    # the defaults when not set
    mov     [rip+rp_grav], eax
    mov     [rip+rp_grav+8], eax
    mov     eax, [rip+pf_g]
    mov     [rip+rp_grav+4], eax
    mov     dword ptr [rip+rp_rate], 120
    mov     dword ptr [rip+rp_iter], 10
    mov     dword ptr [rip+rp_sub], 4
    test    r14, r14
    jz      5f
    cmp     dword ptr [r14+AN_RW_+RW_SET], 0
    je      1f
    mov     rax, [r14+AN_RW_+RW_GRAV]
    mov     [rip+rp_grav], rax
    mov     eax, [r14+AN_RW_+RW_GRAV+8]
    mov     [rip+rp_grav+8], eax
1:  mov     eax, [r14+AN_RW_+RW_RATE]
    test    eax, eax
    jz      2f
    mov     [rip+rp_rate], eax
2:  mov     eax, [r14+AN_RW_+RW_ITER]
    test    eax, eax
    jz      3f
    mov     [rip+rp_iter], eax
3:  mov     eax, [r14+AN_RW_+RW_SUB]
    test    eax, eax
    jz      5f
    mov     [rip+rp_sub], eax
5:  mov     eax, [rip+rp_grav]          # gravity on: any of it
    or      eax, [rip+rp_grav+4]
    or      eax, [rip+rp_grav+8]
    and     eax, 0x7fffffff
    setnz   al
    movzx   eax, al
    mov     [rip+rp_gon], eax
    lea     rdi, [rip+wd_w_gon]
    lea     r8, [rip+rp_gon]
    call    pnl_full
    lea     rdi, [rip+wd_w_grav]
    lea     r8, [rip+rp_grav]
    lea     rdx, [rip+s_c_grav]
    call    rp_vec3
    lea     rdi, [rip+wd_w_rate]
    lea     r8, [rip+rp_rate]
    call    pnl_full
    lea     rdi, [rip+wd_w_iter]
    lea     r8, [rip+rp_iter]
    call    pnl_full
    lea     rdi, [rip+wd_w_sub]
    lea     r8, [rip+rp_sub]
    call    pnl_full
    add     rsp, 8
    ret

.section .rodata
s_recut:        .asciz "Re-cut"
.text

.section .note.GNU-stack,"",@progbits
