# =============================================================================
#  BeeModel - rigid body physics.
#
#  Objects become rigid bodies (rigid.add): active ones fall and collide,
#  passive ones stay where they are and are collided with. Shapes: box,
#  sphere, capsule (a core and a radius), the convex hull of the mesh, or a
#  compound of convex parts (the mesh cut into pieces until each is close
#  to its hull). Joints (fixed, hinge, point) tie two bodies or a body to
#  the world. The settings live in the animation block (undo, saving).
#
#  The simulation runs when the frame goes past the scene's start: bodies
#  are made from the objects as they are there (that transform is kept and
#  given back on the way back to the start), then fixed steps (the rate,
#  120 a second by default) until the frame's time; the bodies' transforms
#  go into their objects. Going back, it starts again from the start.
#
#  A step: bounding boxes, sweep and prune along X for pairs, a contact
#  manifold per pair of parts that touch (kept between steps), narrow phase
#  in parallel (GJK / EPA, collide.s; up to four points a manifold, kept by
#  their anchors on each body, and on boxes and hulls more found by tilting
#  one a little), then islands (bodies touching or jointed, through moving
#  bodies only) solved in parallel. Each island takes the step in substeps
#  (4 by default; "soft step"): forces, warm start, sequential impulses
#  (friction, speculative contacts, soft contacts that push overlaps apart
#  as a damped spring), the bodies moved, then a relax pass without the
#  push (no bounce from it); restitution once at the end. A contact's gap
#  follows its bodies through the substeps. An island at rest for half a
#  second sleeps until something awake touches it.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

.globl rb_frame
.globl rb_gravity
.globl rb_info
.globl rb_reset
.globl rb_impulse
.globl rb_live
.globl rb_inst_mesh

# the settings (anim block)
.equ RW_GRAV,   0                       # gravity (3 floats; all 0: -9.81 Y)
.equ RW_RATE,   12                      # steps a second (0: 120)
.equ RW_ITER,   16                      # solver iterations (0: 10)
.equ RW_SET,    20                      # gravity was set
.equ RW_SUB,    24                      # substeps a step (0: 4)
.equ RB_UID,    0
.equ RB_TYPE,   4                       # 1 active, 2 passive
.equ RB_SHAPE,  8                       # 0 box 1 sphere 2 capsule 3 hull 4 compound
                                        #  5 mesh 6 plane (passive; moving ones:
                                        #  compound, box)
.equ RB_MASS,   12
.equ RB_FRIC,   16
.equ RB_REST,   20
.equ RB_DAMP,   24
.equ RB_FLAGS,  28                      # bit 0: RB_INIT holds the start; bit 1:
                                        #  its instances are the bodies
.equ RB_INIT,   32                      # loc rot scale at the start (9 floats)
.equ RB_VEL,    68                      # its velocity at the start (3 floats)
.equ RBF_GRP,   4                       # RB_FLAGS bits 4-7: its group (0-15);
.equ RBF_IGN,   16                      #  16-31: the groups it does not meet
.equ JT_TYPE,   0                       # 1 fixed, 2 hinge, 3 point, 4 slider
.equ JT_A,      4                       # object uids (B 0: the world)
.equ JT_B,      8
.equ JT_PIV,    16                      # the pivot (world, at the start)
.equ JT_AXIS,   28                      # hinge, slider: its axis (world)
.equ JT_BRK,    40                      # the force that breaks it (0: none)
.equ JT_LO,     44                      # limits (hinge: radians; slider: m)
.equ JT_HI,     48
.equ JT_MSPD,   52                      # a motor: its speed (rad/s, m/s),
.equ JT_MFOR,   56                      #  its torque / force at most
.equ JT_FLG,    60                      # 1 limited, 2 a motor
# a body (runtime)
.equ BD_POS,    0                       # centre of mass (world)
.equ BD_Q,      16                      # orientation (x y z w)
.equ BD_V,      32
.equ BD_W,      48
.equ BD_IIL,    64                      # inverse inertia (body axes)
.equ BD_IIW,    80                      # inverse inertia (world), rows
.equ BD_R,      128                     # rotation, rows
.equ BD_COM,    176                     # centre of mass in the object (scaled)
.equ BD_MIN,    192                     # bounds
.equ BD_MAX,    208
.equ BD_IM,     224                     # inverse mass
.equ BD_FRIC,   228
.equ BD_REST,   232
.equ BD_TYPE,   236                     # 1 moving, 2 static
.equ BD_SLEEP,  240                     # seconds at rest
.equ BD_ASLEEP, 244
.equ BD_P0,     248                     # its parts
.equ BD_NP,     252
.equ BD_OBJ,    256
.equ BD_ISL,    264
.equ BD_DAMP,   268
.equ BD_JOINT,  272                     # in a joint (no contact with its partner)
.equ BD_INST,   276                     # an instance: its index + 1 (0: an object)
.equ BD_BVH,    280                     # a mesh: its triangles' tree (root + 1)
.equ BD_GRP,    284                     # its group's bit; | the groups it does
                                        #  not meet << 16
.equ BD_SCL,    288                     # its scale (instances: their own)
.equ BD_PP,     304                     # where the step began: its position,
.equ BD_PQ,     320                     #  orientation (continuous collision)
.equ BD_SZ,     336
# a part (collide.s)
.equ PT_TYPE,   0
.equ PT_NV,     4
.equ PT_VERTS,  8
.equ PT_RAD,    16
.equ PT_BODY,   20
.equ PT_HALF,   32
.equ PT_OFF,    48
.equ PT_FLG,    24                      # 1: a mesh's triangle; | its edges that
                                        #  are active (bits 1-3: 0-1, 1-2, 2-0)
.equ PT_TW,     28                      # a triangle: its corners' slot (world)
.equ PT_SZ,     64
.equ PT_MAXB,   16                      # parts a body
.equ BV_SZ,     32                      # a tree node: min, left (| 1 << 31: a
                                        #  leaf, its first); max, right (a
                                        #  leaf: how many)
.equ HULL_MAX,  64                      # points a hull part
# a proxy (collide.s)
.equ PX_C,      48
.equ PX_PART,   64
.equ PX_SZ,     80
.equ CR_SEP,    0
.equ CR_PA,     16
.equ CR_PB,     32
.equ CR_N,      48
# a manifold
.equ MF_A,      0                       # bodies,
.equ MF_B,      4
.equ MF_PA,     8                       #  parts
.equ MF_PB,     12
.equ MF_N,      16                      # points
.equ MF_KEEP,   20                      # the step it was last seen in
.equ MF_FRIC,   24
.equ MF_REST,   28
.equ MF_NRM,    32                      # normal (A to B)
.equ MF_T1,     48
.equ MF_T2,     64
.equ MF_DIR,    80                      # its points solved forward / back
.equ MF_PTS,    96
.equ CP_LA,     0                       # anchors (body axes, from its centre)
.equ CP_LB,     16
.equ CP_RA,     32                      # (world, from the centres)
.equ CP_RB,     48
.equ CP_SEP,    64
.equ CP_JN,     68                      # impulses so far
.equ CP_JT1,    72
.equ CP_JT2,    76
.equ CP_MN,     80                      # effective masses
.equ CP_MT1,    84
.equ CP_MT2,    88
.equ CP_BIAS,   92
.equ CP_WA,     96                      # where it is on A (world)
.equ CP_C0,     112                     # gap - n . (pB - pA) at the step's start
.equ CP_VN0,    116                     # normal speed then (restitution)
.equ CP_JMAX,   120                     # the largest normal impulse this step
.equ CP_RN,     128                     # its rows (normal, the tangents), each
.equ CP_RT1,    192                     #  rA x d, rB x d, IA (rA x d),
.equ CP_RT2,    256                     #  IB (rB x d) for the step
.equ RW_AX,     0
.equ RW_BX,     16
.equ RW_IA,     32
.equ RW_IB,     48
.equ CP_SZ,     320
.equ MF_SZ,     MF_PTS + 4*CP_SZ
.equ MX_A,      0                       # a manifold's keys, dense (what the
.equ MX_B,      4                       #  steps scan): its bodies, parts,
.equ MX_PA,     8                       #  the step it was last seen in, its
.equ MX_PB,     12                      #  points
.equ MX_KEEP,   16
.equ MX_N,      20
.equ MX_SZ,     32
# a joint (runtime)
.equ JR_A,      0
.equ JR_B,      4
.equ JR_TYPE,   8
.equ JR_LA,     16
.equ JR_LB,     32
.equ JR_AXA,    48
.equ JR_AXB,    64
.equ JR_Q0,     80                      # B's orientation relative to A at the start
.equ JR_RA,     96
.equ JR_RB,     112
.equ JR_ERR,    128                     # angular error (fixed) / axes (hinge)
.equ JR_P,      144
.equ JR_Q,      160
.equ JR_C,      176                     # pB - pA (world)
.equ JR_BRK,    192                     # (the settings above, as given)
.equ JR_LO,     196
.equ JR_HI,     200
.equ JR_MS,     204
.equ JR_MF,     208
.equ JR_FL,     212                     # 1 limited, 2 a motor, 4 broken
.equ JR_MACC,   220                     # the motor's this substep
.equ JR_AW,     224                     # its axis (world), this substep
.equ JR_POS,    240                     # where it is: the hinge's angle, the
                                        #  slider's distance
.equ JR_IMP,    244                     # the impulse it took this step (by row)
.equ JR_SZ,     256
.equ MARGIN,    0                       # (as floats in rodata)
.equ RBI_OBJ,   0                       # an object whose instances are bodies:
.equ RBI_OUT,   8                       #  the mesh shown while they move (its
.equ RBI_WINV,  16                      #  own instance block), the object's
.equ RBI_SZ,    64                      #  inverse matrix
.equ RBI_MAX,   64
.equ RB_CVER,   0x52425632              # the cache's records ("RBV2")
.equ IB_N_,     4                       # (inst.s: an instance block)
.equ IB_NP_,    8
.equ IB_PROTO_, 24
.equ IB_DATA_,  128
.equ ST_FMF,    0                       # a stage: the fn for manifolds (or
.equ ST_FJR,    8                       #  bodies), for joints,
.equ ST_BASE,   16                      #  its items (constraint ids / body
.equ ST_N,      24                      #  indices), how many,
.equ ST_GR,     28                      #  a block's size,
.equ ST_KIND,   32                      #  0 constraints, 1 bodies
.equ ST_SZ,     48
.equ ST_MAX,    8192
.equ MAP_NORES, 0x4022
.equ AN_START,  24                      # (anim.s)
.equ AN_FPS,    32

.macro DOT3 d, s
    dpps    \d, \s, 0x71
.endm
.macro CROSS d, a, b, t
    movaps  \d, \b
    shufps  \d, \d, 0xC9
    mulps   \d, \a
    movaps  \t, \a
    shufps  \t, \t, 0xC9
    mulps   \t, \b
    subps   \d, \t
    shufps  \d, \d, 0xC9
.endm
# d = M v (M: rows at m; d, t1, t2 registers, v a register)
.macro MV3 d, m, v, t1, t2
    movaps  \d, [\m]
    DOT3    \d, \v
    movaps  \t1, [\m+16]
    DOT3    \t1, \v
    movaps  \t2, [\m+32]
    DOT3    \t2, \v
    unpcklps \d, \t1
    movlhps \d, \t2
.endm
# d = M^T v (rows at m)
.macro MTV3 d, m, v, t1
    movaps  \d, \v
    shufps  \d, \d, 0x00
    mulps   \d, [\m]
    movaps  \t1, \v
    shufps  \t1, \t1, 0x55
    mulps   \t1, [\m+16]
    addps   \d, \t1
    movaps  \t1, \v
    shufps  \t1, \t1, 0xAA
    mulps   \t1, [\m+32]
    addps   \d, \t1
.endm

.section .rodata
.align 16
rx_xyz:         .long -1, -1, -1, 0
rx_abs:         .long 0x7fffffff, 0x7fffffff, 0x7fffffff, 0
rx_sign:        .long 0x80000000, 0x80000000, 0x80000000, 0
rx_one4:        .float 1, 1, 1, 0
rx_half4:       .float 0.5, 0.5, 0.5, 0
rx_grav:        .float 0, -9.81, 0, 0
rx_qid:         .float 0, 0, 0, 1
rx_wmask:       .long 0, 0, 0, -1
rx_negy:        .long 0, 0x80000000, 0, 0
rx_negz:        .long 0, 0, 0x80000000, 0
rx_sign4:       .long 0x80000000, 0x80000000, 0x80000000, 0x80000000
rx_xy:          .long -1, -1, 0, 0
rx_yz:          .long 0, -1, -1, 0
rx_tiny4:       .float 1e-9, 1e-9, 1e-9, 1
rx_ident:       .float 1, 0, 0, 0,  0, 1, 0, 0,  0, 0, 1, 0
rx_1e4:         .float 10000, 10000, 10000, 0
rx_marg4:       .float 0.04, 0.04, 0.04, 0
rx_big4:        .float 1e30, 1e30, 1e30, 0
rx_nbig4:       .float -1e30, -1e30, -1e30, 0
rb_dirs:
                .float 0.176085, 0.984375, 0.000000, 0,  -0.223111, 0.953125, 0.204388, 0
                .float 0.033876, 0.921875, -0.386004, 0,  0.276681, 0.890625, 0.360881, 0
                .float -0.503529, 0.859375, -0.089067, 0,  0.472962, 0.828125, -0.300859, 0
                .float -0.156838, 0.796875, 0.583431, 0,  -0.296496, 0.765625, -0.570884, 0
                .float 0.637559, 0.734375, 0.232835, 0,  -0.657271, 0.703125, 0.271312, 0
                .float 0.313928, 0.671875, -0.670845, 0,  0.229806, 0.640625, 0.732659, 0
                .float -0.686011, 0.609375, -0.397557, 0,  0.796917, 0.578125, -0.175200, 0
                .float -0.481507, 0.546875, 0.684894, 0,  -0.110110, 0.515625, -0.849710, 0
                .float 0.668961, 0.484375, 0.563801, 0,  -0.890686, 0.453125, 0.036833, 0
                .float 0.642663, 0.421875, -0.639536, 0,  -0.042522, 0.390625, 0.919567, 0
                .float -0.597905, 0.359375, -0.716491, 0,  0.936198, 0.328125, 0.125964, 0
                .float -0.783851, 0.296875, 0.545383, 0,  0.211597, 0.265625, -0.940569, 0
                .float 0.483333, 0.234375, 0.843480, 0,  -0.932832, 0.203125, -0.297599, 0
                .float 0.894282, 0.171875, -0.413181, 0,  -0.382225, 0.140625, 0.913307, 0
                .float -0.336422, 0.109375, -0.935338, 0,  0.882484, 0.078125, 0.463809, 0
                .float -0.965907, 0.046875, 0.254610, 0,  0.540772, 0.015625, -0.841024, 0
                .float 0.169355, -0.015625, 0.985431, 0,  -0.789754, -0.046875, -0.611630, 0
                .float 0.993540, -0.078125, -0.082313, 0,  -0.675005, -0.109375, 0.729661, 0
                .float 0.004830, -0.140625, -0.990051, 0,  0.661887, -0.171875, 0.729633, 0
                .float -0.974974, -0.203125, -0.090360, 0,  0.774372, -0.234375, -0.587721, 0
                .float -0.172554, -0.265625, 0.948509, 0,  -0.508594, -0.296875, -0.808206, 0
                .float 0.911040, -0.328125, 0.249678, 0,  -0.830249, -0.359375, 0.426070, 0
                .float 0.319999, -0.390625, -0.863141, 0,  0.341847, -0.421875, 0.839739, 0
                .float -0.805561, -0.453125, -0.381771, 0,  0.836028, -0.484375, -0.257756, 0
                .float -0.433224, -0.515625, 0.739221, 0,  -0.175775, -0.546875, -0.818554, 0
                .float 0.665199, -0.578125, 0.472526, 0,  -0.786795, -0.609375, 0.098057, 0
                .float 0.497699, -0.640625, -0.584718, 0,  0.026992, -0.671875, 0.740173, 0
                .float -0.499107, -0.703125, -0.506465, 0,  0.677858, -0.734375, 0.034659, 0
                .float -0.495910, -0.765625, 0.409746, 0,  0.083481, -0.796875, -0.598349, 0
                .float 0.317896, -0.828125, 0.461683, 0,  -0.498324, -0.859375, -0.114663, 0
                .float 0.395651, -0.890625, -0.224160, 0,  -0.119570, -0.921875, 0.368578, 0
                .float -0.125566, -0.953125, -0.275292, 0,  0.162100, -0.984375, 0.068771, 0
rx_one:         .float 1.0
rx_half:        .float 0.5
rx_quarter:     .float 0.25
rx_two:         .float 2.0
rx_tiny:        .float 1.0e-9
rx_tiny2:       .float 1e-12
rx_cos5:        .float 0.9962                # (5 degrees)
rx_small:       .float 1.0e-6
rx_margin:      .float 0.02                 # contacts begin this far apart
rx_keep:        .float 0.04                 # points kept this far apart,
rx_drift2:      .float 0.0004               #  sliding less than 2 cm
rx_same2:       .float 0.0004               # a new point this near an old one
rx_slop:        .float 0.002
rx_ccd_tol:     .float 0.005                # continuous collision: touching,
rx_ccd_back:    .float 0.02                 #  and how far short (of the step)
rx_gmin:        .float 0.05                 # the grid's smallest cell
rx_pushmax:     .float 1.0
rx_hzmax:       .float 60.0                 # soft contacts: at most this stiff,
rx_zeta:        .float 10.0                 #  damped this much
rx_twopi:       .float 6.2831853
rx_beta:        .float 0.2
rx_bounce:      .float 1.0                  # restitution above 1 m/s
rx_rest2:       .float 0.0025               # at rest under 5 cm/s
rx_sleep:       .float 0.5                  # seconds at rest to sleep
rx_tilt:        .float 0.02                 # radians (more points)
rx_adamp:       .float 0.05                 # angular damping
rx_ldamp:       .float 0.0
rx_fric:        .float 0.5
rx_thin:        .float 0.05                 # a passive box thinner than this
rx_thick:       .float 0.25                 #  is this deep below its top
rx_third:       .float 0.33333334
rx_fifth2:      .float 0.4
.align 8
rx_1e6d:        .double 1000000.0
rx_1000:        .float 1000.0
rx_24:          .float 24.0
rx_conc:        .float 0.05                 # compound: a part's hollowness / size
rx_0577:        .float 0.57735

.section .bss
.align 16
rb_on:          .skip 4                 # a simulation exists
rb_islive:      .skip 4                 # play mode: no cache (logic changes it)
rb_npend:       .skip 4                 # impulses before the bodies are made
.align 16
rb_pend:        .skip 16*32             # (object, then the impulse)
rb_nb:          .skip 4                 # bodies (the world last)
rb_npt:         .skip 4
rb_nvx:         .skip 4
rb_nmf:         .skip 4
rb_capmf:       .skip 4
rb_npr:         .skip 4
rb_njr:         .skip 4
rb_nisl:        .skip 4
rb_hmask:       .skip 4
rb_gmask:       .skip 4                 # buckets - 1
rb_gsh:         .skip 4                 # 64 - log2 buckets
rb_gn:          .skip 4                 # entries this step
rb_gnbig:       .skip 4
rb_npair:       .skip 4
rb_nbvh:        .skip 4                 # (nodes, triangles placed)
rb_nbvi:        .skip 4
rb_xparts:      .skip 4                 # meshes' triangles in all
rb_cappair:     .skip 4
rb_gcs:         .skip 4                 # the cell's size,
rb_ginv:        .skip 4                 #  1 / it
rb_stepno:      .skip 4
rb_iter:        .skip 4
rb_base:        .skip 8                 # the mapping, its size
rb_bytes:       .skip 8
rb_bd:          .skip 8
rb_pt:          .skip 8
rb_vx:          .skip 8
rb_mf:          .skip 8
rb_mx:          .skip 8                 # each manifold's keys, dense (MX_*)
rb_hs:          .skip 8
rb_ord:         .skip 8
rb_gent:        .skip 8                 # the grid: entries (cell, body),
rb_gsrt:        .skip 8                 #  sorted by bucket,
rb_gtab:        .skip 8                 #  the buckets' starts,
rb_gbig:        .skip 8                 #  the bodies too big for it
rb_pairs:       .skip 8                 # pairs of bodies whose bounds meet
rb_gcc:         .skip 8                 # pairs found in each chunk of buckets
rb_bcon:        .skip 8                 # a big island: its constraints,
rb_bsrt:        .skip 8                 #  by colour,
rb_bcol:        .skip 8                 #  their colours,
rb_bmask:       .skip 8                 #  the colours at each body (64 bits)
rb_bcst:        .skip 8                 #  each colour's start (66)
rb_bvh:         .skip 8                 # meshes' trees: nodes,
rb_bvi:         .skip 8                 #  their triangles (parts), in order,
rb_bvb:         .skip 8                 #  those triangles' bounds
rb_tvw:         .skip 8                 #  their corners (world, 3 vec4)
rb_stg:         .skip 8                 # a big island's step: its stages,
rb_scnt:        .skip 8                 #  each one's claimed / done blocks
rb_nstg:        .skip 4
rb_islj:        .skip 4                 #  (it has joints)
rb_par:         .skip 8
rb_ib:          .skip 8                 # islands: bodies, manifolds, joints
rb_imf:         .skip 8
rb_ij:          .skip 8
rb_isb:         .skip 8                 #  (starts: nb + 1 each)
rb_ism:         .skip 8
rb_isj:         .skip 8
rb_iaw:         .skip 8                 #  awake
rb_jr:          .skip 8
rb_hash:        .skip 8                 # the settings it was made from
rb_frame0:      .skip 4                 # the start frame
rb_fnow:        .skip 4                 # the frame it is at
rb_time:        .skip 4                 # seconds simulated
rb_dt:          .skip 4
rb_h:           .skip 4                 # a substep
rb_nsub:        .skip 4
rb_brate:       .skip 4                 # soft contacts: bias rate,
rb_mscale:      .skip 4                 #  mass scale,
rb_iscale:      .skip 4                 #  impulse scale
rb_brate_s:     .skip 4                 # against a static body: twice as
rb_mscale_s:    .skip 4                 #  stiff (it carries the most)
rb_iscale_s:    .skip 4
rb_ms:          .skip 4                 # the last frame's simulation time
rb_busy:        .skip 4
rb_noinst:      .skip 4                 # (obj_eval: the source, not ours)
rb_mffull:      .skip 4                 # pairs that found no room
rb_nbroken:     .skip 4                 # joints broken this run
rbi_n:          .skip 4
.align 16
rbi_tab:        .skip RBI_SZ*RBI_MAX
.align 8
rb_tns:         .skip 8*6               # time in each part of the steps (ns):
                                        #  broad phase, narrow, islands,
                                        #  solve, the hash, compacting
.align 16
rb_g:           .skip 16                # gravity
rb_tmp:         .skip 64
rb_tmp2:        .skip 64
.text

# -----------------------------------------------------------------------------
# Rotations
# -----------------------------------------------------------------------------
# q_rows(rdi=quaternion, rsi=rows out) - R from q (x y z w)
q_rows:
    movss   xmm0, [rdi]                 # x
    movss   xmm1, [rdi+4]               # y
    movss   xmm2, [rdi+8]               # z
    movss   xmm3, [rdi+12]              # w
    movss   xmm4, xmm0                  # xx yy zz
    mulss   xmm4, xmm0
    movss   xmm5, xmm1
    mulss   xmm5, xmm1
    movss   xmm6, xmm2
    mulss   xmm6, xmm2
    movss   xmm7, [rip+rx_one]          # row 0: 1-2(yy+zz), 2(xy-wz), 2(xz+wy)
    movss   xmm8, xmm5
    addss   xmm8, xmm6
    addss   xmm8, xmm8
    subss   xmm7, xmm8
    movss   [rsi], xmm7
    movss   xmm8, xmm0
    mulss   xmm8, xmm1
    movss   xmm9, xmm3
    mulss   xmm9, xmm2
    movss   xmm10, xmm8
    subss   xmm10, xmm9
    addss   xmm10, xmm10
    movss   [rsi+4], xmm10
    addss   xmm8, xmm9                  # (2(xy+wz): row 1 col 0)
    addss   xmm8, xmm8
    movss   [rsi+16], xmm8
    movss   xmm8, xmm0
    mulss   xmm8, xmm2
    movss   xmm9, xmm3
    mulss   xmm9, xmm1
    movss   xmm10, xmm8
    addss   xmm10, xmm9
    addss   xmm10, xmm10
    movss   [rsi+8], xmm10              # 2(xz+wy)
    subss   xmm8, xmm9
    addss   xmm8, xmm8
    movss   [rsi+32], xmm8              # 2(xz-wy): row 2 col 0
    movss   xmm7, [rip+rx_one]          # 1-2(xx+zz)
    movss   xmm8, xmm4
    addss   xmm8, xmm6
    addss   xmm8, xmm8
    subss   xmm7, xmm8
    movss   [rsi+20], xmm7
    movss   xmm8, xmm1                  # 2(yz-wx), 2(yz+wx)
    mulss   xmm8, xmm2
    movss   xmm9, xmm3
    mulss   xmm9, xmm0
    movss   xmm10, xmm8
    subss   xmm10, xmm9
    addss   xmm10, xmm10
    movss   [rsi+24], xmm10
    addss   xmm8, xmm9
    addss   xmm8, xmm8
    movss   [rsi+36], xmm8
    movss   xmm7, [rip+rx_one]          # 1-2(xx+yy)
    movss   xmm8, xmm4
    addss   xmm8, xmm5
    addss   xmm8, xmm8
    subss   xmm7, xmm8
    movss   [rsi+40], xmm7
    xor     eax, eax
    mov     [rsi+12], eax
    mov     [rsi+28], eax
    mov     [rsi+44], eax
    ret

# rows_q(rdi=rows (3x4), rsi=quaternion out) - Shepperd
rows_q:
    movss   xmm0, [rdi]                 # m00
    movss   xmm1, [rdi+20]              # m11
    movss   xmm2, [rdi+40]              # m22
    movss   xmm3, xmm0
    addss   xmm3, xmm1
    addss   xmm3, xmm2                  # trace
    xorps   xmm7, xmm7
    comiss  xmm3, xmm7
    jbe     2f
    addss   xmm3, [rip+rx_one]
    sqrtss  xmm3, xmm3
    addss   xmm3, xmm3                  # s
    movss   xmm4, xmm3
    mulss   xmm4, [rip+rx_quarter]
    movss   [rsi+12], xmm4              # w
    movss   xmm4, [rdi+36]              # (m21 - m12) / s
    subss   xmm4, [rdi+24]
    divss   xmm4, xmm3
    movss   [rsi], xmm4
    movss   xmm4, [rdi+8]               # (m02 - m20) / s
    subss   xmm4, [rdi+32]
    divss   xmm4, xmm3
    movss   [rsi+4], xmm4
    movss   xmm4, [rdi+16]              # (m10 - m01) / s
    subss   xmm4, [rdi+4]
    divss   xmm4, xmm3
    movss   [rsi+8], xmm4
    jmp     9f
2:  comiss  xmm0, xmm1
    jbe     4f
    comiss  xmm0, xmm2
    jbe     4f
    movss   xmm3, [rip+rx_one]          # x leads
    addss   xmm3, xmm0
    subss   xmm3, xmm1
    subss   xmm3, xmm2
    sqrtss  xmm3, xmm3
    addss   xmm3, xmm3
    movss   xmm4, xmm3
    mulss   xmm4, [rip+rx_quarter]
    movss   [rsi], xmm4
    movss   xmm4, [rdi+36]
    subss   xmm4, [rdi+24]
    divss   xmm4, xmm3
    movss   [rsi+12], xmm4
    movss   xmm4, [rdi+4]
    addss   xmm4, [rdi+16]
    divss   xmm4, xmm3
    movss   [rsi+4], xmm4
    movss   xmm4, [rdi+8]
    addss   xmm4, [rdi+32]
    divss   xmm4, xmm3
    movss   [rsi+8], xmm4
    jmp     9f
4:  comiss  xmm1, xmm2
    jbe     5f
    movss   xmm3, [rip+rx_one]          # y leads
    addss   xmm3, xmm1
    subss   xmm3, xmm0
    subss   xmm3, xmm2
    sqrtss  xmm3, xmm3
    addss   xmm3, xmm3
    movss   xmm4, xmm3
    mulss   xmm4, [rip+rx_quarter]
    movss   [rsi+4], xmm4
    movss   xmm4, [rdi+8]
    subss   xmm4, [rdi+32]
    divss   xmm4, xmm3
    movss   [rsi+12], xmm4
    movss   xmm4, [rdi+4]
    addss   xmm4, [rdi+16]
    divss   xmm4, xmm3
    movss   [rsi], xmm4
    movss   xmm4, [rdi+24]
    addss   xmm4, [rdi+36]
    divss   xmm4, xmm3
    movss   [rsi+8], xmm4
    jmp     9f
5:  movss   xmm3, [rip+rx_one]          # z leads
    addss   xmm3, xmm2
    subss   xmm3, xmm0
    subss   xmm3, xmm1
    sqrtss  xmm3, xmm3
    addss   xmm3, xmm3
    movss   xmm4, xmm3
    mulss   xmm4, [rip+rx_quarter]
    movss   [rsi+8], xmm4
    movss   xmm4, [rdi+16]
    subss   xmm4, [rdi+4]
    divss   xmm4, xmm3
    movss   [rsi+12], xmm4
    movss   xmm4, [rdi+8]
    addss   xmm4, [rdi+32]
    divss   xmm4, xmm3
    movss   [rsi], xmm4
    movss   xmm4, [rdi+24]
    addss   xmm4, [rdi+36]
    divss   xmm4, xmm3
    movss   [rsi+4], xmm4
9:  ret

# q_mul(xmm0=a, xmm1=b) -> xmm0 = a b (x y z w); xmm2-5 scratch
q_mul:
    # w = aw bw - av.bv; v = aw bv + bw av + av x bv
    movaps  xmm2, xmm0
    shufps  xmm2, xmm2, 0xFF            # aw
    mulps   xmm2, xmm1                  # aw b
    movaps  xmm3, xmm1
    shufps  xmm3, xmm3, 0xFF            # bw
    mulps   xmm3, xmm0                  # bw a
    addps   xmm2, xmm3                  # (w lane: 2 aw bw)
    movaps  xmm4, xmm0
    andps   xmm4, [rip+rx_xyz]
    movaps  xmm5, xmm1
    andps   xmm5, [rip+rx_xyz]
    CROSS   xmm3, xmm4, xmm5, xmm6
    addps   xmm2, xmm3
    DOT3    xmm4, xmm5                  # av . bv (lane 0)
    movaps  xmm5, xmm0
    shufps  xmm5, xmm5, 0xFF
    movaps  xmm6, xmm1
    shufps  xmm6, xmm6, 0xFF
    mulss   xmm5, xmm6
    subss   xmm5, xmm4                  # w
    andps   xmm2, [rip+rx_xyz]
    shufps  xmm5, xmm5, 0
    andps   xmm5, [rip+rx_wmask]
    orps    xmm2, xmm5
    movaps  xmm0, xmm2
    ret
# q_conj(xmm0) -> xmm0 (vector part negated)
q_conj:
    xorps   xmm0, [rip+rx_sign]
    ret

# body_update(rdi=body) - rotation rows, world inverse inertia, bounds
body_update:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    lea     rdi, [rbx+BD_Q]
    lea     rsi, [rbx+BD_R]
    call    q_rows
    # IIW = R diag(i) R^T: row i = sum_k R_ik i_k col_k
    movaps  xmm7, [rbx+BD_IIL]
    xor     ecx, ecx
1:  imul    edx, ecx, 16
    movaps  xmm0, [rbx+BD_R+rdx]        # row i of R, times i
    mulps   xmm0, xmm7
    MV3     xmm1, rbx+BD_R, xmm0, xmm2, xmm3   # R (R_i. * i)
    andps   xmm1, [rip+rx_xyz]
    movaps  [rbx+BD_IIW+rdx], xmm1
    inc     ecx
    cmp     ecx, 3
    jb      1b
    mov     rdi, rbx
    call    body_bounds
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# body_bounds(rdi=body) - BD_MIN / BD_MAX over its parts (with the margin)
body_bounds:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    movaps  xmm6, [rip+rx_big4]
    movaps  xmm7, [rip+rx_nbig4]
    movaps  xmm8, [rbx+BD_R]            # |R| rows
    andps   xmm8, [rip+rx_abs]
    movaps  xmm9, [rbx+BD_R+16]
    andps   xmm9, [rip+rx_abs]
    movaps  xmm10, [rbx+BD_R+32]
    andps   xmm10, [rip+rx_abs]
    mov     r12d, [rbx+BD_NP]
    mov     eax, [rbx+BD_P0]
    imul    r13, rax, PT_SZ
    add     r13, [rip+rb_pt]
1:  test    r12d, r12d
    jz      2f
    cmp     dword ptr [r13+PT_TYPE], 2  # a plane: without end
    jne     11f
    movaps  xmm6, [rip+rx_nbig4]
    movaps  xmm7, [rip+rx_big4]
    jmp     2f
11: movaps  xmm0, [r13+PT_OFF]          # centre = P + R off
    MV3     xmm1, rbx+BD_R, xmm0, xmm2, xmm3
    addps   xmm1, [rbx+BD_POS]
    movss   xmm4, [r13+PT_RAD]          # extent = |R| (half + r)
    shufps  xmm4, xmm4, 0
    andps   xmm4, [rip+rx_xyz]
    addps   xmm4, [r13+PT_HALF]
    movaps  xmm2, xmm8
    DOT3    xmm2, xmm4
    movaps  xmm3, xmm9
    DOT3    xmm3, xmm4
    movaps  xmm5, xmm10
    DOT3    xmm5, xmm4
    unpcklps xmm2, xmm3
    movlhps xmm2, xmm5
    addps   xmm2, [rip+rx_marg4]
    movaps  xmm3, xmm1
    subps   xmm3, xmm2
    minps   xmm6, xmm3
    addps   xmm1, xmm2
    maxps   xmm7, xmm1
    add     r13, PT_SZ
    dec     r12d
    jmp     1b
2:  movaps  xmm0, [rbx+BD_V]            # and how far it goes in a step
    andps   xmm0, [rip+rx_abs]          #  (fast ones are found in time)
    movss   xmm1, [rip+rb_dt]
    shufps  xmm1, xmm1, 0
    mulps   xmm0, xmm1
    andps   xmm0, [rip+rx_xyz]
    subps   xmm6, xmm0
    addps   xmm7, xmm0
    movaps  [rbx+BD_MIN], xmm6
    movaps  [rbx+BD_MAX], xmm7
    pop     r13
    pop     r12
    pop     rbx
    ret

# rb_body(eax=index) -> rax = the body
.macro BODY reg, idx
    imul    \reg, \idx, BD_SZ
    add     \reg, [rip+rb_bd]
.endm

# -----------------------------------------------------------------------------
# Building the world
# -----------------------------------------------------------------------------
# rb_reserve(rsi=bytes) -> rax = zeroed address space (pages on use), or 0
rb_reserve:
    xor     edi, edi
    mov     edx, PROT_RW
    mov     r10d, MAP_NORES
    mov     r8, -1
    xor     r9d, r9d
    mov     eax, SYS_MMAP
    syscall
    cmp     rax, -4096
    jb      1f
    xor     eax, eax
1:  ret

# rb_free - no simulation
rb_free:
    call    rbi_drop
    cmp     dword ptr [rip+rb_on], 0
    je      9f
    mov     dword ptr [rip+rb_on], 0
    mov     rdi, [rip+rb_base]
    mov     rsi, [rip+rb_bytes]
    mov     eax, SYS_MUNMAP
    syscall
9:  ret

# rb_entry_obj(rdi=entry) -> rax = its object when it can be a body, or 0
rb_entry_obj:
    sub     rsp, 8
    cmp     dword ptr [rdi+RB_TYPE], 0
    je      8f
    mov     edi, [rdi+RB_UID]
    call    obj_by_uid
    test    rax, rax
    jz      9f
    cmp     dword ptr [rax+OB_TYPE], OT_MESH
    jne     8f
    cmp     qword ptr [rax+OB_MESH], 0
    jne     9f
8:  xor     eax, eax
9:  add     rsp, 8
    ret

# rb_restore - objects back where they were at the start; the start forgotten
rb_restore:
    push    rbx
    push    r12
    push    r13
    mov     rbx, [rip+an_cur]
    test    rbx, rbx
    jz      9f
    xor     r12d, r12d
1:  cmp     r12d, [rbx+AN_NRB_]
    jae     9f
    imul    r13, r12, RB_SZ_
    lea     r13, [rbx+AN_RB_+r13]
    test    dword ptr [r13+RB_FLAGS], 1
    jz      2f
    and     dword ptr [r13+RB_FLAGS], ~1
    mov     rdi, r13
    call    rb_entry_obj
    test    rax, rax
    jz      2f
    lea     rdi, [rax+OB_LOC]
    lea     rsi, [r13+RB_INIT]
    mov     ecx, 36
    rep     movsb
    mov     dword ptr [rip+dirty], 1
2:  inc     r12d
    jmp     1b
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# rb_build - bodies, parts, joints from the settings and the objects
rb_build:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    and     rsp, -16
    sub     rsp, 64
    call    rb_free
    mov     dword ptr [rip+rb_noinst], 1    # (the meshes as made, not moved)
    mov     rbx, [rip+an_cur]
    xor     r12d, r12d                  # bodies, the largest mesh
    xor     r13d, r13d
    xor     r14d, r14d                  # (its vertices, triangles)
    mov     dword ptr [rsp], 0
    mov     dword ptr [rip+rb_xparts], 0
1:  cmp     r12d, [rbx+AN_NRB_]
    jae     2f
    imul    rdi, r12, RB_SZ_
    lea     rdi, [rbx+AN_RB_+rdi]
    mov     [rsp+16], rdi
    call    rb_entry_obj
    test    rax, rax
    jz      11f
    mov     rdi, rax
    call    obj_eval
    test    rax, rax
    jz      11f
    mov     rdi, [rsp+16]
    test    dword ptr [rdi+RB_FLAGS], 2
    jz      10f
    mov     rdi, [rax+ME_INST]          # its instances: one body each; their
    test    rdi, rdi                    #  prototypes' sizes
    jz      11f
    add     r13d, [rdi+IB_N_]
    mov     [rsp+24], rdi
    xor     ecx, ecx
101:cmp     ecx, [rdi+IB_NP_]
    jae     11f
    mov     rax, [rdi+IB_PROTO_+rcx*8]
    mov     edx, [rax+ME_NVERTS]
    cmp     edx, r14d
    cmova   r14d, edx
    mov     edx, [rax+ME_NTRIS]
    cmp     edx, [rsp]
    jbe     102f
    mov     [rsp], edx
102:inc     ecx
    jmp     101b
10: inc     r13d
    mov     rdi, [rsp+16]               # a mesh collider: its triangles
    cmp     dword ptr [rdi+RB_SHAPE], 5
    jne     103f
    cmp     dword ptr [rdi+RB_TYPE], 2
    jne     103f
    mov     ecx, [rax+ME_NTRIS]
    add     [rip+rb_xparts], ecx
103:mov     ecx, [rax+ME_NVERTS]
    cmp     ecx, r14d
    cmova   r14d, ecx
    mov     ecx, [rax+ME_NTRIS]
    cmp     ecx, [rsp]
    jbe     11f
    mov     [rsp], ecx
11: inc     r12d
    jmp     1b
2:  lea     eax, [r13+1]                # (the world, a body too)
    mov     [rip+rb_nb], eax
    mov     [rsp+8], r14d
    # the layout: offsets from the base, in rb_* first
    mov     r15d, eax                   # nb
    xor     r12, r12                    # running size
    lea     rdi, [rip+rb_bd]
    imul    rsi, r15, BD_SZ
    call    rb_lay
    lea     rdi, [rip+rb_pt]
    imul    rsi, r15, PT_SZ*PT_MAXB
    mov     eax, [rip+rb_xparts]        # (and meshes' triangles)
    imul    rax, rax, PT_SZ
    add     rsi, rax
    call    rb_lay
    lea     rdi, [rip+rb_bvh]           # meshes' trees
    mov     esi, [rip+rb_xparts]
    lea     rsi, [rsi*2+64]
    shl     rsi, 5
    call    rb_lay
    lea     rdi, [rip+rb_bvi]
    mov     esi, [rip+rb_xparts]
    lea     rsi, [rsi*4+64]
    call    rb_lay
    lea     rdi, [rip+rb_bvb]
    mov     esi, [rip+rb_xparts]
    add     esi, 16
    shl     rsi, 5
    call    rb_lay
    lea     rdi, [rip+rb_tvw]
    mov     esi, [rip+rb_xparts]
    add     esi, 16
    imul    rsi, rsi, 48
    call    rb_lay
    lea     rdi, [rip+rb_vx]            # hulls, then scratch for a mesh
    imul    rsi, r15, PT_MAXB*HULL_MAX*16
    mov     eax, [rip+rb_xparts]        # (and meshes' triangles' corners)
    imul    rax, rax, 48
    add     rsi, rax
    mov     eax, [rsp+8]
    imul    rax, rax, 48
    add     rsi, rax
    mov     eax, [rsp]
    imul    rax, rax, 16
    add     rsi, rax
    add     rsi, 65536
    call    rb_lay
    imul    eax, r15d, 64               # manifolds: 64 a body (packed small
    add     eax, 4096                   #  ones meet many; address space,
    cmp     dword ptr [rip+rb_xparts], 0    #  pages taken as used), 128 more
    je      21f                         #  with a mesh collider (a body on a
    imul    ecx, r15d, 128              #  fine mesh meets its triangles)
    add     eax, ecx
21:
    mov     [rip+rb_capmf], eax
    lea     rdi, [rip+rb_mf]
    imul    rsi, rax, MF_SZ
    call    rb_lay
    lea     rdi, [rip+rb_mx]
    mov     esi, [rip+rb_capmf]
    shl     rsi, 5
    call    rb_lay
    mov     eax, [rip+rb_capmf]         # the hash (kept: entries added when
                                        #  made, taken out when they go): a
                                        #  power of two >= 4 x
    shl     eax, 2
    bsr     ecx, eax
    inc     ecx
    mov     eax, 1
    shl     eax, cl
    lea     ecx, [rax-1]
    mov     [rip+rb_hmask], ecx
    lea     rdi, [rip+rb_hs]
    mov     esi, eax
    shl     rsi, 2
    call    rb_lay
    lea     rdi, [rip+rb_ord]
    lea     rsi, [r15*4+16]
    call    rb_lay
    imul    rsi, r15, 27*16             # the grid: a body in at most 27 cells
    add     rsi, 1024
    lea     rdi, [rip+rb_gent]
    push    rsi
    push    rsi
    call    rb_lay
    pop     rsi
    pop     rsi
    lea     rdi, [rip+rb_gsrt]
    call    rb_lay
    imul    eax, r15d, 16               # buckets: a power of two >= 16 nb
    or      eax, 1023
    bsr     ecx, eax
    inc     ecx
    mov     eax, 1
    shl     eax, cl
    lea     edx, [rax-1]
    mov     [rip+rb_gmask], edx
    mov     edx, 64
    sub     edx, ecx
    mov     [rip+rb_gsh], edx
    lea     rsi, [rax*4+16]
    lea     rdi, [rip+rb_gtab]
    call    rb_lay
    lea     rdi, [rip+rb_gbig]
    lea     rsi, [r15*4+16]
    call    rb_lay
    imul    eax, r15d, 64               # pairs: 64 a body (more: at once)
    add     eax, 1024
    mov     [rip+rb_cappair], eax
    lea     rdi, [rip+rb_pairs]
    lea     rsi, [rax*8]
    call    rb_lay
    mov     esi, [rip+rb_gmask]         # a count for each 256 buckets
    shr     esi, 8
    add     esi, 2
    shl     esi, 2
    lea     rdi, [rip+rb_gcc]
    call    rb_lay
    mov     esi, [rip+rb_capmf]         # big islands: constraints, sorted,
    add     esi, JT_MAX_+16             #  colours
    shl     esi, 2
    push    rsi
    push    rsi
    lea     rdi, [rip+rb_bcon]
    call    rb_lay
    mov     rsi, [rsp]
    lea     rdi, [rip+rb_bsrt]
    call    rb_lay
    pop     rsi
    pop     rsi
    lea     rdi, [rip+rb_bcol]
    call    rb_lay
    lea     rsi, [r15*8+16]
    lea     rdi, [rip+rb_bmask]
    call    rb_lay
    lea     rdi, [rip+rb_bcst]
    mov     esi, 70*4
    call    rb_lay
    lea     rdi, [rip+rb_stg]           # stages (at most ST_MAX a step)
    mov     esi, ST_MAX*ST_SZ
    call    rb_lay
    lea     rdi, [rip+rb_scnt]
    mov     esi, ST_MAX*128
    call    rb_lay
    lea     rdi, [rip+rb_par]
    lea     rsi, [r15*4+16]
    call    rb_lay
    lea     rdi, [rip+rb_ib]
    lea     rsi, [r15*4+16]
    call    rb_lay
    lea     rdi, [rip+rb_imf]
    mov     esi, [rip+rb_capmf]
    shl     rsi, 2
    call    rb_lay
    lea     rdi, [rip+rb_ij]
    mov     esi, JT_MAX_*4
    call    rb_lay
    lea     rdi, [rip+rb_isb]
    lea     rsi, [r15*4+16]
    call    rb_lay
    lea     rdi, [rip+rb_ism]
    lea     rsi, [r15*4+16]
    call    rb_lay
    lea     rdi, [rip+rb_isj]
    lea     rsi, [r15*4+16]
    call    rb_lay
    lea     rdi, [rip+rb_iaw]
    lea     rsi, [r15*4+16]
    call    rb_lay
    lea     rdi, [rip+rb_jr]
    mov     esi, JT_MAX_*JR_SZ
    call    rb_lay
    mov     rsi, r12
    mov     [rip+rb_bytes], rsi
    call    rb_reserve
    test    rax, rax
    jz      .Lbd_fail
    mov     [rip+rb_base], rax
    lea     rcx, [rip+rb_bd]            # offsets -> addresses
    lea     rdx, [rip+rb_jr]
3:  add     [rcx], rax
    add     rcx, 8
    cmp     rcx, rdx
    jbe     3b
    mov     dword ptr [rip+rb_on], 1
    xor     eax, eax
    mov     [rip+rb_mffull], eax
    mov     [rip+rb_nbroken], eax
    lea     rdi, [rip+rb_tns]
    mov     [rdi], rax
    mov     [rdi+8], rax
    mov     [rdi+16], rax
    mov     [rdi+24], rax
    mov     [rip+rb_npt], eax
    mov     [rip+rb_nvx], eax
    mov     [rip+rb_nmf], eax
    mov     [rip+rb_nbvh], eax
    mov     [rip+rb_nbvi], eax
    mov     [rip+rb_njr], eax
    mov     [rip+rb_stepno], eax
    # the bodies
    xor     r12d, r12d                  # entry
    xor     r13d, r13d                  # body
4:  cmp     r12d, [rbx+AN_NRB_]
    jae     5f
    imul    r14, r12, RB_SZ_
    lea     r14, [rbx+AN_RB_+r14]
    mov     rdi, r14
    call    rb_entry_obj
    test    rax, rax
    jz      41f
    mov     r15, rax
    test    dword ptr [r14+RB_FLAGS], 1 # the start: kept, or now
    jz      42f
    lea     rdi, [r15+OB_LOC]
    lea     rsi, [r14+RB_INIT]
    mov     ecx, 36
    rep     movsb
    jmp     43f
42: lea     rsi, [r15+OB_LOC]
    lea     rdi, [r14+RB_INIT]
    mov     ecx, 36
    rep     movsb
    or      dword ptr [r14+RB_FLAGS], 1
43: test    dword ptr [r14+RB_FLAGS], 2
    jz      44f
    mov     edi, r13d                   # its instances
    mov     rsi, r14
    mov     rdx, r15
    call    inst_bodies
    add     r13d, eax
    jmp     41f
44: mov     edi, r13d
    mov     rsi, r14
    mov     rdx, r15
    call    make_body
    inc     r13d
41: inc     r12d
    jmp     4b
5:  BODY    rax, r13                    # the world: static, at the origin
    mov     dword ptr [rax+BD_TYPE], 2
    movaps  xmm0, [rip+rx_qid]
    movaps  [rax+BD_Q], xmm0
    mov     rdi, rax
    call    body_update
    call    make_joints
    mov     rax, [rip+rb_ord]           # the sweep's order
    xor     ecx, ecx
6:  cmp     ecx, [rip+rb_nb]
    jae     7f
    mov     [rax+rcx*4], ecx
    inc     ecx
    jmp     6b
7:  call    rb_settings
    jmp     .Lbd_out
.Lbd_fail:
    mov     dword ptr [rip+rb_on], 0
.Lbd_out:
    mov     dword ptr [rip+rb_noinst], 0
    lea     rsp, [rbp-40]
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret
# rb_lay(rdi=pointer slot, rsi=bytes; r12 = the size so far) - its offset
rb_lay:
    mov     [rdi], r12
    add     rsi, 63
    and     rsi, -64
    add     r12, rsi
    ret

# rb_gravity -> rax = the world's gravity (4 floats, w 0)
rb_gravity:
    sub     rsp, 8
    call    rb_settings
    lea     rax, [rip+rb_g]
    add     rsp, 8
    ret

# rb_settings - gravity, step, iterations from the world settings
rb_settings:
    mov     rax, [rip+an_cur]
    movaps  xmm0, [rip+rx_grav]
    mov     ecx, 120
    mov     edx, 10
    mov     r8d, 4
    test    rax, rax
    jz      2f
    cmp     dword ptr [rax+AN_RW_+RW_SUB], 0
    je      10f
    mov     r8d, [rax+AN_RW_+RW_SUB]
10:
    cmp     dword ptr [rax+AN_RW_+RW_SET], 0
    je      1f
    movups  xmm0, [rax+AN_RW_+RW_GRAV]
    andps   xmm0, [rip+rx_xyz]
1:  cmp     dword ptr [rax+AN_RW_+RW_RATE], 0
    je      11f
    mov     ecx, [rax+AN_RW_+RW_RATE]
11: cmp     dword ptr [rax+AN_RW_+RW_ITER], 0
    je      2f
    mov     edx, [rax+AN_RW_+RW_ITER]
2:  movaps  [rip+rb_g], xmm0
    mov     [rip+rb_nsub], r8d
    mov     eax, edx                    # iterations: spread over the substeps
    xor     edx, edx
    div     r8d
    cmp     eax, 1
    adc     eax, 0
    mov     [rip+rb_iter], eax
    cvtsi2ss xmm0, ecx
    movss   xmm1, [rip+rx_one]
    divss   xmm1, xmm0
    movss   [rip+rb_dt], xmm1
    cvtsi2ss xmm2, r8d
    divss   xmm1, xmm2
    movss   [rip+rb_h], xmm1            # h
    # soft contacts: w = 2 pi min(30, rate x substeps / 4), z = 10;
    #   a1 = 2z + hw, a2 = hw a1, a3 = 1 / (1 + a2): bias w / a1, mass a2 a3,
    #   impulse a3
    mulss   xmm0, xmm2
    mulss   xmm0, [rip+rx_quarter]
    minss   xmm0, [rip+rx_hzmax]
    mulss   xmm0, [rip+rx_twopi]        # w
    lea     rdi, [rip+rb_brate]
    movss   xmm8, xmm0                  # (rb_soft keeps xmm1, xmm8)
    call    rb_soft
    movss   xmm0, xmm8
    addss   xmm0, xmm0
    lea     rdi, [rip+rb_brate_s]
    jmp     rb_soft
# rb_soft(xmm0=w, xmm1=h, rdi=out: bias rate, mass scale, impulse scale)
rb_soft:
    movss   xmm3, xmm1
    mulss   xmm3, xmm0                  # hw
    movss   xmm4, [rip+rx_zeta]
    addss   xmm4, xmm4
    addss   xmm4, xmm3                  # a1
    movss   xmm5, xmm3
    mulss   xmm5, xmm4                  # a2
    movss   xmm6, [rip+rx_one]
    addss   xmm6, xmm5
    movss   xmm7, [rip+rx_one]
    divss   xmm7, xmm6                  # a3
    divss   xmm0, xmm4
    movss   [rdi], xmm0
    mulss   xmm5, xmm7
    movss   [rdi+4], xmm5
    movss   [rdi+8], xmm7
    ret

# make_body(edi=index, rsi=entry, rdx=object)
make_body:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12
    push    r13
    push    r14
    and     rsp, -16
    sub     rsp, 128
    mov     ebx, edi
    mov     r12, rsi
    mov     r13, rdx
    xorps   xmm0, xmm0                  # rotation: from the Euler angles
    movups  [rsp], xmm0                 #  (loc 0, scale 1)
    movups  xmm0, [r13+OB_ROT]
    movups  [rsp+12], xmm0
    mov     eax, [rip+rx_one]
    mov     [rsp+24], eax
    mov     [rsp+28], eax
    mov     [rsp+32], eax
    lea     rdi, [rsp-OB_LOC]
    lea     rsi, [rsp+48]               # rows (3 x vec4)
    call    obj_matrix
    xor     eax, eax
    mov     [rsp+48+12], eax
    mov     [rsp+48+28], eax
    mov     [rsp+48+44], eax
    movups  xmm0, [r13+OB_LOC]
    andps   xmm0, [rip+rx_xyz]
    movaps  [rsp+96], xmm0              # loc
    movups  xmm0, [r13+OB_SCALE]
    andps   xmm0, [rip+rx_xyz]
    movaps  [rsp+112], xmm0             # scale
    mov     rdi, r13
    call    obj_eval
    mov     rcx, rax                    # the mesh
    mov     edi, ebx
    mov     rsi, r12
    mov     rdx, r13
    lea     r8, [rsp+48]
    call    make_body_ex
    lea     rsp, [rbp-32]
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret

# make_body_ex(edi=index, rsi=entry, rdx=object, rcx=mesh, r8=its place:
#   rotation rows (3 x vec4), loc (vec4), scale (vec4)) - a body of that
#   mesh, so placed and scaled
make_body_ex:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    and     rsp, -16
    sub     rsp, 160
    BODY    rbx, rdi
    mov     r12, rsi
    mov     r13, rdx
    mov     r14, rcx
    mov     [rbx+BD_OBJ], r13
    mov     ecx, [r12+RB_TYPE]
    mov     [rbx+BD_TYPE], ecx
    mov     eax, [rip+rb_npt]
    mov     [rbx+BD_P0], eax
    mov     eax, [r12+RB_FLAGS]         # its group (a bit), those it ignores
    mov     ecx, eax
    shr     ecx, RBF_GRP
    and     ecx, 15
    mov     edx, 1
    shl     edx, cl
    and     eax, 0xffff0000
    or      eax, edx
    mov     [rbx+BD_GRP], eax
    cmp     dword ptr [r12+RB_TYPE], 1  # moving: its velocity at the start
    jne     1f
    movups  xmm0, [r12+RB_VEL-4]
    psrldq  xmm0, 4
    movaps  [rbx+BD_V], xmm0
1:
    movaps  xmm0, [r8+48]               # loc, scale kept
    movaps  [rsp+144], xmm0
    movaps  xmm0, [r8+64]
    movaps  [rbx+BD_SCL], xmm0
    mov     rdi, r8
    lea     rsi, [rbx+BD_Q]
    call    rows_q
    movaps  xmm0, [rbx+BD_Q]            # (unit)
    movaps  xmm1, xmm0
    dpps    xmm1, xmm1, 0xF1
    sqrtss  xmm1, xmm1
    shufps  xmm1, xmm1, 0
    divps   xmm0, xmm1
    movaps  [rbx+BD_Q], xmm0
    lea     rdi, [rbx+BD_Q]
    lea     rsi, [rbx+BD_R]
    call    q_rows
    # the mesh's bounds, scaled: centre c (rsp+96), half h (rsp+112)
    movups  xmm0, [r14+ME_BMIN]
    movups  xmm1, [r14+ME_BMAX]
    movaps  xmm2, [rbx+BD_SCL]
    andps   xmm0, [rip+rx_xyz]
    andps   xmm1, [rip+rx_xyz]
    andps   xmm2, [rip+rx_xyz]
    movaps  [rsp+128], xmm2             # S
    mulps   xmm0, xmm2
    mulps   xmm1, xmm2
    movaps  xmm3, xmm0
    minps   xmm0, xmm1
    maxps   xmm1, xmm3
    movaps  xmm2, xmm0
    addps   xmm2, xmm1
    mulps   xmm2, [rip+rx_half4]
    movaps  [rsp+96], xmm2
    subps   xmm1, xmm0
    mulps   xmm1, [rip+rx_half4]
    movaps  [rsp+112], xmm1
    mov     eax, [r12+RB_SHAPE]
    cmp     eax, 5
    jb      .Lmb_shape
    cmp     dword ptr [r12+RB_TYPE], 2
    jne     .Lmb_moving
    cmp     eax, 5
    je      .Lmb_mesh
    jmp     .Lmb_plane
.Lmb_moving:                            # (moving: a mesh as a compound, a
    cmp     eax, 5                      #  plane as a box)
    je      .Lmb_comp_pts
    xor     eax, eax
.Lmb_shape:
    cmp     eax, 3
    jae     .Lmb_hull
    # box / sphere / capsule: one part
    call    new_part
    mov     r15, rax
    movaps  xmm1, [rsp+112]
    mov     eax, [r12+RB_SHAPE]
    cmp     eax, 6
    je      0f
    test    eax, eax
    jne     2f
0:  cmp     dword ptr [r12+RB_TYPE], 2  # a thin passive box: deep below
    jne     1f                          #  (a floor: its own Y only - a thin
    mov     ecx, 1                      #  wall stays thin, speculative
    movss   xmm0, [rsp+112+rcx*4]       #  contacts keep fast bodies out)
    comiss  xmm0, [rip+rx_thin]
    jae     12f
    movss   xmm3, [rip+rx_thick]
    movss   [rsp+112+rcx*4], xmm3
    subss   xmm3, xmm0
    movss   xmm4, [rsp+96+rcx*4]
    subss   xmm4, xmm3
    movss   [rsp+96+rcx*4], xmm4
12: movaps  xmm1, [rsp+112]
1:  movaps  [r15+PT_HALF], xmm1
    jmp     .Lmb_mass
2:  movaps  xmm0, xmm1                  # r = the largest half (sphere),
    shufps  xmm0, xmm0, 0x55            #  or of x and z (capsule)
    movaps  xmm2, xmm1
    shufps  xmm2, xmm2, 0xAA
    maxss   xmm2, xmm1
    cmp     dword ptr [r12+RB_SHAPE], 1
    jne     3f
    maxss   xmm2, xmm0
    movss   [r15+PT_RAD], xmm2
    jmp     .Lmb_mass
3:  movss   [r15+PT_RAD], xmm2          # capsule: along Y
    subss   xmm0, xmm2
    xorps   xmm3, xmm3
    maxss   xmm0, xmm3
    movss   [r15+PT_HALF+4], xmm0
    jmp     .Lmb_mass
.Lmb_hull:
    # the points, scaled, from the centre, into scratch
    mov     rdi, r14
    lea     rsi, [rsp+96]
    lea     rdx, [rsp+128]
    call    mesh_points                 # rax = them, ecx = how many
    cmp     dword ptr [r12+RB_SHAPE], 3
    jne     .Lmb_comp
    mov     rdi, rax
    mov     esi, ecx
    xorps   xmm0, xmm0
    call    hull_part
    jmp     .Lmb_mass
.Lmb_comp_pts:
    mov     rdi, r14
    lea     rsi, [rsp+96]
    lea     rdx, [rsp+128]
    call    mesh_points
.Lmb_comp:
    mov     [rip+dc_body], rbx
    mov     rdi, r14
    mov     rsi, rax
    call    decompose
    jmp     .Lmb_mass
.Lmb_mesh:                              # a mesh collider: a part a triangle
    mov     rdi, r14
    lea     rsi, [rsp+96]
    lea     rdx, [rsp+128]
    mov     ecx, [r14+ME_NTRIS]         # (its points after where the
    lea     ecx, [rcx+rcx*2+64]         #  triangles' corners go)
    call    mesh_points_at
    mov     r15, rax
    mov     dword ptr [rsp+140], 0      # triangle
1:  mov     eax, [rsp+140]
    cmp     eax, [r14+ME_NTRIS]
    jae     .Lmb_mass
    mov     rcx, [r14+ME_TRIS]
    imul    eax, eax, 12
    xor     edx, edx                    # its corners into [rsp] (3 vec4)
2:  mov     r8d, [rcx+rax]
    shl     r8, 4
    movaps  xmm0, [r15+r8]
    mov     r9d, edx
    shl     r9d, 4
    movaps  [rsp+r9], xmm0
    add     eax, 4
    inc     edx
    cmp     edx, 3
    jb      2b
    movaps  xmm1, [rsp+16]              # (no area: none)
    subps   xmm1, [rsp]
    movaps  xmm2, [rsp+32]
    subps   xmm2, [rsp]
    CROSS   xmm3, xmm1, xmm2, xmm4
    DOT3    xmm3, xmm3
    comiss  xmm3, [rip+rx_tiny2]
    jbe     3f
    lea     rdi, [rsp]
    mov     esi, 3
    xorps   xmm0, xmm0
    call    hull_part
    mov     eax, [rip+rb_npt]
    dec     eax
    imul    rax, rax, PT_SZ
    add     rax, [rip+rb_pt]
    mov     dword ptr [rax+PT_FLG], 1 | 14  # (every edge active, for now)
3:  inc     dword ptr [rsp+140]
    jmp     1b
.Lmb_plane:                             # a plane: its object's XZ, up its Y,
    call    new_part                    #  through its origin, without end
    mov     dword ptr [rax+PT_TYPE], 2
    mov     dword ptr [rax+PT_HALF], 0
    mov     ecx, [rip+rx_one]
    mov     dword ptr [rax+PT_HALF+4], ecx
    mov     dword ptr [rax+PT_HALF+8], 0
    movaps  xmm0, [rsp+96]              # (the point: the origin, from the
    xorps   xmm0, [rip+rx_sign]         #  bounds' centre)
    movaps  [rax+PT_OFF], xmm0
.Lmb_mass:
    mov     eax, [rip+rb_npt]
    sub     eax, [rbx+BD_P0]
    mov     [rbx+BD_NP], eax
    movaps  xmm0, [rsp+96]              # the centre of mass: the bounds' centre
    movaps  [rbx+BD_COM], xmm0
    MV3     xmm1, rbx+BD_R, xmm0, xmm2, xmm3    # pos = loc + R com
    addps   xmm1, [rsp+144]
    movaps  [rbx+BD_POS], xmm1
    movss   xmm0, [r12+RB_FRIC]
    movss   [rbx+BD_FRIC], xmm0
    movss   xmm0, [r12+RB_REST]
    movss   [rbx+BD_REST], xmm0
    movss   xmm0, [r12+RB_DAMP]
    movss   [rbx+BD_DAMP], xmm0
    cmp     dword ptr [r12+RB_TYPE], 1
    jne     8f
    movss   xmm7, [r12+RB_MASS]         # moving: mass, inertia (a box of
    xorps   xmm0, xmm0                  #  its bounds; a sphere's 2/5)
    comiss  xmm7, xmm0
    ja      51f
    movss   xmm7, [rip+rx_one]
51: movss   xmm0, [rip+rx_one]
    divss   xmm0, xmm7
    movss   [rbx+BD_IM], xmm0
    movaps  xmm1, [rsp+112]             # h^2
    mulps   xmm1, xmm1
    cmp     dword ptr [r12+RB_SHAPE], 1
    jne     52f
    mov     rax, [rip+rb_pt]
    mov     ecx, [rbx+BD_P0]
    imul    ecx, ecx, PT_SZ
    movss   xmm2, [rax+rcx+PT_RAD]      # 2/5 m r^2
    mulss   xmm2, xmm2
    mulss   xmm2, xmm7
    mulss   xmm2, [rip+rx_fifth2]
    shufps  xmm2, xmm2, 0
    jmp     53f
52: movaps  xmm2, xmm1                  # I_x = m/3 (hy^2 + hz^2) ...
    shufps  xmm2, xmm2, 0xC9            # (y z x)
    movaps  xmm3, xmm1
    shufps  xmm3, xmm3, 0xD2            # (z x y)
    addps   xmm2, xmm3
    movss   xmm3, xmm7
    mulss   xmm3, [rip+rx_third]
    shufps  xmm3, xmm3, 0
    mulps   xmm2, xmm3
53: movaps  xmm3, [rip+rx_one4]         # inverse (tiny: none)
    maxps   xmm2, [rip+rx_tiny4]
    divps   xmm3, xmm2
    andps   xmm3, [rip+rx_xyz]
    movaps  [rbx+BD_IIL], xmm3
8:  mov     rdi, rbx
    call    body_update
    cmp     dword ptr [r12+RB_SHAPE], 5 # a mesh collider: its edges, its
    jne     9f                          #  tree
    cmp     dword ptr [r12+RB_TYPE], 2
    jne     9f
    mov     rdi, rbx
    call    tri_edges
    mov     rdi, rbx
    call    bvh_build
9:  lea     rsp, [rbp-40]
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret

# tri_edges(rdi=body) - which of its triangles' edges are active: an edge
#   shared with a neighbour in the same plane (within 5 degrees) is not
#   (contacts there take the face's normal: tri_fix). Edges are matched by
#   their ends' places (to 0.1 mm), so meshes with split vertices work too
.equ TE_SZ,     16                      # an entry: key (8), part, edge
tri_edges:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    and     rsp, -16
    sub     rsp, 128
    mov     rbx, rdi
    mov     eax, [rbx+BD_NP]            # the table: a power of two >= 6 n
    imul    eax, eax, 6
    or      eax, 63
    bsr     ecx, eax
    inc     ecx
    mov     eax, 1
    shl     eax, cl
    dec     eax
    mov     [rsp+96], eax               # mask
    inc     rax
    shl     rax, 4
    mov     [rsp+104], rax              # bytes
    mov     rsi, rax
    call    rb_reserve
    test    rax, rax
    jz      .Lte_out
    mov     [rsp+112], rax
    xor     r12d, r12d                  # part (of this body)
1:  cmp     r12d, [rbx+BD_NP]
    jae     .Lte_done
    xor     r13d, r13d                  # edge
2:  cmp     r13d, 3
    jae     8f
    mov     edi, r12d
    mov     esi, r13d
    call    te_key                      # rax the key
    mov     r14, rax
    mov     rcx, [rsp+112]
    mov     rdx, rax                    # its slot
    shr     rdx, 20
    and     edx, [rsp+96]
3:  mov     r8, rdx
    shl     r8, 4
    cmp     qword ptr [rcx+r8], 0
    je      4f
    cmp     [rcx+r8], r14
    je      5f
    inc     edx
    and     edx, [rsp+96]
    jmp     3b
4:  mov     [rcx+r8], r14               # first seen: kept
    mov     [rcx+r8+8], r12d
    mov     [rcx+r8+12], r13d
    jmp     7f
5:  mov     edi, r12d                   # its neighbour: flat?
    mov     esi, [rcx+r8+8]
    call    te_normals                  # xmm0 = |n1 . n2|
    comiss  xmm0, [rip+rx_cos5]
    jb      7f
    mov     rcx, [rsp+112]
    mov     edx, r14d                   # (the slot again)
    mov     rdx, r14
    shr     rdx, 20
    and     edx, [rsp+96]
51: mov     r8, rdx
    shl     r8, 4
    cmp     [rcx+r8], r14
    je      52f
    inc     edx
    and     edx, [rsp+96]
    jmp     51b
52: mov     eax, [rcx+r8+8]             # both edges inactive
    mov     r9d, [rcx+r8+12]
    add     eax, [rbx+BD_P0]
    imul    rax, rax, PT_SZ
    add     rax, [rip+rb_pt]
    mov     r10d, 2
    mov     ecx, r9d
    shl     r10d, cl
    not     r10d
    and     [rax+PT_FLG], r10d
    mov     eax, r12d
    add     eax, [rbx+BD_P0]
    imul    rax, rax, PT_SZ
    add     rax, [rip+rb_pt]
    mov     r10d, 2
    mov     ecx, r13d
    shl     r10d, cl
    not     r10d
    and     [rax+PT_FLG], r10d
7:  inc     r13d
    jmp     2b
8:  inc     r12d
    jmp     1b
.Lte_done:
    mov     rdi, [rsp+112]
    mov     rsi, [rsp+104]
    mov     eax, SYS_MUNMAP
    syscall
.Lte_out:
    lea     rsp, [rbp-40]
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret

# te_point(edi=part of rbx, esi=corner 0-2) -> xmm0 = it (body axes)
te_point:
    mov     eax, edi
    add     eax, [rbx+BD_P0]
    imul    rax, rax, PT_SZ
    add     rax, [rip+rb_pt]
    mov     rcx, [rax+PT_VERTS]
    shl     esi, 4
    movaps  xmm0, [rcx+rsi]
    addps   xmm0, [rax+PT_OFF]
    andps   xmm0, [rip+rx_xyz]
    ret

# te_key(edi=part of rbx, esi=edge) -> rax = its ends' places (to 0.1 mm,
#   either way round) hashed; never 0
te_key:
    push    r12
    push    r13
    sub     rsp, 40
    mov     r12d, edi
    mov     r13d, esi
    call    te_point                    # its first end
    mulps   xmm0, [rip+rx_1e4]
    cvtps2dq xmm0, xmm0
    movdqa  [rsp], xmm0
    mov     edi, r12d
    lea     esi, [r13+1]
    cmp     esi, 3
    jb      1f
    xor     esi, esi
1:  call    te_point                    # its second
    mulps   xmm0, [rip+rx_1e4]
    cvtps2dq xmm0, xmm0
    movdqa  [rsp+16], xmm0
    mov     rax, [rsp]                  # the lesser first (x, then y, z)
    mov     rcx, [rsp+16]
    mov     edx, [rsp+8]
    mov     r8d, [rsp+24]
    mov     r9d, [rsp]
    cmp     r9d, [rsp+16]
    jl      3f
    jg      2f
    mov     r9d, [rsp+4]
    cmp     r9d, [rsp+20]
    jl      3f
    jg      2f
    mov     r9d, [rsp+8]
    cmp     r9d, [rsp+24]
    jle     3f
2:  xchg    rax, rcx
    xchg    edx, r8d
3:  mov     r9, 0x9E3779B97F4A7C15      # (a, b) mixed
    imul    rax, r9
    xor     rax, rdx
    imul    rax, r9
    xor     rax, rcx
    imul    rax, r9
    xor     rax, r8
    imul    rax, r9
    or      rax, 1
    add     rsp, 40
    pop     r13
    pop     r12
    ret

# te_normals(edi=part, esi=part, both of rbx) -> xmm0 = |n1 . n2|
te_normals:
    push    r12
    push    r13
    sub     rsp, 40
    mov     r12d, edi
    mov     r13d, esi
    mov     edi, r12d
    call    te_normal
    movaps  [rsp], xmm0
    mov     edi, r13d
    call    te_normal
    DOT3    xmm0, [rsp]
    andps   xmm0, [rip+rx_abs]
    add     rsp, 40
    pop     r13
    pop     r12
    ret
# te_normal(edi=part of rbx) -> xmm0 = its face's normal (unit)
te_normal:
    mov     eax, edi
    add     eax, [rbx+BD_P0]
    imul    rax, rax, PT_SZ
    add     rax, [rip+rb_pt]
    mov     rcx, [rax+PT_VERTS]
    movaps  xmm1, [rcx+16]
    subps   xmm1, [rcx]
    movaps  xmm2, [rcx+32]
    subps   xmm2, [rcx]
    andps   xmm1, [rip+rx_xyz]
    andps   xmm2, [rip+rx_xyz]
    CROSS   xmm0, xmm1, xmm2, xmm3
    movaps  xmm1, xmm0
    DOT3    xmm1, xmm1
    maxss   xmm1, [rip+rx_tiny2]
    sqrtss  xmm1, xmm1
    shufps  xmm1, xmm1, 0
    divps   xmm0, xmm1
    ret

# bvh_build(rdi=body) - a tree of its parts (a mesh's triangles): their
#   bounds (world), split at the middle of their centres' largest extent
#   (half and half when that fails), four or fewer to a leaf
bvh_build:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 40
    mov     rbx, rdi
    mov     r12d, [rip+rb_nbvi]         # this body's triangles start here
    xor     r13d, r13d
1:  cmp     r13d, [rbx+BD_NP]
    jae     2f
    mov     esi, [rbx+BD_P0]
    add     esi, r13d
    lea     eax, [r12+r13]
    mov     rcx, [rip+rb_bvi]
    mov     [rcx+rax*4], esi
    shl     rax, 5
    mov     rdx, [rip+rb_bvb]
    add     rdx, rax
    mov     rdi, rbx
    call    part_bounds
    mov     esi, [rbx+BD_P0]            # its corners (world), kept
    add     esi, r13d
    lea     edx, [r12+r13]
    call    tw_make
    inc     r13d
    jmp     1b
2:  add     [rip+rb_nbvi], r13d
    mov     edi, r12d
    mov     esi, r13d
    call    bvh_node
    inc     eax
    mov     [rbx+BD_BVH], eax
    add     rsp, 40
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# tw_make(esi=part of rbx, edx=its slot) - the triangle's corners in the
#   world into rb_tvw (the body is static)
tw_make:
    imul    rax, rsi, PT_SZ
    add     rax, [rip+rb_pt]
    mov     [rax+PT_TW], edx
    imul    r8, rdx, 48
    add     r8, [rip+rb_tvw]
    mov     r9, [rax+PT_VERTS]
    xor     ecx, ecx
1:  mov     edx, ecx
    shl     edx, 4
    movaps  xmm0, [r9+rdx]
    addps   xmm0, [rax+PT_OFF]
    andps   xmm0, [rip+rx_xyz]
    MV3     xmm1, rbx+BD_R, xmm0, xmm2, xmm3
    addps   xmm1, [rbx+BD_POS]
    andps   xmm1, [rip+rx_xyz]
    movaps  [r8+rdx], xmm1
    inc     ecx
    cmp     ecx, 3
    jb      1b
    ret

# bvh_node(edi=first, esi=count) -> eax = a node for those triangles
bvh_node:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 64
    mov     r12d, edi
    mov     r13d, esi
    mov     ebx, [rip+rb_nbvh]          # the node
    inc     dword ptr [rip+rb_nbvh]
    movaps  xmm6, [rip+rx_big4]         # bounds, and the centres' bounds
    movaps  xmm7, [rip+rx_nbig4]
    movaps  xmm8, [rip+rx_big4]
    movaps  xmm9, [rip+rx_nbig4]
    xor     ecx, ecx
1:  cmp     ecx, r13d
    jae     2f
    lea     eax, [r12+rcx]
    shl     rax, 5
    add     rax, [rip+rb_bvb]
    minps   xmm6, [rax]
    maxps   xmm7, [rax+16]
    movaps  xmm0, [rax]
    addps   xmm0, [rax+16]
    minps   xmm8, xmm0
    maxps   xmm9, xmm0
    inc     ecx
    jmp     1b
2:  mov     rax, rbx
    shl     rax, 5
    add     rax, [rip+rb_bvh]
    mov     r14, rax
    movaps  [r14], xmm6
    movaps  [r14+16], xmm7
    cmp     r13d, 4
    ja      3f
    mov     eax, r12d                   # a leaf
    or      eax, 0x80000000
    mov     [r14+12], eax
    mov     [r14+28], r13d
    jmp     9f
3:  movaps  xmm0, xmm9                  # the axis: the centres' largest
    subps   xmm0, xmm8                  #  extent (x2: sums of min and max)
    xor     r15d, r15d
    movss   xmm1, xmm0
    movaps  xmm2, xmm0
    shufps  xmm2, xmm2, 0x55
    comiss  xmm2, xmm1
    jbe     31f
    movss   xmm1, xmm2
    mov     r15d, 1
31: movaps  xmm2, xmm0
    shufps  xmm2, xmm2, 0xAA
    comiss  xmm2, xmm1
    jbe     32f
    mov     r15d, 2
32: movaps  [rsp], xmm8             # its middle
    movaps  [rsp+16], xmm9
    movss   xmm3, [rsp+r15*4]
    addss   xmm3, [rsp+16+r15*4]
    mulss   xmm3, [rip+rx_half]
    movss   [rsp+32], xmm3
    mov     ecx, r12d                   # partition: centre below it first
    lea     edx, [r12+r13]
4:  cmp     ecx, edx
    jae     5f
    mov     eax, ecx
    shl     rax, 5
    add     rax, [rip+rb_bvb]
    movss   xmm0, [rax+r15*4]
    addss   xmm0, [rax+16+r15*4]
    comiss  xmm0, [rsp+32]
    jae     41f
    inc     ecx
    jmp     4b
41: dec     edx                         # swap with the last
    mov     r8d, edx
    shl     r8, 5
    add     r8, [rip+rb_bvb]
    movaps  xmm0, [rax]
    movaps  xmm1, [rax+16]
    movaps  xmm2, [r8]
    movaps  xmm3, [r8+16]
    movaps  [rax], xmm2
    movaps  [rax+16], xmm3
    movaps  [r8], xmm0
    movaps  [r8+16], xmm1
    mov     r9, [rip+rb_bvi]
    mov     r10d, [r9+rcx*4]
    mov     r11d, [r9+rdx*4]
    mov     [r9+rcx*4], r11d
    mov     [r9+rdx*4], r10d
    jmp     4b
5:  sub     ecx, r12d                   # how many below
    jz      51f
    cmp     ecx, r13d
    jb      52f
51: mov     ecx, r13d                   # (all on one side: half and half)
    shr     ecx, 1
52: mov     [rsp+36], ecx
    mov     edi, r12d
    mov     esi, ecx
    call    bvh_node
    mov     [r14+12], eax
    mov     edi, r12d
    add     edi, [rsp+36]
    mov     esi, r13d
    sub     esi, [rsp+36]
    call    bvh_node
    mov     rcx, rbx                    # (the array may have moved? no:
    shl     rcx, 5                      #  reserved; r14 still good)
    add     rcx, [rip+rb_bvh]
    mov     [rcx+28], eax
9:  mov     eax, ebx
    add     rsp, 64
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# mesh_points_at(rdi=mesh, rsi=centre, rdx=scale, ecx=where in the scratch
#   (points after rb_nvx)) -> rax = its points (vec4, scaled, from the centre)
mesh_points_at:
    add     ecx, [rip+rb_nvx]
    mov     eax, ecx
    shl     rax, 4
    add     rax, [rip+rb_vx]
    jmp     mesh_points_in

# new_part -> rax = a zeroed part of the body being made (rbx), counted
new_part:
    mov     eax, [rip+rb_npt]
    inc     dword ptr [rip+rb_npt]
    imul    rax, rax, PT_SZ
    add     rax, [rip+rb_pt]
    mov     rcx, rbx
    sub     rcx, [rip+rb_bd]
    push    rax
    mov     rax, rcx
    xor     edx, edx
    mov     ecx, BD_SZ
    div     rcx
    mov     ecx, eax
    pop     rax
    mov     [rax+PT_BODY], ecx
    ret

# mesh_points(rdi=mesh, rsi=centre, rdx=scale) -> rax = its points (vec4,
#   scaled, from the centre) in scratch, ecx = how many
mesh_points:
    mov     eax, [rip+rb_nvx]           # (scratch: after the hulls so far,
    add     eax, PT_MAXB*HULL_MAX       #  leaving room for this body's)
    shl     rax, 4
    add     rax, [rip+rb_vx]
mesh_points_in:
    mov     r8, [rdi+ME_POS]
    mov     ecx, [rdi+ME_NVERTS]
    movaps  xmm1, [rdx]
    movaps  xmm2, [rsi]
    xor     r9d, r9d
1:  cmp     r9d, ecx
    jae     2f
    imul    r10, r9, 12
    movsd   xmm0, [r8+r10]
    movss   xmm3, [r8+r10+8]
    movlhps xmm0, xmm3
    mulps   xmm0, xmm1
    subps   xmm0, xmm2
    andps   xmm0, [rip+rx_xyz]
    mov     r10, r9
    shl     r10, 4
    movaps  [rax+r10], xmm0
    inc     r9d
    jmp     1b
2:  ret

# hull_part(rdi=points, esi=count, xmm0=offset of the part (vec4)) - a hull
#   part: at most HULL_MAX of the points (the farthest along fixed
#   directions), from their bounds' centre
hull_part:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    and     rsp, -16
    sub     rsp, 64
    movaps  [rsp], xmm0
    mov     r12, rdi
    mov     r13d, esi
    call    new_part
    mov     r14, rax
    mov     dword ptr [r14+PT_TYPE], 1
    mov     eax, [rip+rb_nvx]
    shl     rax, 4
    add     rax, [rip+rb_vx]
    mov     [r14+PT_VERTS], rax
    mov     r15, rax                    # the hull's points
    xor     ebx, ebx                    # kept
    cmp     r13d, HULL_MAX
    ja      3f
    xor     ecx, ecx                    # few: all
1:  cmp     ecx, r13d
    jae     5f
    mov     rax, rcx
    shl     rax, 4
    movaps  xmm0, [r12+rax]
    movaps  [r15+rax], xmm0
    inc     ecx
    jmp     1b
3:  mov     rdi, r12                    # many: the farthest along 64 ways
    mov     esi, r13d
    mov     rdx, r15
    call    extremes
    mov     ebx, eax
    jmp     6f
5:  mov     ebx, r13d
6:  mov     [r14+PT_NV], ebx
    add     [rip+rb_nvx], ebx
    movaps  xmm6, [rip+rx_big4]         # its bounds' centre: the points from it
    movaps  xmm7, [rip+rx_nbig4]
    xor     ecx, ecx
7:  cmp     ecx, ebx
    jae     71f
    mov     rax, rcx
    shl     rax, 4
    minps   xmm6, [r15+rax]
    maxps   xmm7, [r15+rax]
    inc     ecx
    jmp     7b
71: movaps  xmm0, xmm6
    addps   xmm0, xmm7
    mulps   xmm0, [rip+rx_half4]
    andps   xmm0, [rip+rx_xyz]
    subps   xmm7, xmm6
    mulps   xmm7, [rip+rx_half4]
    andps   xmm7, [rip+rx_xyz]
    movaps  [r14+PT_HALF], xmm7
    xor     ecx, ecx
72: cmp     ecx, ebx
    jae     73f
    mov     rax, rcx
    shl     rax, 4
    movaps  xmm1, [r15+rax]
    subps   xmm1, xmm0
    movaps  [r15+rax], xmm1
    inc     ecx
    jmp     72b
73: addps   xmm0, [rsp]
    movaps  [r14+PT_OFF], xmm0
    lea     rsp, [rbp-40]
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret

# extremes(rdi=points, esi=count, rdx=out) -> eax = the points farthest
#   along 64 directions (each once), at out
extremes:
    push    rbx
    xor     ebx, ebx
    xor     r8d, r8d
1:  cmp     r8d, 64
    jae     9f
    mov     rax, r8
    shl     rax, 4
    lea     rcx, [rip+rb_dirs]
    movaps  xmm7, [rcx+rax]
    movss   xmm6, [rip+rx_nbig4]
    xor     r9d, r9d
    xor     r10d, r10d
2:  cmp     r9d, esi
    jae     3f
    mov     rax, r9
    shl     rax, 4
    movaps  xmm0, [rdi+rax]
    DOT3    xmm0, xmm7
    comiss  xmm0, xmm6
    jbe     21f
    movss   xmm6, xmm0
    mov     r10d, r9d
21: inc     r9d
    jmp     2b
3:  mov     rax, r10                    # (unless kept already)
    shl     rax, 4
    movaps  xmm0, [rdi+rax]
    xor     ecx, ecx
4:  cmp     ecx, ebx
    jae     5f
    mov     rax, rcx
    shl     rax, 4
    movaps  xmm1, [rdx+rax]
    cmpneqps xmm1, xmm0
    movmskps eax, xmm1
    test    eax, 7
    jz      6f
    inc     ecx
    jmp     4b
5:  mov     rax, rbx
    shl     rax, 4
    movaps  [rdx+rax], xmm0
    inc     ebx
6:  inc     r8d
    jmp     1b
9:  mov     eax, ebx
    pop     rbx
    ret

# decompose(rdi=mesh, rsi=its points (scratch, from the body's centre)) -
#   convex parts: triangles split in half along their longest side while a
#   part is hollower than its hull (a triangle, either way, far inside it)
.equ DC_MESH,   0
.equ DC_PTS,    8
.equ DC_LIST,   16
.equ DC_MARK,   24
.equ DC_GATH,   32
.equ DC_STAMP,  40
decompose:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12
    and     rsp, -16
    sub     rsp, 64
    mov     [rip+dc_ctx+DC_MESH], rdi
    mov     [rip+dc_ctx+DC_PTS], rsi
    mov     eax, [rdi+ME_NVERTS]
    shl     rax, 4
    lea     rcx, [rsi+rax+64]
    and     rcx, -16
    mov     [rip+dc_ctx+DC_GATH], rcx   # gathered points (n vec4)
    add     rcx, rax
    mov     [rip+dc_ctx+DC_MARK], rcx   # a stamp a vertex
    mov     eax, [rdi+ME_NVERTS]
    lea     rcx, [rcx+rax*4+64]
    and     rcx, -16
    mov     [rip+dc_ctx+DC_LIST], rcx   # the triangles
    mov     rdx, [rip+dc_ctx+DC_MARK]
    xor     r8d, r8d
1:  cmp     r8d, eax
    jae     2f
    mov     dword ptr [rdx+r8*4], 0
    inc     r8d
    jmp     1b
2:  mov     dword ptr [rip+dc_ctx+DC_STAMP], 0
    mov     ecx, [rdi+ME_NTRIS]
    mov     rdx, [rip+dc_ctx+DC_LIST]
    xor     r8d, r8d
3:  cmp     r8d, ecx
    jae     4f
    mov     [rdx+r8*4], r8d
    inc     r8d
    jmp     3b
4:  mov     rdi, rdx
    mov     esi, ecx
    xor     edx, edx
    call    dc_node
    lea     rsp, [rbp-16]
    pop     r12
    pop     rbx
    pop     rbp
    ret

# dc_tri(edi=triangle) -> rax, rcx, rdx = its points' addresses
dc_tri:
    mov     r8, [rip+dc_ctx+DC_MESH]
    mov     r8, [r8+ME_TRIS]
    imul    rdi, rdi, 12
    mov     r9, [rip+dc_ctx+DC_PTS]
    mov     eax, [r8+rdi]
    shl     rax, 4
    add     rax, r9
    mov     ecx, [r8+rdi+4]
    shl     rcx, 4
    add     rcx, r9
    mov     edx, [r8+rdi+8]
    shl     rdx, 4
    add     rdx, r9
    ret

# dc_node(rdi=triangle list, esi=count, edx=depth)
dc_node:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    and     rsp, -16
    sub     rsp, 1152                   # (the hull's points: 64 x 16, + 128)
    mov     r12, rdi
    mov     r13d, esi
    mov     r14d, edx
    test    r13d, r13d
    jz      .Ldn_out
    # gather the vertices
    inc     dword ptr [rip+dc_ctx+DC_STAMP]
    mov     r15d, [rip+dc_ctx+DC_STAMP]
    xor     ebx, ebx                    # gathered
    xor     ecx, ecx
1:  cmp     ecx, r13d
    jae     3f
    mov     r8, [rip+dc_ctx+DC_MESH]
    mov     r8, [r8+ME_TRIS]
    mov     eax, [r12+rcx*4]
    imul    rax, rax, 12
    add     r8, rax
    xor     edx, edx
2:  mov     r9d, [r8+rdx*4]
    mov     r10, [rip+dc_ctx+DC_MARK]
    cmp     [r10+r9*4], r15d
    je      21f
    mov     [r10+r9*4], r15d
    shl     r9, 4
    add     r9, [rip+dc_ctx+DC_PTS]
    movaps  xmm0, [r9]
    mov     r10, rbx
    shl     r10, 4
    add     r10, [rip+dc_ctx+DC_GATH]
    movaps  [r10], xmm0
    inc     ebx
21: inc     edx
    cmp     edx, 3
    jb      2b
    inc     ecx
    jmp     1b
3:  mov     [rsp+64], ebx
    # leaf? deep enough, few triangles, no room for more parts
    cmp     r14d, 4
    jae     .Ldn_leaf
    cmp     r13d, 12
    jb      .Ldn_leaf
    mov     eax, [rip+rb_npt]
    mov     rcx, [rip+dc_body]
    sub     eax, [rcx+BD_P0]
    add     eax, 2
    cmp     eax, PT_MAXB
    ja      .Ldn_leaf
    # its hull's points (64 at most) and bounds
    mov     rdi, [rip+dc_ctx+DC_GATH]
    mov     esi, ebx
    lea     rdx, [rsp+128]
    call    extremes
    mov     [rsp], eax
    movaps  xmm6, [rip+rx_big4]
    movaps  xmm7, [rip+rx_nbig4]
    xor     ecx, ecx
4:  cmp     ecx, [rsp]
    jae     41f
    mov     rax, rcx
    shl     rax, 4
    minps   xmm6, [rsp+128+rax]
    maxps   xmm7, [rsp+128+rax]
    inc     ecx
    jmp     4b
41: movaps  [rsp+16], xmm6
    movaps  [rsp+32], xmm7
    subps   xmm7, xmm6                  # threshold: hollowness x the diagonal
    andps   xmm7, [rip+rx_xyz]
    movaps  [rsp+48], xmm7
    DOT3    xmm7, xmm7
    sqrtss  xmm7, xmm7
    mulss   xmm7, [rip+rx_conc]
    movss   [rsp+4], xmm7
    # the hollowest triangle: min over +-n of (the hull along n - its centre)
    xorps   xmm5, xmm5
    movss   [rsp+8], xmm5
    xor     r15d, r15d
5:  cmp     r15d, r13d
    jae     6f
    mov     edi, [r12+r15*4]
    call    dc_tri
    movaps  xmm0, [rax]
    movaps  xmm1, [rcx]
    movaps  xmm2, [rdx]
    movaps  xmm3, xmm1
    subps   xmm3, xmm0
    movaps  xmm4, xmm2
    subps   xmm4, xmm0
    CROSS   xmm5, xmm3, xmm4, xmm6
    movaps  xmm6, xmm5
    DOT3    xmm6, xmm6
    sqrtss  xmm6, xmm6
    comiss  xmm6, [rip+rx_tiny]
    jbe     55f
    shufps  xmm6, xmm6, 0
    divps   xmm5, xmm6                  # n
    andps   xmm5, [rip+rx_xyz]
    addps   xmm0, xmm1                  # g
    addps   xmm0, xmm2
    movss   xmm7, [rip+rx_third]
    shufps  xmm7, xmm7, 0
    mulps   xmm0, xmm7
    andps   xmm0, [rip+rx_xyz]
    movaps  xmm1, xmm0
    DOT3    xmm1, xmm5                  # g . n
    movss   xmm2, [rip+rx_nbig4]        # hull: max, min of h . n
    movss   xmm3, [rip+rx_big4]
    xor     ecx, ecx
51: cmp     ecx, [rsp]
    jae     52f
    mov     rax, rcx
    shl     rax, 4
    movaps  xmm4, [rsp+128+rax]
    DOT3    xmm4, xmm5
    maxss   xmm2, xmm4
    minss   xmm3, xmm4
    inc     ecx
    jmp     51b
52: subss   xmm2, xmm1                  # along n: max - g.n
    subss   xmm1, xmm3                  # along -n: g.n - min
    minss   xmm2, xmm1
    maxss   xmm2, [rsp+8]
    movss   [rsp+8], xmm2
55: inc     r15d
    jmp     5b
6:  movss   xmm0, [rsp+8]
    comiss  xmm0, [rsp+4]
    jbe     .Ldn_leaf
    # split along the longest side at its middle (by triangle centres)
    xor     ecx, ecx
    movss   xmm0, [rsp+48]
    movss   xmm1, [rsp+52]
    comiss  xmm1, xmm0
    jbe     61f
    mov     ecx, 1
    movss   xmm0, xmm1
61: movss   xmm1, [rsp+56]
    comiss  xmm1, xmm0
    jbe     62f
    mov     ecx, 2
62: mov     [rsp+12], ecx
    movss   xmm7, [rsp+16+rcx*4]        # middle
    addss   xmm7, [rsp+32+rcx*4]
    mulss   xmm7, [rip+rx_half]
    movss   [rsp+60], xmm7
    xor     r15d, r15d                  # i: below goes first
    lea     ebx, [r13-1]                # j
7:  cmp     r15d, ebx
    jg      8f
    mov     edi, [r12+r15*4]
    call    dc_tri
    mov     r8d, [rsp+12]
    movss   xmm0, [rax+r8*4]
    addss   xmm0, [rcx+r8*4]
    addss   xmm0, [rdx+r8*4]
    mulss   xmm0, [rip+rx_third]
    comiss  xmm0, [rsp+60]
    jae     71f
    inc     r15d
    jmp     7b
71: mov     eax, [r12+r15*4]            # above: to the end
    mov     ecx, [r12+rbx*4]
    mov     [r12+r15*4], ecx
    mov     [r12+rbx*4], eax
    dec     ebx
    jmp     7b
8:  test    r15d, r15d
    jz      .Ldn_regather
    cmp     r15d, r13d
    jae     .Ldn_regather
    mov     rdi, r12
    mov     esi, r15d
    lea     edx, [r14+1]
    call    dc_node
    lea     rdi, [r12+r15*4]
    mov     esi, r13d
    sub     esi, r15d
    lea     edx, [r14+1]
    call    dc_node
    jmp     .Ldn_out
.Ldn_regather:                          # (no split: a leaf)
.Ldn_leaf:
    mov     rdi, [rip+dc_ctx+DC_GATH]
    mov     esi, [rsp+64]
    xorps   xmm0, xmm0
    push    rbx
    push    rbx
    mov     rbx, [rip+dc_body]
    call    hull_part
    pop     rbx
    pop     rbx
.Ldn_out:
    lea     rsp, [rbp-40]
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret

.section .bss
.align 16
dc_ctx:         .skip 64
dc_body:        .skip 8
.text

# make_joints - the joints' runtime records
make_joints:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 32
    mov     rbx, [rip+an_cur]
    xor     r12d, r12d
1:  cmp     r12d, [rbx+AN_NJT_]
    jae     9f
    imul    r13, r12, JT_SZ_
    lea     r13, [rbx+AN_JT_+r13]
    mov     edi, [r13+JT_A]
    call    body_of_uid
    test    eax, eax
    js      8f
    mov     r14d, eax
    mov     eax, [rip+rb_nb]            # B: the world, or a body
    dec     eax
    mov     edi, [r13+JT_B]
    test    edi, edi
    jz      2f
    call    body_of_uid
    test    eax, eax
    js      8f
2:  mov     r15d, eax
    cmp     r15d, r14d
    je      8f
    mov     eax, [rip+rb_njr]
    inc     dword ptr [rip+rb_njr]
    imul    rdi, rax, JR_SZ
    add     rdi, [rip+rb_jr]
    mov     [rdi+JR_A], r14d
    mov     [rdi+JR_B], r15d
    mov     eax, [r13+JT_TYPE]
    mov     [rdi+JR_TYPE], eax
    mov     eax, [r13+JT_BRK]           # break, limits, motor
    mov     [rdi+JR_BRK], eax
    mov     eax, [r13+JT_LO]
    mov     [rdi+JR_LO], eax
    mov     eax, [r13+JT_HI]
    mov     [rdi+JR_HI], eax
    mov     eax, [r13+JT_MSPD]
    mov     [rdi+JR_MS], eax
    mov     eax, [r13+JT_MFOR]
    mov     [rdi+JR_MF], eax
    mov     eax, [r13+JT_FLG]
    and     eax, 3
    mov     [rdi+JR_FL], eax
    mov     dword ptr [rdi+JR_IMP], 0
    mov     dword ptr [rdi+JR_IMP+4], 0
    mov     dword ptr [rdi+JR_IMP+8], 0
    BODY    r8, r14
    BODY    r9, r15
    mov     dword ptr [r8+BD_JOINT], 1
    mov     dword ptr [r9+BD_JOINT], 1
    movups  xmm0, [r13+JT_PIV]          # anchors: R^T (pivot - centre)
    andps   xmm0, [rip+rx_xyz]
    movaps  xmm1, xmm0
    subps   xmm1, [r8+BD_POS]
    lea     rax, [r8+BD_R]
    MTV3    xmm2, rax, xmm1, xmm3
    andps   xmm2, [rip+rx_xyz]
    movaps  [rdi+JR_LA], xmm2
    movaps  xmm1, xmm0
    subps   xmm1, [r9+BD_POS]
    lea     rax, [r9+BD_R]
    MTV3    xmm2, rax, xmm1, xmm3
    andps   xmm2, [rip+rx_xyz]
    movaps  [rdi+JR_LB], xmm2
    movups  xmm0, [r13+JT_AXIS]         # the axis in each (Y when none)
    andps   xmm0, [rip+rx_xyz]
    movaps  xmm1, xmm0
    DOT3    xmm1, xmm1
    comiss  xmm1, [rip+rx_tiny]
    ja      3f
    movaps  xmm0, [rip+rx_ident+16]
    movaps  xmm1, [rip+rx_one4]
3:  sqrtss  xmm1, xmm1
    shufps  xmm1, xmm1, 0
    divps   xmm0, xmm1
    andps   xmm0, [rip+rx_xyz]
    lea     rax, [r8+BD_R]
    MTV3    xmm2, rax, xmm0, xmm3
    andps   xmm2, [rip+rx_xyz]
    movaps  [rdi+JR_AXA], xmm2
    lea     rax, [r9+BD_R]
    MTV3    xmm2, rax, xmm0, xmm3
    andps   xmm2, [rip+rx_xyz]
    movaps  [rdi+JR_AXB], xmm2
    push    rdi                         # q0 = qB conj(qA)
    sub     rsp, 8
    movaps  xmm0, [r9+BD_Q]
    movaps  xmm1, [r8+BD_Q]
    xorps   xmm1, [rip+rx_sign]
    call    q_mul
    add     rsp, 8
    pop     rdi
    movaps  [rdi+JR_Q0], xmm0
8:  inc     r12d
    jmp     1b
9:  add     rsp, 32
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# body_of_uid(edi=object uid) -> eax = its body, or -1
body_of_uid:
    xor     eax, eax
    mov     rcx, [rip+rb_bd]
1:  mov     edx, [rip+rb_nb]
    dec     edx
    cmp     eax, edx
    jae     8f
    mov     rdx, [rcx+BD_OBJ]
    test    rdx, rdx
    jz      2f
    cmp     [rdx+OB_UID], edi
    je      9f
2:  add     rcx, BD_SZ
    inc     eax
    jmp     1b
8:  mov     eax, -1
9:  ret

# -----------------------------------------------------------------------------
# A step
# -----------------------------------------------------------------------------
# awake_mover(rax=body) -> ZF clear when it moves and is awake
.macro AWAKE body
    cmp     dword ptr [\body+BD_TYPE], 1
    jne     98f
    cmp     dword ptr [\body+BD_ASLEEP], 0
98:
.endm

rb_step:
    push    rbx
    sub     rsp, 16
    inc     dword ptr [rip+rb_stepno]
    call    now_ns
    mov     rbx, rax
    call    ccd_mark                    # where the moving bodies begin
    call    broad                       # pairs of parts: manifolds kept / made
    xor     edi, edi
    call    rb_lap
    call    compact                     # the rest go
    mov     edi, 5
    call    rb_lap
    lea     rdi, [rip+narrow_job]       # contacts, in parallel
    xor     esi, esi
    mov     edx, [rip+rb_nmf]
    mov     ecx, 16
    test    edx, edx
    jz      1f
    call    parallel_for
1:  mov     edi, 1
    call    rb_lap
    call    islands
    mov     edi, 2
    call    rb_lap
    lea     rdi, [rip+island_job]       # each island solved, in parallel
    xor     esi, esi
    mov     edx, [rip+rb_nisl]
    mov     ecx, 1
    test    edx, edx
    jz      2f
    call    parallel_for
    mov     [rsp], rbx                  # (the lap's start)
    xor     ebx, ebx                    # the big ones, one at a time, each
21: cmp     ebx, [rip+rb_nisl]          #  across the workers
    jae     22f
    mov     rax, [rip+rb_iaw]
    cmp     dword ptr [rax+rbx*4], 0
    je      23f
    mov     edi, ebx
    call    isl_big
    jz      23f
    mov     edi, ebx
    call    solve_big
23: inc     ebx
    jmp     21b
22: mov     rbx, [rsp]
2:  call    jr_breaks                   # joints pulled too hard: broken
    call    ccd_pass                    # fast ones: stopped short of statics
    mov     edi, 3
    call    rb_lap
    add     rsp, 16
    pop     rbx
    ret
# ccd_mark - each moving body's place at the step's start
ccd_mark:
    xor     ecx, ecx
1:  cmp     ecx, [rip+rb_nb]
    jae     9f
    BODY    rax, rcx
    cmp     dword ptr [rax+BD_TYPE], 1
    jne     2f
    movaps  xmm0, [rax+BD_POS]
    movaps  [rax+BD_PP], xmm0
    movaps  xmm0, [rax+BD_Q]
    movaps  [rax+BD_PQ], xmm0
2:  inc     ecx
    jmp     1b
9:  ret

# ccd_pass - continuous collision for fast bodies: a moving body that went
#   more than half its size this step, against each static part it has a
#   manifold with: conservative advancement from where it began (the gap
#   over the most it can close: its speed along the normal and its turning
#   times its reach) to the first time of impact; it is put there (a
#   little short), its velocity kept - the next step's contact stops it
.equ CC_PXA,    0                       # (the frame)
.equ CC_PXB,    80
.equ CC_RES,    160
.equ CC_ROWS,   224                     # rows at time t
.equ CC_POS,    272
.equ CC_Q,      288
.equ CC_T,      304                     # its earliest impact so far
.equ CC_SZ,     320
ccd_pass:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    and     rsp, -16
    sub     rsp, CC_SZ
    xor     r12d, r12d                  # manifold
1:  cmp     r12d, [rip+rb_nmf]
    jae     9f
    mov     rax, r12
    shl     rax, 5
    add     rax, [rip+rb_mx]
    mov     ecx, [rax+MX_A]
    mov     edx, [rax+MX_B]
    BODY    r13, rcx                    # the moving one (r13), the static
    BODY    r14, rdx                    #  (r14)
    mov     r8d, [rax+MX_PA]
    mov     r9d, [rax+MX_PB]
    cmp     dword ptr [r13+BD_TYPE], 1
    jne     11f
    cmp     dword ptr [r14+BD_TYPE], 2
    je      12f
    jmp     8f
11: cmp     dword ptr [r14+BD_TYPE], 1
    jne     8f
    cmp     dword ptr [r13+BD_TYPE], 2
    jne     8f
    xchg    r13, r14
    xchg    r8d, r9d
12: mov     [rsp+CC_T+4], r8d           # (its part, the static's)
    mov     [rsp+CC_T+8], r9d
    cmp     dword ptr [r13+BD_ASLEEP], 0
    jne     8f
    imul    rax, r8, PT_SZ              # fast: moved more than half its
    add     rax, [rip+rb_pt]            #  smallest half (+ radius)
    movaps  xmm0, [rax+PT_HALF]         # min(x, y, z) + r, halved
    movaps  xmm1, xmm0
    shufps  xmm1, xmm1, 0x55
    minss   xmm0, xmm1
    movaps  xmm1, [rax+PT_HALF]
    shufps  xmm1, xmm1, 0xAA
    minss   xmm0, xmm1
    addss   xmm0, [rax+PT_RAD]
    mulss   xmm0, [rip+rx_half]
    movaps  xmm1, [r13+BD_POS]
    subps   xmm1, [r13+BD_PP]
    DOT3    xmm1, xmm1
    mulss   xmm0, xmm0
    comiss  xmm1, xmm0
    jbe     8f
    call    cc_toi                      # (r13 moving, r14 static; parts in
    comiss  xmm0, [rip+rx_one]          #  the frame) -> xmm0 = TOI (>= 1:
    jae     8f                          #  none)
    mov     rdi, r13                    # there (its pose at TOI), velocity
    call    cc_place                    #  kept
8:  inc     r12d
    jmp     1b
9:  lea     rsp, [rbp-40]
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret

# cc_toi -> xmm0 = the first time (0..1 of the step) the moving part comes
#   within 5 mm of the static one (>= 1: not this step, or touching it
#   from the start)
cc_toi:
    push    rbx
    push    r15
    sub     rsp, 8                      # (the caller's frame at +32)
    xorps   xmm0, xmm0
    movss   [rsp+32+CC_T], xmm0         # t
    mov     ebx, 24                     # (iterations)
1:  movss   xmm0, [rsp+32+CC_T]
    call    cc_pose_here
    lea     rdi, [rsp+32+CC_PXA]        # the moving part at t
    lea     rsi, [rsp+32+CC_ROWS]
    lea     rdx, [rsp+32+CC_POS]
    mov     ecx, [rsp+32+CC_T+4]
    imul    rcx, rcx, PT_SZ
    add     rcx, [rip+rb_pt]
    call    px_place
    lea     rdi, [rsp+32+CC_PXB]        # the static one
    lea     rsi, [r14+BD_R]
    lea     rdx, [r14+BD_POS]
    mov     ecx, [rsp+32+CC_T+8]
    imul    rcx, rcx, PT_SZ
    add     rcx, [rip+rb_pt]
    call    px_place
    lea     rdi, [rsp+32+CC_PXA]
    lea     rsi, [rsp+32+CC_PXB]
    lea     rdx, [rsp+32+CC_RES]
    call    collide
    movss   xmm0, [rsp+32+CC_RES+CR_SEP]
    comiss  xmm0, [rip+rx_ccd_tol]
    ja      2f
    cmp     ebx, 24                     # touching where it began (resting,
    je      7f                          #  sliding on it): its contact's, not
    jmp     8f                          #  this; later: there
2:
    movaps  xmm1, [r13+BD_POS]          # the most it closes over the step:
    subps   xmm1, [r13+BD_PP]           #  its move along n + its turn x reach
    DOT3    xmm1, [rsp+32+CC_RES+CR_N]
    andps   xmm1, [rip+rx_abs]
    movaps  xmm2, [r13+BD_W]
    DOT3    xmm2, xmm2
    sqrtss  xmm2, xmm2
    mulss   xmm2, [rip+rb_dt]
    mov     eax, [rsp+32+CC_T+4]
    imul    rax, rax, PT_SZ
    add     rax, [rip+rb_pt]
    movaps  xmm3, [rax+PT_HALF]
    DOT3    xmm3, xmm3
    sqrtss  xmm3, xmm3
    addss   xmm3, [rax+PT_RAD]
    movaps  xmm4, [rax+PT_OFF]
    DOT3    xmm4, xmm4
    sqrtss  xmm4, xmm4
    addss   xmm3, xmm4
    mulss   xmm2, xmm3
    addss   xmm1, xmm2
    comiss  xmm1, [rip+rx_tiny]
    jbe     7f                          # not closing: no impact
    divss   xmm0, xmm1                  # dt = gap / closing
    addss   xmm0, [rsp+32+CC_T]
    movss   [rsp+32+CC_T], xmm0
    comiss  xmm0, [rip+rx_one]
    jae     7f
    dec     ebx
    jnz     1b
8:  movss   xmm0, [rsp+32+CC_T]
    jmp     9f
7:  movss   xmm0, [rip+rx_two]          # none
9:  add     rsp, 8
    pop     r15
    pop     rbx
    ret
# cc_pose_here(xmm0=t; r13 the body; ccd_pass's frame at rsp+8+32) - its
#   rows and centre at t of the step (position lerped, orientation nlerped)
cc_pose_here:
    movss   xmm7, xmm0
    shufps  xmm7, xmm7, 0
    movaps  xmm0, [r13+BD_POS]
    subps   xmm0, [r13+BD_PP]
    mulps   xmm0, xmm7
    addps   xmm0, [r13+BD_PP]
    andps   xmm0, [rip+rx_xyz]
    movaps  [rsp+8+32+CC_POS], xmm0
    movaps  xmm1, [r13+BD_PQ]
    movaps  xmm2, [r13+BD_Q]
    movaps  xmm3, xmm1
    dpps    xmm3, xmm2, 0xF1
    xorps   xmm4, xmm4
    comiss  xmm3, xmm4
    jae     1f
    xorps   xmm2, [rip+rx_sign4]
1:  subps   xmm2, xmm1
    mulps   xmm2, xmm7
    addps   xmm2, xmm1
    movaps  xmm3, xmm2
    dpps    xmm3, xmm3, 0xF1
    sqrtss  xmm3, xmm3
    shufps  xmm3, xmm3, 0
    divps   xmm2, xmm3
    movaps  [rsp+8+32+CC_Q], xmm2
    lea     rdi, [rsp+8+32+CC_Q]
    lea     rsi, [rsp+8+32+CC_ROWS]
    jmp     q_rows

# cc_place(rdi=body; xmm0 = TOI; the caller's frame at rsp+8) - the body at
#   its pose a little before the impact (it keeps its velocity)
cc_place:
    push    rbx
    sub     rsp, 16
    mov     rbx, rdi
    subss   xmm0, [rip+rx_ccd_back]
    xorps   xmm1, xmm1
    maxss   xmm0, xmm1
    movss   xmm7, xmm0
    shufps  xmm7, xmm7, 0
    movaps  xmm0, [rbx+BD_POS]
    subps   xmm0, [rbx+BD_PP]
    mulps   xmm0, xmm7
    addps   xmm0, [rbx+BD_PP]
    andps   xmm0, [rip+rx_xyz]
    movaps  [rbx+BD_POS], xmm0
    movaps  xmm1, [rbx+BD_PQ]
    movaps  xmm2, [rbx+BD_Q]
    movaps  xmm3, xmm1
    dpps    xmm3, xmm2, 0xF1
    xorps   xmm4, xmm4
    comiss  xmm3, xmm4
    jae     1f
    xorps   xmm2, [rip+rx_sign4]
1:  subps   xmm2, xmm1
    mulps   xmm2, xmm7
    addps   xmm2, xmm1
    movaps  xmm3, xmm2
    dpps    xmm3, xmm3, 0xF1
    sqrtss  xmm3, xmm3
    shufps  xmm3, xmm3, 0
    divps   xmm2, xmm3
    movaps  [rbx+BD_Q], xmm2
    lea     rdi, [rbx+BD_Q]
    lea     rsi, [rbx+BD_R]
    call    q_rows
    mov     rdi, rbx
    call    body_update
    add     rsp, 16
    pop     rbx
    ret

# rb_lap(edi=part; rbx = the time it began) - its time added; rbx = now
rb_lap:
    push    rdi
    call    now_ns
    pop     rdi
    lea     rcx, [rip+rb_tns]
    mov     rdx, rax
    sub     rdx, rbx
    add     [rcx+rdi*8], rdx
    mov     rbx, rax
    ret

# mf_hash(edi=part a, esi=part b) -> eax = the slot to start at
mf_hash:
    mov     eax, edi                    # (a << 32 | b) x a large odd number,
    shl     rax, 32                     #  its high bits folded down
    mov     ecx, esi
    or      rax, rcx
    mov     rcx, 0x9E3779B97F4A7C15
    imul    rax, rcx
    mov     rcx, rax
    shr     rcx, 29
    xor     rax, rcx
    and     eax, [rip+rb_hmask]
    ret

# hf_slot(edi=manifold) -> rax = its slot in the hash (it is there)
hf_slot:
    push    rbx
    mov     ebx, edi
    mov     rax, rbx
    shl     rax, 5
    add     rax, [rip+rb_mx]
    mov     edi, [rax+MX_PA]
    mov     esi, [rax+MX_PB]
    call    mf_hash
    mov     rcx, [rip+rb_hs]
    lea     edx, [rbx+1]
1:  cmp     [rcx+rax*4], edx
    je      9f
    inc     eax
    and     eax, [rip+rb_hmask]
    jmp     1b
9:  pop     rbx
    ret

# hf_delete(eax=slot) - that slot emptied, the entries after it shifted back
#   (linear probing: no gaps between an entry and its home)
hf_delete:
    push    rbx
    push    r12
    push    r13
    mov     r12d, eax                   # i: the hole
    mov     rbx, [rip+rb_hs]
    mov     dword ptr [rbx+r12*4], 0
    mov     r13d, r12d                  # j
1:  inc     r13d
    and     r13d, [rip+rb_hmask]
    mov     edx, [rbx+r13*4]
    test    edx, edx
    jz      9f
    dec     edx                         # its home k
    shl     rdx, 5
    add     rdx, [rip+rb_mx]
    mov     edi, [rdx+MX_PA]
    mov     esi, [rdx+MX_PB]
    call    mf_hash
    # it may move to i when k is not cyclically in (i, j]
    mov     ecx, r13d
    sub     ecx, eax
    and     ecx, [rip+rb_hmask]         # (j - k) mod n
    mov     edx, r13d
    sub     edx, r12d
    and     edx, [rip+rb_hmask]         # (j - i) mod n
    cmp     ecx, edx
    jb      1b                          # its home is after the hole: stays
    mov     eax, [rbx+r13*4]
    mov     [rbx+r12*4], eax
    mov     dword ptr [rbx+r13*4], 0
    mov     r12d, r13d
    jmp     1b
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# mf_get(edi=body a, esi=body b, edx=part a, ecx=part b) - the manifold of
#   the two parts kept this step (made when new; none when full)
mf_get:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r12d, edi
    mov     r13d, esi
    mov     r14d, edx
    mov     r15d, ecx
    mov     edi, edx
    mov     esi, ecx
    call    mf_hash
    mov     rcx, [rip+rb_hs]
1:  mov     edx, [rcx+rax*4]
    test    edx, edx
    jz      3f
    dec     edx
    shl     rdx, 5
    add     rdx, [rip+rb_mx]
    cmp     [rdx+MX_PA], r14d
    jne     2f
    cmp     [rdx+MX_PB], r15d
    jne     2f
    mov     ecx, [rip+rb_stepno]
    mov     [rdx+MX_KEEP], ecx
    jmp     9f
2:  inc     eax
    and     eax, [rip+rb_hmask]
    jmp     1b
3:  mov     edx, [rip+rb_nmf]           # a new one (room, and the hash
    mov     r8d, [rip+rb_hmask]         #  at most half full)
    shr     r8d, 1
    cmp     edx, r8d
    jae     32f
    cmp     edx, [rip+rb_capmf]
    jb      31f
32:
    inc     dword ptr [rip+rb_mffull]   # (none left: counted, rbinfo(14);
    cmp     dword ptr [rip+rb_mffull], 1    #  said once)
    jne     9f
    lea     rdi, [rip+s_rb_mffull]
    call    log_line
    jmp     9f
31:
    inc     dword ptr [rip+rb_nmf]
    lea     r8d, [rdx+1]
    mov     [rcx+rax*4], r8d
    imul    rbx, rdx, MF_SZ
    add     rbx, [rip+rb_mf]
    mov     [rbx+MF_A], r12d
    mov     [rbx+MF_B], r13d
    mov     [rbx+MF_PA], r14d
    mov     [rbx+MF_PB], r15d
    mov     dword ptr [rbx+MF_N], 0
    shl     rdx, 5
    add     rdx, [rip+rb_mx]
    mov     [rdx+MX_A], r12d
    mov     [rdx+MX_B], r13d
    mov     [rdx+MX_PA], r14d
    mov     [rdx+MX_PB], r15d
    mov     dword ptr [rdx+MX_N], 0
    mov     ecx, [rip+rb_stepno]
    mov     [rdx+MX_KEEP], ecx
    BODY    r8, r12                     # friction sqrt(fa fb), bounce max
    BODY    r9, r13
    movss   xmm0, [r8+BD_FRIC]
    mulss   xmm0, [r9+BD_FRIC]
    sqrtss  xmm0, xmm0
    movss   [rbx+MF_FRIC], xmm0
    movss   xmm0, [r8+BD_REST]
    maxss   xmm0, [r9+BD_REST]
    movss   [rbx+MF_REST], xmm0
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# broad - pairs of bodies whose bounds meet, through a hash grid: the cell
#   about the size of a moving body (their average); each body in the cells
#   its bounds cover (bodies more than twice that size go in a list and are
#   tested against every body); the entries counting-sorted by bucket; in a
#   bucket, two entries of the same cell are a pair when that cell is where
#   their bounds' overlap begins (each pair once). The order is the bodies'
#   own (the same every run)
.equ GE_KEY,    0                       # an entry: its cell (packed),
.equ GE_BODY,   8                       #  the body,
.equ GE_B,      12                      #  the bucket
broad:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    and     rsp, -16
    sub     rsp, 64
    mov     r13, [rip+rb_bd]
    # the cell: the moving bodies' average size
    xorps   xmm4, xmm4
    xor     ecx, ecx
    xor     edx, edx
1:  cmp     ecx, [rip+rb_nb]
    jae     2f
    imul    rax, rcx, BD_SZ
    cmp     dword ptr [r13+rax+BD_TYPE], 1
    jne     11f
    movaps  xmm0, [r13+rax+BD_MAX]
    subps   xmm0, [r13+rax+BD_MIN]
    call    gr_ext
    addss   xmm4, xmm0
    inc     edx
11: inc     ecx
    jmp     1b
2:  test    edx, edx
    jz      .Lbr_out                    # nothing moves: no pairs
    cvtsi2ss xmm0, edx
    divss   xmm4, xmm0
    maxss   xmm4, [rip+rx_gmin]
    movss   [rip+rb_gcs], xmm4
    movss   xmm0, [rip+rx_one]
    divss   xmm0, xmm4
    movss   [rip+rb_ginv], xmm0
    # entries; the buckets counted
    mov     rdi, [rip+rb_gtab]
    mov     ecx, [rip+rb_gmask]
    add     ecx, 2
    xor     eax, eax
    rep     stosd
    mov     dword ptr [rip+rb_gn], 0
    mov     dword ptr [rip+rb_gnbig], 0
    mov     dword ptr [rip+rb_npair], 0
    xor     r12d, r12d
3:  cmp     r12d, [rip+rb_nb]
    jae     4f
    imul    rbx, r12, BD_SZ
    add     rbx, r13
    movaps  xmm0, [rbx+BD_MAX]
    subps   xmm0, [rbx+BD_MIN]
    call    gr_ext
    movss   xmm1, [rip+rb_gcs]
    addss   xmm1, xmm1
    comiss  xmm0, xmm1
    jbe     31f
    mov     eax, [rip+rb_gnbig]         # too big: the list
    mov     rcx, [rip+rb_gbig]
    mov     [rcx+rax*4], r12d
    inc     dword ptr [rip+rb_gnbig]
    jmp     39f
31: movss   xmm2, [rip+rb_ginv]         # its cells
    shufps  xmm2, xmm2, 0
    movaps  xmm0, [rbx+BD_MIN]
    mulps   xmm0, xmm2
    roundps xmm0, xmm0, 1
    cvttps2dq xmm0, xmm0
    movdqa  [rsp], xmm0                 # i0 j0 k0
    movaps  xmm0, [rbx+BD_MAX]
    mulps   xmm0, xmm2
    roundps xmm0, xmm0, 1
    cvttps2dq xmm0, xmm0
    movdqa  [rsp+16], xmm0              # i1 j1 k1
    mov     r14d, [rsp]                 # i
32: cmp     r14d, [rsp+16]
    jg      39f
    mov     r15d, [rsp+4]               # j
33: cmp     r15d, [rsp+20]
    jg      38f
    mov     eax, [rsp+8]                # k
    mov     [rsp+32], eax
34: mov     eax, [rsp+32]
    cmp     eax, [rsp+24]
    jg      37f
    mov     edi, r14d
    mov     esi, r15d
    mov     edx, eax
    call    gr_key                      # rax key, edx bucket
    mov     ecx, [rip+rb_gn]
    shl     rcx, 4
    add     rcx, [rip+rb_gent]
    mov     [rcx+GE_KEY], rax
    mov     [rcx+GE_BODY], r12d
    mov     [rcx+GE_B], edx
    mov     rcx, [rip+rb_gtab]
    inc     dword ptr [rcx+rdx*4+4]
    inc     dword ptr [rip+rb_gn]
    inc     dword ptr [rsp+32]
    jmp     34b
37: inc     r15d
    jmp     33b
38: inc     r14d
    jmp     32b
39: inc     r12d
    jmp     3b
4:  mov     rcx, [rip+rb_gtab]          # starts; then a stable counting sort
    mov     edx, [rip+rb_gmask]
    inc     edx
    xor     eax, eax
    xor     r8d, r8d
41: cmp     r8d, edx
    ja      42f
    add     eax, [rcx+r8*4]
    mov     [rcx+r8*4], eax
    inc     r8d
    jmp     41b
42: xor     r8d, r8d                    # (tab[b] the cursor; afterwards
43: cmp     r8d, [rip+rb_gn]            #  tab[b] = b's end = b+1's start)
    jae     44f
    mov     rsi, r8
    shl     rsi, 4
    add     rsi, [rip+rb_gent]
    mov     eax, [rsi+GE_B]
    mov     r9d, [rcx+rax*4]
    inc     dword ptr [rcx+rax*4]
    shl     r9, 4
    add     r9, [rip+rb_gsrt]
    movaps  xmm0, [rsi]
    movaps  [r9], xmm0
    inc     r8d
    jmp     43b
44: # the buckets' pairs, in parallel: counted in chunks of 256 buckets,
    #   then written where each chunk's count puts them (bucket order)
    mov     eax, [rip+rb_gmask]
    shr     eax, 8
    inc     eax
    mov     [rsp+40], eax               # chunks
    lea     rdi, [rip+gr_count_job]
    xor     esi, esi
    mov     edx, eax
    mov     ecx, 1
    call    parallel_for
    mov     rcx, [rip+rb_gcc]           # counts -> starts
    xor     eax, eax
    xor     edx, edx
441:cmp     edx, [rsp+40]
    jae     442f
    mov     r8d, [rcx+rdx*4]
    mov     [rcx+rdx*4], eax
    add     eax, r8d
    inc     edx
    jmp     441b
442:cmp     eax, [rip+rb_cappair]       # (no room: the list stays empty and
    jbe     443f                        #  the pairs go one by one)
    xor     eax, eax
    mov     [rip+rb_npair], eax
    lea     rdi, [rip+gr_slow_job]
    xor     esi, esi
    mov     edx, [rsp+40]
    call    gr_slow_job
    jmp     5f
443:mov     [rip+rb_npair], eax
    lea     rdi, [rip+gr_write_job]
    xor     esi, esi
    mov     edx, [rsp+40]
    mov     ecx, 1
    call    parallel_for
5:  # the big ones: against every body (two big ones once)
    xor     r12d, r12d
51: cmp     r12d, [rip+rb_gnbig]
    jae     .Lbr_pairs
    mov     rax, [rip+rb_gbig]
    mov     r14d, [rax+r12*4]
    xor     r15d, r15d
52: cmp     r15d, [rip+rb_nb]
    jae     59f
    cmp     r15d, r14d
    je      58f
    BODY    rbx, r14
    BODY    rdi, r15
    movaps  xmm0, [rdi+BD_MAX]          # (the other big too: only from the
    subps   xmm0, [rdi+BD_MIN]          #  lower one)
    call    gr_ext
    movss   xmm1, [rip+rb_gcs]
    addss   xmm1, xmm1
    comiss  xmm0, xmm1
    jbe     53f
    cmp     r15d, r14d
    jb      58f
53: mov     rsi, rdi
    mov     rdi, rbx
    mov     edx, r14d
    mov     ecx, r15d
    call    gr_pair
58: inc     r15d
    jmp     52b
59: inc     r12d
    jmp     51b
.Lbr_pairs:
    # the pairs' manifolds looked up in parallel (kept); the new ones (and
    #   bodies of several parts) made after, in the list's order
    lea     rdi, [rip+pair_job]
    xor     esi, esi
    mov     edx, [rip+rb_npair]
    mov     ecx, 256
    test    edx, edx
    jz      .Lbr_out
    call    parallel_for
    xor     r12d, r12d
6:  cmp     r12d, [rip+rb_npair]
    jae     .Lbr_out
    mov     rax, [rip+rb_pairs]
    mov     ecx, [rax+r12*8+4]
    test    ecx, ecx
    jns     61f
    and     ecx, 0x7fffffff
    mov     edx, [rax+r12*8]
    BODY    rdi, rdx
    BODY    rsi, rcx
    call    pair_parts
61: inc     r12d
    jmp     6b
.Lbr_out:
    lea     rsp, [rbp-40]
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret

# pair_job(rdi=ctx, esi=begin, edx=end) - pairs of one part each whose
#   manifold exists: seen this step; the rest marked (B | 1 << 31)
pair_job:
    push    rbx
    push    r12
    push    r13
    mov     r12d, esi
    mov     r13d, edx
1:  cmp     r12d, r13d
    jae     9f
    mov     rbx, [rip+rb_pairs]
    lea     rbx, [rbx+r12*8]
    mov     eax, [rbx]
    BODY    r8, rax
    mov     eax, [rbx+4]
    BODY    r9, rax
    cmp     dword ptr [r8+BD_BVH], 0    # a mesh: its triangles in reach
    jne     5f                          #  looked up (new ones: after)
    cmp     dword ptr [r9+BD_BVH], 0
    jne     5f
    cmp     dword ptr [r8+BD_NP], 1
    jne     8f
    cmp     dword ptr [r9+BD_NP], 1
    jne     8f
    mov     edi, [r8+BD_P0]
    mov     esi, [r9+BD_P0]
    mov     r10d, edi
    mov     r11d, esi
    call    mf_hash
    mov     rcx, [rip+rb_hs]
2:  mov     edx, [rcx+rax*4]
    test    edx, edx
    jz      8f                          # none yet
    dec     edx
    shl     rdx, 5
    add     rdx, [rip+rb_mx]
    cmp     [rdx+MX_PA], r10d
    jne     3f
    cmp     [rdx+MX_PB], r11d
    jne     3f
    mov     ecx, [rip+rb_stepno]
    mov     [rdx+MX_KEEP], ecx
    jmp     7f
3:  inc     eax
    and     eax, [rip+rb_hmask]
    jmp     2b
8:  or      dword ptr [rbx+4], 0x80000000
7:  inc     r12d
    jmp     1b
5:  mov     rdi, r8
    mov     rsi, r9
    mov     edx, [rbx]
    mov     ecx, [rbx+4]
    mov     r8d, 1
    call    pp_tree
    test    eax, eax
    jnz     8b
    jmp     7b
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# gr_count_job / gr_write_job(rdi=ctx, esi=first chunk, edx=end) - each
#   chunk's pairs counted (rb_gcc) / written at its start (rb_gcc);
#   gr_slow_job: paired at once (sequential)
gr_count_job:
    push    rbx
    push    r12
    push    r13
    mov     r12d, esi
    mov     r13d, edx
1:  cmp     r12d, r13d
    jae     9f
    mov     edi, r12d
    xor     esi, esi
    call    gr_scan
    mov     rcx, [rip+rb_gcc]
    mov     [rcx+r12*4], eax
    inc     r12d
    jmp     1b
9:  pop     r13
    pop     r12
    pop     rbx
    ret
gr_write_job:
    push    rbx
    push    r12
    push    r13
    mov     r12d, esi
    mov     r13d, edx
1:  cmp     r12d, r13d
    jae     9f
    mov     rcx, [rip+rb_gcc]
    mov     esi, [rcx+r12*4]
    shl     rsi, 3
    add     rsi, [rip+rb_pairs]
    mov     edi, r12d
    call    gr_scan
    inc     r12d
    jmp     1b
9:  pop     r13
    pop     r12
    pop     rbx
    ret
gr_slow_job:
    push    rbx
    push    r12
    push    r13
    mov     r12d, esi
    mov     r13d, edx
1:  cmp     r12d, r13d
    jae     9f
    mov     edi, r12d
    mov     rsi, -1
    call    gr_scan
    inc     r12d
    jmp     1b
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# gr_scan(edi=chunk, rsi=out (0: count only; -1: pair_parts at once)) ->
#   eax = the pairs in its 256 buckets: two entries of one cell where their
#   bounds' overlap begins, passing gr_test
gr_scan:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    and     rsp, -16
    sub     rsp, 80
    mov     [rsp+64], rsi
    mov     dword ptr [rsp+72], 0       # found
    shl     edi, 8
    mov     r12d, edi                   # bucket
    lea     eax, [rdi+256]
    mov     ecx, [rip+rb_gmask]
    inc     ecx
    cmp     eax, ecx
    jbe     1f
    mov     eax, ecx
1:  mov     [rsp+76], eax               # end
    xor     r14d, r14d                  # its start: the one before's end
    test    r12d, r12d
    jz      2f
    mov     rcx, [rip+rb_gtab]
    mov     r14d, [rcx+r12*4-4]
2:  cmp     r12d, [rsp+76]
    jae     9f
    mov     rcx, [rip+rb_gtab]
    mov     r15d, [rcx+r12*4]           # its end
    mov     [rsp+40], r15d
    lea     eax, [r14+1]
    cmp     eax, r15d
    jae     8f
    mov     [rsp+44], r14d              # i
3:  mov     eax, [rsp+44]
    inc     eax
    cmp     eax, [rsp+40]
    jae     8f
    mov     [rsp+48], eax               # j
4:  mov     eax, [rsp+48]
    cmp     eax, [rsp+40]
    jae     7f
    mov     rsi, [rip+rb_gsrt]
    mov     ecx, [rsp+44]
    shl     rcx, 4
    mov     edx, eax
    shl     rdx, 4
    mov     rax, [rsi+rcx+GE_KEY]
    cmp     rax, [rsi+rdx+GE_KEY]
    jne     6f
    mov     [rsp+56], rax
    mov     edi, [rsi+rcx+GE_BODY]
    mov     r8d, [rsi+rdx+GE_BODY]
    mov     [rsp+32], edi
    mov     [rsp+36], r8d
    BODY    rbx, rdi
    BODY    r13, r8
    movaps  xmm0, [rbx+BD_MIN]          # where the overlap begins: this cell?
    maxps   xmm0, [r13+BD_MIN]
    movss   xmm2, [rip+rb_ginv]
    shufps  xmm2, xmm2, 0
    mulps   xmm0, xmm2
    roundps xmm0, xmm0, 1
    cvttps2dq xmm0, xmm0
    movdqa  [rsp], xmm0
    mov     edi, [rsp]
    mov     esi, [rsp+4]
    mov     edx, [rsp+8]
    call    gr_key
    cmp     rax, [rsp+56]
    jne     6f
    mov     rdi, rbx
    mov     rsi, r13
    call    gr_test
    test    eax, eax
    jz      6f
    mov     edx, [rsp+32]               # the lower first
    mov     ecx, [rsp+36]
    cmp     edx, ecx
    jb      51f
    xchg    edx, ecx
51: mov     rax, [rsp+64]
    test    rax, rax
    jz      53f
    cmp     rax, -1
    jne     52f
    BODY    rdi, rdx
    BODY    rsi, rcx
    call    pair_parts
    jmp     53f
52: mov     [rax], edx
    mov     [rax+4], ecx
    add     qword ptr [rsp+64], 8
53: inc     dword ptr [rsp+72]
6:  inc     dword ptr [rsp+48]
    jmp     4b
7:  inc     dword ptr [rsp+44]
    jmp     3b
8:  mov     r14d, r15d
    inc     r12d
    jmp     2b
9:  mov     eax, [rsp+72]
    lea     rsp, [rbp-40]
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret

# gr_test(rdi=body, rsi=body) -> eax = 1 when their bounds meet, at least
#   one moves and no joint ties them
gr_test:
    sub     rsp, 8
    xor     eax, eax
    movaps  xmm0, [rdi+BD_MIN]
    cmpleps xmm0, [rsi+BD_MAX]
    movaps  xmm1, [rsi+BD_MIN]
    cmpleps xmm1, [rdi+BD_MAX]
    andps   xmm0, xmm1
    movmskps ecx, xmm0
    and     ecx, 7
    cmp     ecx, 7
    jne     9f
    cmp     dword ptr [rdi+BD_TYPE], 1
    je      1f
    cmp     dword ptr [rsi+BD_TYPE], 1
    jne     9f
1:  mov     ecx, [rdi+BD_GRP]           # groups: either ignoring the other's
    mov     edx, [rsi+BD_GRP]           #  group, no contact
    mov     r8d, ecx
    shr     r8d, 16
    and     r8d, edx
    test    r8w, r8w
    jnz     9f
    mov     r8d, edx
    shr     r8d, 16
    and     r8d, ecx
    test    r8w, r8w
    jnz     9f
    mov     eax, 1
    cmp     dword ptr [rdi+BD_JOINT], 0
    je      9f
    cmp     dword ptr [rsi+BD_JOINT], 0
    je      9f
    call    jointed
    xor     eax, 1
9:  add     rsp, 8
    ret

# gr_ext(xmm0=size (vec4)) -> xmm0 = its largest of x y z
gr_ext:
    movaps  xmm1, xmm0
    shufps  xmm1, xmm1, 0x55
    maxss   xmm0, xmm1
    movhlps xmm1, xmm0
    maxss   xmm0, xmm1
    ret

# gr_key(edi=i, esi=j, edx=k) -> rax = the cell packed, edx = its bucket
gr_key:
    mov     eax, edi
    add     eax, 0x100000
    and     eax, 0x1FFFFF
    mov     ecx, esi
    add     ecx, 0x100000
    and     ecx, 0x1FFFFF
    shl     rcx, 21
    or      rax, rcx
    mov     ecx, edx
    add     ecx, 0x100000
    and     ecx, 0x1FFFFF
    shl     rcx, 42
    or      rax, rcx
    mov     rdx, 0x9E3779B97F4A7C15
    imul    rdx, rax
    mov     ecx, [rip+rb_gsh]
    shr     rdx, cl
    ret

# gr_pair(rdi=body, rsi=body, edx, ecx = their indices) - when their
#   bounds meet, at least one moves and no joint ties them: on the list
#   (the lower first)
gr_pair:
    sub     rsp, 8
    movaps  xmm0, [rdi+BD_MIN]
    cmpleps xmm0, [rsi+BD_MAX]
    movaps  xmm1, [rsi+BD_MIN]
    cmpleps xmm1, [rdi+BD_MAX]
    andps   xmm0, xmm1
    movmskps eax, xmm0
    and     eax, 7
    cmp     eax, 7
    jne     9f
    cmp     dword ptr [rdi+BD_TYPE], 1
    je      1f
    cmp     dword ptr [rsi+BD_TYPE], 1
    jne     9f
1:  mov     r8d, [rdi+BD_GRP]           # groups (as gr_test)
    mov     r9d, [rsi+BD_GRP]
    mov     r10d, r8d
    shr     r10d, 16
    and     r10d, r9d
    test    r10w, r10w
    jnz     9f
    mov     r10d, r9d
    shr     r10d, 16
    and     r10d, r8d
    test    r10w, r10w
    jnz     9f
    cmp     dword ptr [rdi+BD_JOINT], 0
    je      2f
    cmp     dword ptr [rsi+BD_JOINT], 0
    je      2f
    push    rdi
    push    rsi
    push    rdx
    push    rcx
    call    jointed
    pop     rcx
    pop     rdx
    pop     rsi
    pop     rdi
    test    eax, eax
    jnz     9f
2:  cmp     edx, ecx
    jb      21f
    xchg    edx, ecx
21: mov     eax, [rip+rb_npair]
    cmp     eax, [rip+rb_cappair]
    jae     22f
    mov     r8, [rip+rb_pairs]
    mov     [r8+rax*8], edx
    mov     [r8+rax*8+4], ecx
    inc     dword ptr [rip+rb_npair]
    jmp     9f
22: call    pair_parts                  # (the list full: now)
9:  add     rsp, 8
    ret

# jointed(rdi=body, rsi=body) -> eax = 1 when a joint ties them
jointed:
    mov     rax, rdi
    sub     rax, [rip+rb_bd]
    xor     edx, edx
    mov     ecx, BD_SZ
    div     rcx
    mov     r8d, eax
    mov     rax, rsi
    sub     rax, [rip+rb_bd]
    xor     edx, edx
    div     rcx
    mov     r9d, eax
    mov     rdx, [rip+rb_jr]
    xor     ecx, ecx
1:  cmp     ecx, [rip+rb_njr]
    jae     8f
    test    dword ptr [rdx+JR_FL], 4    # (broken: no longer)
    jnz     3f
    mov     eax, [rdx+JR_A]
    mov     r10d, [rdx+JR_B]
    cmp     eax, r8d
    jne     2f
    cmp     r10d, r9d
    je      9f
2:  cmp     eax, r9d
    jne     3f
    cmp     r10d, r8d
    je      9f
3:  add     rdx, JR_SZ
    inc     ecx
    jmp     1b
8:  xor     eax, eax
    ret
9:  mov     eax, 1
    ret

# body_index(rdi=body) -> eax
.macro BIDX reg, body
    mov     rax, \body
    sub     rax, [rip+rb_bd]
    xor     edx, edx
    mov     ecx, BD_SZ
    div     rcx
    mov     \reg, eax
.endm

# pair_parts(rdi=body, rsi=body) - their parts whose bounds meet: manifolds
pair_parts:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    and     rsp, -16
    sub     rsp, 96
    BIDX    r8d, rdi
    BIDX    r9d, rsi
    cmp     r8d, r9d                    # the lower first
    jb      1f
    xchg    rdi, rsi
    xchg    r8d, r9d
1:  mov     rbx, rdi
    mov     r12, rsi
    mov     [rsp], r8d
    mov     [rsp+4], r9d
    cmp     dword ptr [rbx+BD_BVH], 0   # a mesh: its tree
    jne     .Lpp_tree
    cmp     dword ptr [r12+BD_BVH], 0
    jne     .Lpp_tree
    mov     r13d, [rbx+BD_P0]
2:  mov     eax, [rbx+BD_P0]
    add     eax, [rbx+BD_NP]
    cmp     r13d, eax
    jae     9f
    mov     r14d, [r12+BD_P0]
3:  mov     eax, [r12+BD_P0]
    add     eax, [r12+BD_NP]
    cmp     r14d, eax
    jae     5f
    mov     eax, [rbx+BD_NP]            # one part each: the bodies' test did
    add     eax, [r12+BD_NP]
    cmp     eax, 2
    je      4f
    mov     rdi, rbx
    mov     esi, r13d
    lea     rdx, [rsp+16]
    call    part_bounds
    mov     rdi, r12
    mov     esi, r14d
    lea     rdx, [rsp+48]
    call    part_bounds
    movaps  xmm0, [rsp+16]
    cmpleps xmm0, [rsp+64]
    movaps  xmm1, [rsp+48]
    cmpleps xmm1, [rsp+32]
    andps   xmm0, xmm1
    movmskps eax, xmm0
    and     eax, 7
    cmp     eax, 7
    jne     41f
4:  mov     edi, [rsp]
    mov     esi, [rsp+4]
    mov     edx, r13d
    mov     ecx, r14d
    call    mf_get
41: inc     r14d
    jmp     3b
5:  inc     r13d
    jmp     2b
.Lpp_tree:
    mov     rdi, rbx
    mov     rsi, r12
    mov     edx, [rsp]
    mov     ecx, [rsp+4]
    xor     r8d, r8d
    call    pp_tree
9:  lea     rsp, [rbp-40]
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret

# pp_tree(rdi=body, rsi=body (the lower index first), edx, ecx = their
#   indices, r8d=1: only look) -> eax = triangles in reach with no manifold
#   (looking: those found are kept). One of them is a mesh: each part of
#   the other against the triangles under its bounds, within its reach
pp_tree:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    and     rsp, -16
    sub     rsp, 400                    # (+64: the tree walk's stack, 48;
                                        #  +48, +52: a leaf's end, place;
                                        #  +276 missing, +56 a part, +60 the
                                        #  mode; +256 the part's centre, +272
                                        #  its reach squared, +288 a
                                        #  triangle, +336 tri_closest's out)
    mov     rbx, rdi
    mov     r12, rsi
    mov     [rsp], edx
    mov     [rsp+4], ecx
    mov     [rsp+60], r8d
    mov     dword ptr [rsp+276], 0
    # the mesh M (r12 when it is the second) and the other O: each part of
    #   O against the triangles under its bounds
    mov     dword ptr [rsp+8], 0        # M is the second (0) / first (1)
    mov     r15, r12
    mov     r14, rbx
    cmp     dword ptr [r12+BD_BVH], 0
    jne     61f
    mov     dword ptr [rsp+8], 1
    mov     r15, rbx
    mov     r14, r12
61: mov     r13d, [r14+BD_P0]           # O's parts
62: mov     eax, [r14+BD_P0]
    add     eax, [r14+BD_NP]
    cmp     r13d, eax
    jae     .Lpt_out
    mov     rdi, r14
    mov     esi, r13d
    lea     rdx, [rsp+16]
    call    part_bounds
    mov     eax, r13d                   # its centre and reach: the bounds'
    imul    rax, rax, PT_SZ             #  half diagonal and its radius, the
    add     rax, [rip+rb_pt]            #  margin, how far it goes in a step
    movaps  xmm0, [rax+PT_OFF]
    MV3     xmm1, r14+BD_R, xmm0, xmm2, xmm3
    addps   xmm1, [r14+BD_POS]
    andps   xmm1, [rip+rx_xyz]
    movaps  [rsp+256], xmm1
    movaps  xmm0, [rax+PT_HALF]
    andps   xmm0, [rip+rx_xyz]
    DOT3    xmm0, xmm0
    sqrtss  xmm0, xmm0
    addss   xmm0, [rax+PT_RAD]
    movaps  xmm1, [r14+BD_V]
    DOT3    xmm1, xmm1
    sqrtss  xmm1, xmm1
    mulss   xmm1, [rip+rb_dt]
    addss   xmm0, xmm1
    addss   xmm0, [rip+rx_keep]
    mulss   xmm0, xmm0
    movss   [rsp+272], xmm0
    mov     eax, [r15+BD_BVH]           # the walk: a stack of nodes
    dec     eax
    mov     [rsp+64], eax
    mov     dword ptr [rsp+12], 1       # (its depth, at +64 on)
63: mov     ecx, [rsp+12]
    test    ecx, ecx
    jz      69f
    dec     ecx
    mov     [rsp+12], ecx
    mov     eax, [rsp+64+rcx*4]
    shl     rax, 5
    add     rax, [rip+rb_bvh]
    movaps  xmm0, [rax]                 # meets the bounds?
    cmpleps xmm0, [rsp+32]
    movaps  xmm1, [rsp+16]
    cmpleps xmm1, [rax+16]
    andps   xmm0, xmm1
    movmskps edx, xmm0
    and     edx, 7
    cmp     edx, 7
    jne     63b
    mov     edx, [rax+12]
    test    edx, edx
    js      65f
    mov     ecx, [rsp+12]               # inner: both children (the stack
    cmp     ecx, 46                     #  holds 48: a tree of 2^40 leaves)
    jae     63b
    mov     [rsp+64+rcx*4], edx
    mov     edx, [rax+28]
    mov     [rsp+68+rcx*4], edx
    add     dword ptr [rsp+12], 2
    jmp     63b
65: and     edx, 0x7fffffff             # a leaf: its triangles
    mov     ecx, [rax+28]
    add     ecx, edx
    mov     [rsp+48], ecx
    mov     [rsp+52], edx
66: mov     edx, [rsp+52]
    cmp     edx, [rsp+48]
    jae     63b
    mov     rax, rdx
    shl     rax, 5
    add     rax, [rip+rb_bvb]
    movaps  xmm0, [rax]
    cmpleps xmm0, [rsp+32]
    movaps  xmm1, [rsp+16]
    cmpleps xmm1, [rax+16]
    andps   xmm0, xmm1
    movmskps ecx, xmm0
    and     ecx, 7
    cmp     ecx, 7
    jne     67f
    mov     rax, [rip+rb_bvi]
    mov     ecx, [rax+rdx*4]            # the triangle's part: within reach?
    mov     [rsp+56], ecx               #  (its closest point to the centre)
    call    pp_reach
    mov     ecx, [rsp+56]
    test    eax, eax
    jz      67f
    mov     edi, [rsp]
    mov     esi, [rsp+4]
    mov     edx, r13d                   # (parts in the bodies' order)
    cmp     dword ptr [rsp+8], 0        # (M second: O's part first; M
    je      68f                         #  first: its triangle first)
    xchg    edx, ecx
68: cmp     dword ptr [rsp+60], 0   # (only looking: there already?)
    je      681f
    mov     edi, edx
    mov     esi, ecx
    call    mf_find
    test    rax, rax
    jz      682f
    mov     ecx, [rip+rb_stepno]
    mov     [rax+MX_KEEP], ecx
    jmp     67f
682:inc     dword ptr [rsp+276]
    jmp     67f
681:call    mf_get
67: inc     dword ptr [rsp+52]
    jmp     66b
69: inc     r13d
    jmp     62b
.Lpt_out:
    mov     eax, [rsp+276]
    lea     rsp, [rbp-40]
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret

# mf_find(edi=part a, esi=part b) -> rax = its manifold's keys, or 0
mf_find:
    mov     r10d, edi
    mov     r11d, esi
    call    mf_hash
    mov     rcx, [rip+rb_hs]
1:  mov     edx, [rcx+rax*4]
    test    edx, edx
    jz      8f
    dec     edx
    shl     rdx, 5
    add     rdx, [rip+rb_mx]
    cmp     [rdx+MX_PA], r10d
    jne     2f
    cmp     [rdx+MX_PB], r11d
    jne     2f
    mov     rax, rdx
    ret
2:  inc     eax
    and     eax, [rip+rb_hmask]
    jmp     1b
8:  xor     eax, eax
    ret

# pp_reach(ecx=a triangle's part of r15; the caller's frame: +256 the
#   other part's centre, +272 its reach squared) -> eax = 1 when the
#   triangle comes within that reach
pp_reach:
    push    rbx
    push    r12
    sub     rsp, 8                      # (the caller's frame at +32)
    imul    rax, rcx, PT_SZ
    add     rax, [rip+rb_pt]
    mov     ebx, [rax+PT_TW]            # its corners (world, kept)
    imul    rbx, rbx, 48
    add     rbx, [rip+rb_tvw]
    xor     r12d, r12d
1:  mov     edx, r12d                   # each corner: from the centre
    shl     edx, 4
    movaps  xmm1, [rbx+rdx]
    subps   xmm1, [rsp+32+256]
    andps   xmm1, [rip+rx_xyz]
    movaps  [rsp+32+288+rdx], xmm1
    inc     r12d
    cmp     r12d, 3
    jb      1b
    lea     rdi, [rsp+32+288]
    lea     rsi, [rsp+32+304]
    lea     rdx, [rsp+32+320]
    lea     rcx, [rsp+32+336]
    call    tri_closest
    movaps  xmm0, [rsp+32+336]          # |closest|^2 <= reach^2
    DOT3    xmm0, xmm0
    xor     eax, eax
    comiss  xmm0, [rsp+32+272]
    ja      9f
    mov     eax, 1
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# part_bounds(rdi=body, esi=part, rdx=out min, max)
part_bounds:
    imul    rsi, rsi, PT_SZ
    add     rsi, [rip+rb_pt]
    cmp     dword ptr [rsi+PT_TYPE], 2  # a plane: without end
    jne     1f
    movaps  xmm0, [rip+rx_nbig4]
    movaps  [rdx], xmm0
    movaps  xmm0, [rip+rx_big4]
    movaps  [rdx+16], xmm0
    ret
1:
    movaps  xmm0, [rsi+PT_OFF]
    MV3     xmm1, rdi+BD_R, xmm0, xmm2, xmm3
    addps   xmm1, [rdi+BD_POS]
    movss   xmm4, [rsi+PT_RAD]
    shufps  xmm4, xmm4, 0
    andps   xmm4, [rip+rx_xyz]
    addps   xmm4, [rsi+PT_HALF]
    movaps  xmm2, [rdi+BD_R]
    andps   xmm2, [rip+rx_abs]
    DOT3    xmm2, xmm4
    movaps  xmm3, [rdi+BD_R+16]
    andps   xmm3, [rip+rx_abs]
    DOT3    xmm3, xmm4
    movaps  xmm5, [rdi+BD_R+32]
    andps   xmm5, [rip+rx_abs]
    DOT3    xmm5, xmm4
    unpcklps xmm2, xmm3
    movlhps xmm2, xmm5
    addps   xmm2, [rip+rx_marg4]
    movaps  xmm4, [rdi+BD_V]            # and how far it goes in a step (as
    andps   xmm4, [rip+rx_abs]          #  body_bounds)
    movss   xmm5, [rip+rb_dt]
    shufps  xmm5, xmm5, 0
    mulps   xmm4, xmm5
    andps   xmm4, [rip+rx_xyz]
    addps   xmm2, xmm4
    movaps  xmm3, xmm1
    subps   xmm3, xmm2
    movaps  [rdx], xmm3
    addps   xmm1, xmm2
    movaps  [rdx+16], xmm1
    ret

# compact - manifolds not seen this step go
compact:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     edx, [rip+rb_stepno]
    xor     ebx, ebx
1:  cmp     ebx, [rip+rb_nmf]
    jae     9f
    mov     rax, rbx
    shl     rax, 5
    add     rax, [rip+rb_mx]
    cmp     [rax+MX_KEEP], edx
    je      3f
    push    rdx                         # not seen: out of the hash,
    push    rdx
    mov     edi, ebx
    call    hf_slot
    call    hf_delete
    pop     rdx
    pop     rdx
    mov     r12d, [rip+rb_nmf]          #  the last into its place
    dec     r12d
    mov     [rip+rb_nmf], r12d
    cmp     ebx, r12d
    je      1b
    push    rdx
    push    rdx
    mov     edi, r12d                   # (its hash entry: the new index)
    call    hf_slot
    mov     rcx, [rip+rb_hs]
    lea     edx, [rbx+1]
    mov     [rcx+rax*4], edx
    pop     rdx
    pop     rdx
    mov     rax, rbx
    shl     rax, 5
    add     rax, [rip+rb_mx]
    mov     rsi, r12
    shl     rsi, 5
    add     rsi, [rip+rb_mx]
    mov     rdi, rax
    mov     ecx, MX_SZ/8
    rep     movsq
    imul    rsi, r12, MF_SZ
    add     rsi, [rip+rb_mf]
    imul    rdi, rbx, MF_SZ
    add     rdi, [rip+rb_mf]
    mov     ecx, MF_SZ/8
    rep     movsq
    jmp     1b                          # (that one checked next)
3:  inc     ebx
    jmp     1b
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# -----------------------------------------------------------------------------
# Narrow phase
# -----------------------------------------------------------------------------
# narrow_job(rdi=ctx, esi=begin, edx=end) - each manifold with something
#   awake in it brought up to date
narrow_job:
    push    rbx
    push    r12
    push    r13
    mov     r12d, esi
    mov     r13d, edx
1:  cmp     r12d, r13d
    jae     9f
    imul    rbx, r12, MF_SZ
    add     rbx, [rip+rb_mf]
    mov     eax, [rbx+MF_A]
    BODY    rcx, rax
    AWAKE   rcx
    je      2f
    mov     eax, [rbx+MF_B]
    BODY    rcx, rax
    AWAKE   rcx
    jne     3f
2:  mov     rdi, rbx
    call    mf_update
    mov     eax, [rbx+MF_N]             # (its count in the keys)
    mov     rcx, r12
    shl     rcx, 5
    add     rcx, [rip+rb_mx]
    mov     [rcx+MX_N], eax
3:  inc     r12d
    jmp     1b
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# mf_update(rdi=manifold) - its points refreshed (gone when apart or slid),
#   a new one from collide, more by tilting (polytopes), at most four kept
.equ MU_PXA,    0
.equ MU_PXB,    80
.equ MU_RES,    160
.equ MU_TILT,   224
.equ MU_PXT,    304
.equ MU_PIV,    384
.equ MU_WHO,    400
.equ MU_CL,     416                     # poly_clip's points (4 results)
.equ MU_NEW,    672                     # the new points (4)
.equ MU_MG,     MU_NEW + 4*CP_SZ        # contacts begin this far apart, and
.equ MU_KEEP,   MU_MG + 4               #  points are kept this far
.equ MU_SZ,     MU_MG + 16
mf_update:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    and     rsp, -16
    sub     rsp, MU_SZ
    mov     rbx, rdi
    mov     eax, [rbx+MF_A]
    BODY    r12, rax
    mov     eax, [rbx+MF_B]
    BODY    r13, rax
    # the margin: 2 cm, and as far as they can close in a step (no fast
    #   body passes another between two narrow phases)
    movaps  xmm0, [r12+BD_V]
    DOT3    xmm0, xmm0
    sqrtss  xmm0, xmm0
    movaps  xmm1, [r13+BD_V]
    DOT3    xmm1, xmm1
    sqrtss  xmm1, xmm1
    addss   xmm0, xmm1
    mulss   xmm0, [rip+rb_dt]
    addss   xmm0, [rip+rx_margin]
    movss   [rsp+MU_MG], xmm0
    addss   xmm0, [rip+rx_margin]
    maxss   xmm0, [rip+rx_keep]
    movss   [rsp+MU_KEEP], xmm0
    # refresh
    xor     r14d, r14d
1:  cmp     r14d, [rbx+MF_N]
    jae     3f
    imul    r15, r14, CP_SZ
    lea     r15, [rbx+MF_PTS+r15]
    movaps  xmm0, [r15+CP_LA]
    MV3     xmm1, r12+BD_R, xmm0, xmm2, xmm3
    movaps  [r15+CP_RA], xmm1
    addps   xmm1, [r12+BD_POS]          # wA
    movaps  [r15+CP_WA], xmm1
    movaps  xmm0, [r15+CP_LB]
    MV3     xmm4, r13+BD_R, xmm0, xmm2, xmm3
    movaps  [r15+CP_RB], xmm4
    addps   xmm4, [r13+BD_POS]          # wB
    subps   xmm4, xmm1                  # d = wB - wA
    movaps  xmm5, xmm4
    DOT3    xmm5, [rbx+MF_NRM]          # sep
    movss   [r15+CP_SEP], xmm5
    comiss  xmm5, [rsp+MU_KEEP]
    ja      2f
    shufps  xmm5, xmm5, 0               # sliding: d - n sep
    mulps   xmm5, [rbx+MF_NRM]
    subps   xmm4, xmm5
    DOT3    xmm4, xmm4
    comiss  xmm4, [rip+rx_drift2]
    ja      2f
    inc     r14d
    jmp     1b
2:  mov     rdi, rbx                    # this one goes
    mov     esi, r14d
    call    cp_remove
    jmp     1b
3:  # a new point
    lea     rdi, [rsp+MU_PXA]           # (the proxies first)
    lea     rsi, [r12+BD_R]
    lea     rdx, [r12+BD_POS]
    mov     ecx, [rbx+MF_PA]
    imul    rcx, rcx, PT_SZ
    add     rcx, [rip+rb_pt]
    call    px_place
    lea     rdi, [rsp+MU_PXB]
    lea     rsi, [r13+BD_R]
    lea     rdx, [r13+BD_POS]
    mov     ecx, [rbx+MF_PB]
    imul    rcx, rcx, PT_SZ
    add     rcx, [rip+rb_pt]
    call    px_place
    mov     rax, [rsp+MU_PXA+PX_PART]   # a plane: its own contacts
    mov     edx, 1
    lea     rdi, [rsp+MU_PXA]
    lea     rsi, [rsp+MU_PXB]
    cmp     dword ptr [rax+PT_TYPE], 2
    je      31f
    mov     rax, [rsp+MU_PXB+PX_PART]
    xor     edx, edx
    lea     rdi, [rsp+MU_PXB]
    lea     rsi, [rsp+MU_PXA]
    cmp     dword ptr [rax+PT_TYPE], 2
    jne     32f
31: movss   xmm0, [rsp+MU_MG]
    lea     rcx, [rsp+MU_CL]
    call    poly_plane
    mov     edx, eax
    mov     rdi, rbx
    lea     rsi, [rsp+MU_CL]
    lea     rcx, [rsp+MU_NEW]
    test    edx, edx
    jnz     33f
    mov     dword ptr [rbx+MF_N], 0     # (apart)
    jmp     .Lmu_out
33: movaps  xmm0, [rsp+MU_CL+CR_N]
    movaps  [rbx+MF_NRM], xmm0
    call    mf_replace
    jmp     .Lmu_tan
32: lea     rdi, [rsp+MU_PXA]
    lea     rsi, [rsp+MU_PXB]
    lea     rdx, [rsp+MU_RES]
    call    collide
    movss   xmm0, [rsp+MU_RES+CR_SEP]
    comiss  xmm0, [rsp+MU_MG]
    jbe     4f
    mov     dword ptr [rbx+MF_N], 0     # apart
    jmp     .Lmu_out
4:  mov     rax, [rsp+MU_PXA+PX_PART]   # a mesh's triangle: its inactive
    lea     rdi, [rsp+MU_PXA]           #  edges (tri_fix)
    mov     edx, 1
    test    dword ptr [rax+PT_FLG], 1
    jnz     40f
    mov     rax, [rsp+MU_PXB+PX_PART]
    lea     rdi, [rsp+MU_PXB]
    xor     edx, edx
    test    dword ptr [rax+PT_FLG], 1
    jz      42f
40: lea     rsi, [rsp+MU_RES]
    call    tri_fix
    movss   xmm0, [rsp+MU_RES+CR_SEP]   # (the gap along the face: maybe apart)
    comiss  xmm0, [rsp+MU_MG]
    jbe     42f
    mov     dword ptr [rbx+MF_N], 0
    jmp     .Lmu_out
42: movaps  xmm0, [rsp+MU_RES+CR_N]
    movaps  [rbx+MF_NRM], xmm0
    # polytopes: their faces clipped - the whole contact at once
    lea     rdi, [rsp+MU_PXA]
    lea     rsi, [rsp+MU_PXB]
    movaps  xmm0, [rsp+MU_RES+CR_N]
    movss   xmm1, [rsp+MU_MG]
    lea     rdx, [rsp+MU_CL]
    call    poly_clip
    test    eax, eax
    jz      45f
    mov     edx, eax
    mov     rdi, rbx
    lea     rsi, [rsp+MU_CL]
    lea     rcx, [rsp+MU_NEW]
    call    mf_replace
    jmp     .Lmu_tan
45: mov     rdi, rbx
    lea     rsi, [rsp+MU_RES]
    call    cp_add
    # other polytopes (edges, vertices): tilt A a little four ways for more
    cmp     dword ptr [rbx+MF_N], 4
    jae     .Lmu_tan
    mov     rax, [rsp+MU_PXA+PX_PART]
    xorps   xmm0, xmm0
    ucomiss xmm0, [rax+PT_RAD]
    jne     .Lmu_tan
    mov     rax, [rsp+MU_PXB+PX_PART]
    ucomiss xmm0, [rax+PT_RAD]
    jne     .Lmu_tan
    mov     rdi, rbx
    call    mf_tangents
    movaps  xmm0, [rsp+MU_RES+CR_PA]    # the pivot: the contact
    movaps  [rsp+MU_PIV], xmm0
    mov     rax, [rsp+MU_PXA+PX_PART]   # tilt the smaller part
    movaps  xmm0, [rax+PT_HALF]
    DOT3    xmm0, xmm0
    mov     rax, [rsp+MU_PXB+PX_PART]
    movaps  xmm1, [rax+PT_HALF]
    DOT3    xmm1, xmm1
    xor     eax, eax
    comiss  xmm0, xmm1
    jbe     41f
    mov     eax, 1
41: mov     [rsp+MU_WHO], eax
    xor     r14d, r14d
5:  cmp     r14d, 4
    jae     .Lmu_tan
    movaps  xmm0, [rbx+MF_T1]           # axis: +-t1, +-t2
    test    r14d, 2
    jz      51f
    movaps  xmm0, [rbx+MF_T2]
51: movss   xmm1, [rip+rx_tilt]
    test    r14d, 1
    jz      52f
    xorps   xmm1, [rip+rx_sign]
52: movaps  [rsp+MU_TILT], xmm0
    lea     rdi, [rsp+MU_TILT+16]       # Q (48 bytes)
    lea     rsi, [rsp+MU_TILT]
    movss   xmm0, xmm1
    call    rot_axis4
    lea     r15, [rsp+MU_PXA]           # the one tilted: rows Q R, centre
    cmp     dword ptr [rsp+MU_WHO], 0   #  P + Q (C - P)
    je      53f
    lea     r15, [rsp+MU_PXB]
53: lea     rdi, [rsp+MU_PXT]
    lea     rsi, [rsp+MU_TILT+16]
    mov     rdx, r15
    call    rows_mul
    movaps  xmm0, [r15+PX_C]
    subps   xmm0, [rsp+MU_PIV]
    lea     rax, [rsp+MU_TILT+16]
    MV3     xmm1, rax, xmm0, xmm2, xmm3
    addps   xmm1, [rsp+MU_PIV]
    andps   xmm1, [rip+rx_xyz]
    movaps  [rsp+MU_PXT+PX_C], xmm1
    mov     rax, [r15+PX_PART]
    mov     [rsp+MU_PXT+PX_PART], rax
    lea     rdi, [rsp+MU_PXT]
    lea     rsi, [rsp+MU_PXB]
    cmp     dword ptr [rsp+MU_WHO], 0
    je      54f
    lea     rdi, [rsp+MU_PXA]
    lea     rsi, [rsp+MU_PXT]
54: lea     rdx, [rsp+MU_RES]
    call    collide
    movss   xmm0, [rsp+MU_RES+CR_SEP]
    comiss  xmm0, [rsp+MU_MG]
    ja      58f
    # the tilted one's point: from the other's along n, turned back
    shufps  xmm0, xmm0, 0
    mulps   xmm0, [rsp+MU_RES+CR_N]
    cmp     dword ptr [rsp+MU_WHO], 0
    jne     55f
    movaps  xmm1, [rsp+MU_RES+CR_PB]    # A tilted: pA' = pB - n sep
    subps   xmm1, xmm0
    lea     rcx, [rsp+MU_RES+CR_PA]
    jmp     56f
55: movaps  xmm1, [rsp+MU_RES+CR_PA]    # B tilted: pB' = pA + n sep
    addps   xmm1, xmm0
    lea     rcx, [rsp+MU_RES+CR_PB]
56: subps   xmm1, [rsp+MU_PIV]          # P + Q^T (p' - P)
    lea     rax, [rsp+MU_TILT+16]
    MTV3    xmm2, rax, xmm1, xmm3
    addps   xmm2, [rsp+MU_PIV]
    andps   xmm2, [rip+rx_xyz]
    movaps  [rcx], xmm2
    movaps  xmm0, [rsp+MU_RES+CR_PB]    # its separation along the normal
    subps   xmm0, [rsp+MU_RES+CR_PA]
    DOT3    xmm0, [rbx+MF_NRM]
    movss   [rsp+MU_RES+CR_SEP], xmm0
    comiss  xmm0, [rsp+MU_MG]
    ja      58f
    mov     rdi, rbx
    lea     rsi, [rsp+MU_RES]
    call    cp_add
58: inc     r14d
    jmp     5b
.Lmu_tan:
    mov     rdi, rbx
    call    mf_tangents
.Lmu_out:
    lea     rsp, [rbp-40]
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret

# mf_tangents(rdi=manifold) - t1, t2 square to the normal
mf_tangents:
    movaps  xmm0, [rdi+MF_NRM]
    movaps  xmm1, xmm0
    andps   xmm1, [rip+rx_abs]
    comiss  xmm1, [rip+rx_0577]
    jb      1f
    movaps  xmm1, xmm0                  # (y, -x, 0)
    shufps  xmm1, xmm1, 0xE1            # (y x z w)
    xorps   xmm1, [rip+rx_negy]
    andps   xmm1, [rip+rx_xy]
    jmp     2f
1:  movaps  xmm1, xmm0                  # (0, z, -y)
    shufps  xmm1, xmm1, 0xD8            # (x z y w)
    xorps   xmm1, [rip+rx_negz]
    andps   xmm1, [rip+rx_yz]
2:  movaps  xmm2, xmm1
    DOT3    xmm2, xmm2
    sqrtss  xmm2, xmm2
    maxss   xmm2, [rip+rx_tiny]
    shufps  xmm2, xmm2, 0
    divps   xmm1, xmm2
    andps   xmm1, [rip+rx_xyz]
    movaps  [rdi+MF_T1], xmm1
    CROSS   xmm2, xmm0, xmm1, xmm3
    andps   xmm2, [rip+rx_xyz]
    movaps  [rdi+MF_T2], xmm2
    ret

# rot_axis4(rdi=rows out, rsi=unit axis (vec4), xmm0=angle)
rot_axis4:
    push    rbx
    push    r12
    sub     rsp, 24
    mov     rbx, rdi
    mov     r12, rsi
    call    sincos
    movss   [rsp], xmm0                 # s
    movss   [rsp+4], xmm1               # c
    movss   xmm2, [rip+rx_one]
    subss   xmm2, xmm1
    movss   [rsp+8], xmm2               # 1 - c
    xor     ecx, ecx
1:  movss   xmm0, [r12+rcx*4]           # row i = (1-c) k_i k + c e_i + s ([k]x)_i
    mulss   xmm0, [rsp+8]
    shufps  xmm0, xmm0, 0
    mulps   xmm0, [r12]
    imul    edx, ecx, 16
    lea     rax, [rip+rx_ident]
    movaps  xmm1, [rax+rdx]
    movss   xmm2, [rsp+4]
    shufps  xmm2, xmm2, 0
    mulps   xmm1, xmm2
    addps   xmm0, xmm1
    andps   xmm0, [rip+rx_xyz]
    movaps  [rbx+rdx], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      1b
    movss   xmm3, [rsp]                 # skew: [[0 -z y] [z 0 -x] [-y x 0]]
    movss   xmm0, [r12]
    mulss   xmm0, xmm3
    movss   xmm1, [r12+4]
    mulss   xmm1, xmm3
    movss   xmm2, [r12+8]
    mulss   xmm2, xmm3
    movss   xmm4, [rbx+4]
    subss   xmm4, xmm2
    movss   [rbx+4], xmm4
    movss   xmm4, [rbx+8]
    addss   xmm4, xmm1
    movss   [rbx+8], xmm4
    movss   xmm4, [rbx+16]
    addss   xmm4, xmm2
    movss   [rbx+16], xmm4
    movss   xmm4, [rbx+24]
    subss   xmm4, xmm0
    movss   [rbx+24], xmm4
    movss   xmm4, [rbx+32]
    subss   xmm4, xmm1
    movss   [rbx+32], xmm4
    movss   xmm4, [rbx+36]
    addss   xmm4, xmm0
    movss   [rbx+36], xmm4
    add     rsp, 24
    pop     r12
    pop     rbx
    ret

# rows_mul(rdi=out rows, rsi=Q rows, rdx=R rows) - out = Q R
rows_mul:
    xor     ecx, ecx
1:  imul    eax, ecx, 16
    movaps  xmm0, [rsi+rax]             # row i of Q: sum_k Q_ik row_k(R)
    MTV3    xmm1, rdx, xmm0, xmm2
    andps   xmm1, [rip+rx_xyz]
    movaps  [rdi+rax], xmm1
    inc     ecx
    cmp     ecx, 3
    jb      1b
    ret

# cp_remove(rdi=manifold, esi=point) - the last into its place
cp_remove:
    mov     eax, [rdi+MF_N]
    dec     eax
    mov     [rdi+MF_N], eax
    cmp     esi, eax
    je      9f
    imul    rcx, rsi, CP_SZ
    lea     rcx, [rdi+MF_PTS+rcx]
    imul    rdx, rax, CP_SZ
    lea     rdx, [rdi+MF_PTS+rdx]
    xor     r8d, r8d
1:  movaps  xmm0, [rdx+r8]
    movaps  [rcx+r8], xmm0
    add     r8d, 16
    cmp     r8d, CP_SZ
    jb      1b
9:  ret

# cp_add(rdi=manifold, rsi=result (r12, r13 its bodies)) - a contact point:
#   replacing one near it (its impulses kept), added, or four kept
cp_add:
    push    rbx
    push    r14
    push    r15
    sub     rsp, 16
    mov     rbx, rdi
    mov     r15, rsi
    xor     r14d, r14d                  # near an old one?
1:  cmp     r14d, [rbx+MF_N]
    jae     3f
    imul    rax, r14, CP_SZ
    movaps  xmm0, [rbx+MF_PTS+rax+CP_WA]
    subps   xmm0, [r15+CR_PA]
    DOT3    xmm0, xmm0
    comiss  xmm0, [rip+rx_same2]
    jbe     4f
    inc     r14d
    jmp     1b
3:  cmp     r14d, 4                     # full: one goes
    jb      31f
    mov     rdi, rbx
    mov     rsi, r15
    call    cp_reduce
    mov     r14d, eax
    test    eax, eax
    js      9f
    jmp     4f
31: inc     dword ptr [rbx+MF_N]
    imul    rax, r14, CP_SZ
    xor     ecx, ecx
    mov     [rbx+MF_PTS+rax+CP_JN], ecx
    mov     [rbx+MF_PTS+rax+CP_JT1], ecx
    mov     [rbx+MF_PTS+rax+CP_JT2], ecx
4:  imul    rax, r14, CP_SZ             # its geometry
    lea     rdi, [rbx+MF_PTS+rax]
    mov     rsi, r15
    call    cp_geom
9:  add     rsp, 16
    pop     r15
    pop     r14
    pop     rbx
    ret

# cp_geom(rdi=point, rsi=result; r12, r13 the bodies) - its anchors, where
#   it is, its gap
cp_geom:
    push    r15
    mov     r15, rsi
    movaps  xmm0, [r15+CR_PA]
    movaps  [rdi+CP_WA], xmm0
    subps   xmm0, [r12+BD_POS]
    movaps  [rdi+CP_RA], xmm0
    lea     rax, [r12+BD_R]
    MTV3    xmm1, rax, xmm0, xmm2
    andps   xmm1, [rip+rx_xyz]
    movaps  [rdi+CP_LA], xmm1
    movaps  xmm0, [r15+CR_PB]
    subps   xmm0, [r13+BD_POS]
    movaps  [rdi+CP_RB], xmm0
    lea     rax, [r13+BD_R]
    MTV3    xmm1, rax, xmm0, xmm2
    andps   xmm1, [rip+rx_xyz]
    movaps  [rdi+CP_LB], xmm1
    movss   xmm0, [r15+CR_SEP]
    movss   [rdi+CP_SEP], xmm0
    pop     r15
    ret

# mf_replace(rdi=manifold, rsi=results, edx=count, rcx=scratch (4 points);
#   r12, r13 its bodies) - these points instead; each takes the impulses of
#   an old one where it was
mf_replace:
    push    rbx
    push    r14
    push    r15
    push    rbp
    push    r8
    push    r9
    sub     rsp, 8
    mov     rbx, rdi
    mov     r15, rsi
    mov     ebp, edx
    mov     r9, rcx
    xor     r14d, r14d
1:  cmp     r14d, ebp
    jae     5f
    imul    rdi, r14, CP_SZ
    add     rdi, r9
    xor     eax, eax
    mov     [rdi+CP_JN], eax
    mov     [rdi+CP_JT1], eax
    mov     [rdi+CP_JT2], eax
    xor     ecx, ecx                    # an old one near it
2:  cmp     ecx, [rbx+MF_N]
    jae     4f
    imul    rax, rcx, CP_SZ
    movaps  xmm0, [rbx+MF_PTS+rax+CP_WA]
    subps   xmm0, [r15+CR_PA]
    DOT3    xmm0, xmm0
    comiss  xmm0, [rip+rx_same2]
    jbe     3f
    inc     ecx
    jmp     2b
3:  mov     edx, [rbx+MF_PTS+rax+CP_JN]
    mov     [rdi+CP_JN], edx
    mov     edx, [rbx+MF_PTS+rax+CP_JT1]
    mov     [rdi+CP_JT1], edx
    mov     edx, [rbx+MF_PTS+rax+CP_JT2]
    mov     [rdi+CP_JT2], edx
4:  mov     rsi, r15
    call    cp_geom
    add     r15, 64
    inc     r14d
    jmp     1b
5:  mov     [rbx+MF_N], ebp
    lea     rdi, [rbx+MF_PTS]
    mov     rsi, r9
    imul    ecx, ebp, CP_SZ
    rep     movsb
    add     rsp, 8
    pop     r9
    pop     r8
    pop     rbp
    pop     r15
    pop     r14
    pop     rbx
    ret

# cp_reduce(rdi=manifold of 4, rsi=result) -> eax = the point the new one
#   replaces (the deepest stays; the most area left), or -1: the new one
#   is not wanted
cp_reduce:
    push    rbx
    sub     rsp, 16
    mov     rbx, rdi
    mov     ecx, -1                     # the deepest old point
    movss   xmm7, [r15+CR_SEP]
    xor     edx, edx
1:  imul    rax, rdx, CP_SZ
    movss   xmm0, [rbx+MF_PTS+rax+CP_SEP]
    comiss  xmm0, xmm7
    jae     2f
    movss   xmm7, xmm0
    mov     ecx, edx
2:  inc     edx
    cmp     edx, 4
    jb      1b
    mov     [rsp], ecx
    # areas without each: |(p4 - pa) x (pb - pc)|^2
    movaps  xmm6, [r15+CR_PA]           # p4
    xorps   xmm5, xmm5                  # best area
    mov     r8d, -1
    xor     edx, edx
3:  cmp     edx, [rsp]
    je      5f
    lea     rax, [rip+red_tab]
    movzx   r9d, byte ptr [rax+rdx*4]
    movzx   r10d, byte ptr [rax+rdx*4+1]
    movzx   r11d, byte ptr [rax+rdx*4+2]
    imul    r9, r9, CP_SZ
    imul    r10, r10, CP_SZ
    imul    r11, r11, CP_SZ
    movaps  xmm0, xmm6
    subps   xmm0, [rbx+MF_PTS+r9+CP_WA]
    movaps  xmm1, [rbx+MF_PTS+r10+CP_WA]
    subps   xmm1, [rbx+MF_PTS+r11+CP_WA]
    andps   xmm0, [rip+rx_xyz]
    andps   xmm1, [rip+rx_xyz]
    CROSS   xmm2, xmm0, xmm1, xmm3
    DOT3    xmm2, xmm2
    comiss  xmm2, xmm5
    jbe     5f
    movss   xmm5, xmm2
    mov     r8d, edx
5:  inc     edx
    cmp     edx, 4
    jb      3b
    mov     eax, r8d
    add     rsp, 16
    pop     rbx
    ret

.section .rodata
.align 4
red_tab:        .byte 1, 3, 2, 0,  0, 3, 2, 0,  0, 3, 1, 0,  0, 2, 1, 0
.text

# -----------------------------------------------------------------------------
# Islands
# -----------------------------------------------------------------------------
# uf_find(edi=body) -> eax = its root (paths halved)
uf_find:
    mov     rcx, [rip+rb_par]
    mov     eax, edi
1:  mov     edx, [rcx+rax*4]
    cmp     edx, eax
    je      9f
    mov     r8d, [rcx+rdx*4]
    mov     [rcx+rax*4], r8d
    mov     eax, r8d
    jmp     1b
9:  ret
# uf_union(edi, esi) - when both move
uf_union:
    push    rbx
    BODY    rax, rdi
    cmp     dword ptr [rax+BD_TYPE], 1
    jne     9f
    BODY    rax, rsi
    cmp     dword ptr [rax+BD_TYPE], 1
    jne     9f
    mov     ebx, esi
    call    uf_find
    xchg    eax, ebx
    mov     edi, eax
    call    uf_find
    cmp     eax, ebx
    je      9f
    mov     rcx, [rip+rb_par]
    mov     [rcx+rax*4], ebx
9:  pop     rbx
    ret

# isl_of(edi=a, esi=b) -> eax = the island of the one that moves, or -1
isl_of:
    BODY    rax, rdi
    cmp     dword ptr [rax+BD_TYPE], 1
    je      1f
    BODY    rax, rsi
    cmp     dword ptr [rax+BD_TYPE], 1
    je      1f
    mov     eax, -1
    ret
1:  mov     eax, [rax+BD_ISL]
    ret

# islands - bodies joined by contacts and joints (through moving bodies):
#   their lists, and whether each is awake (then all of it is)
islands:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r15d, [rip+rb_nb]
    mov     rcx, [rip+rb_par]
    xor     eax, eax
1:  cmp     eax, r15d
    jae     2f
    mov     [rcx+rax*4], eax
    inc     eax
    jmp     1b
2:  xor     r12d, r12d                  # unions: contacts,
3:  cmp     r12d, [rip+rb_nmf]
    jae     4f
    mov     rbx, r12
    shl     rbx, 5
    add     rbx, [rip+rb_mx]
    cmp     dword ptr [rbx+MX_N], 0
    je      31f
    mov     edi, [rbx+MX_A]
    mov     esi, [rbx+MX_B]
    call    uf_union
31: inc     r12d
    jmp     3b
4:  xor     r12d, r12d                  #  joints
41: cmp     r12d, [rip+rb_njr]
    jae     5f
    imul    rbx, r12, JR_SZ
    add     rbx, [rip+rb_jr]
    test    dword ptr [rbx+JR_FL], 4    # (broken: no tie)
    jnz     411f
    mov     edi, [rbx+JR_A]
    mov     esi, [rbx+JR_B]
    call    uf_union
411:inc     r12d
    jmp     41b
5:  mov     r13, [rip+rb_isj]           # ids (rb_isj as root -> id, for now)
    xor     eax, eax
51: cmp     eax, r15d
    jae     52f
    mov     dword ptr [r13+rax*4], -1
    inc     eax
    jmp     51b
52: xor     r14d, r14d                  # islands
    xor     r12d, r12d
53: cmp     r12d, r15d
    jae     6f
    BODY    rbx, r12
    mov     dword ptr [rbx+BD_ISL], -1
    cmp     dword ptr [rbx+BD_TYPE], 1
    jne     54f
    mov     edi, r12d
    call    uf_find
    mov     ecx, [r13+rax*4]
    test    ecx, ecx
    jns     531f
    mov     ecx, r14d
    mov     [r13+rax*4], ecx
    inc     r14d
531:mov     [rbx+BD_ISL], ecx
54: inc     r12d
    jmp     53b
6:  mov     [rip+rb_nisl], r14d
    # bodies by island
    mov     rdi, [rip+rb_isb]
    call    isl_zero
    xor     r12d, r12d
61: cmp     r12d, r15d
    jae     62f
    BODY    rbx, r12
    mov     eax, [rbx+BD_ISL]
    test    eax, eax
    js      611f
    mov     rcx, [rip+rb_isb]
    inc     dword ptr [rcx+rax*4+4]
611:inc     r12d
    jmp     61b
62: mov     rdi, [rip+rb_isb]
    call    isl_prefix
    xor     r12d, r12d
63: cmp     r12d, r15d
    jae     64f
    BODY    rbx, r12
    mov     eax, [rbx+BD_ISL]
    test    eax, eax
    js      631f
    mov     rcx, [rip+rb_par]           # (cursors)
    mov     edx, [rcx+rax*4]
    inc     dword ptr [rcx+rax*4]
    mov     rcx, [rip+rb_ib]
    mov     [rcx+rdx*4], r12d
631:inc     r12d
    jmp     63b
64: # manifolds by island
    mov     rdi, [rip+rb_ism]
    call    isl_zero
    xor     r12d, r12d
65: cmp     r12d, [rip+rb_nmf]
    jae     66f
    mov     rbx, r12
    shl     rbx, 5
    add     rbx, [rip+rb_mx]
    call    mf_island
    test    eax, eax
    js      651f
    mov     rcx, [rip+rb_ism]
    inc     dword ptr [rcx+rax*4+4]
651:inc     r12d
    jmp     65b
66: mov     rdi, [rip+rb_ism]
    call    isl_prefix
    xor     r12d, r12d
67: cmp     r12d, [rip+rb_nmf]
    jae     68f
    mov     rbx, r12
    shl     rbx, 5
    add     rbx, [rip+rb_mx]
    call    mf_island
    test    eax, eax
    js      671f
    mov     rcx, [rip+rb_par]
    mov     edx, [rcx+rax*4]
    inc     dword ptr [rcx+rax*4]
    mov     rcx, [rip+rb_imf]
    mov     [rcx+rdx*4], r12d
671:inc     r12d
    jmp     67b
68: # joints by island
    mov     rdi, [rip+rb_isj]
    call    isl_zero
    xor     r12d, r12d
69: cmp     r12d, [rip+rb_njr]
    jae     70f
    imul    rbx, r12, JR_SZ
    add     rbx, [rip+rb_jr]
    mov     edi, [rbx+JR_A]
    mov     esi, [rbx+JR_B]
    call    isl_of
    test    eax, eax
    js      691f
    mov     rcx, [rip+rb_isj]
    inc     dword ptr [rcx+rax*4+4]
691:inc     r12d
    jmp     69b
70: mov     rdi, [rip+rb_isj]
    call    isl_prefix
    xor     r12d, r12d
71: cmp     r12d, [rip+rb_njr]
    jae     72f
    imul    rbx, r12, JR_SZ
    add     rbx, [rip+rb_jr]
    mov     edi, [rbx+JR_A]
    mov     esi, [rbx+JR_B]
    call    isl_of
    test    eax, eax
    js      711f
    mov     rcx, [rip+rb_par]
    mov     edx, [rcx+rax*4]
    inc     dword ptr [rcx+rax*4]
    mov     rcx, [rip+rb_ij]
    mov     [rcx+rdx*4], r12d
711:inc     r12d
    jmp     71b
72: # awake: any body in it; then all of it
    mov     rcx, [rip+rb_iaw]
    xor     eax, eax
73: cmp     eax, r14d
    jae     74f
    mov     dword ptr [rcx+rax*4], 0
    inc     eax
    jmp     73b
74: xor     r12d, r12d
75: cmp     r12d, r15d
    jae     76f
    BODY    rbx, r12
    mov     eax, [rbx+BD_ISL]
    test    eax, eax
    js      751f
    cmp     dword ptr [rbx+BD_ASLEEP], 0
    jne     751f
    mov     rcx, [rip+rb_iaw]
    mov     dword ptr [rcx+rax*4], 1
751:inc     r12d
    jmp     75b
76: xor     r12d, r12d
77: cmp     r12d, r15d
    jae     9f
    BODY    rbx, r12
    mov     eax, [rbx+BD_ISL]
    test    eax, eax
    js      771f
    mov     rcx, [rip+rb_iaw]
    cmp     dword ptr [rcx+rax*4], 0
    je      771f
    mov     dword ptr [rbx+BD_ASLEEP], 0
771:inc     r12d
    jmp     77b
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
# mf_island(rbx=manifold's keys) -> eax = its island (-1: no points / none)
mf_island:
    mov     eax, -1
    cmp     dword ptr [rbx+MX_N], 0
    je      9f
    mov     edi, [rbx+MX_A]
    mov     esi, [rbx+MX_B]
    jmp     isl_of
9:  ret
# isl_zero(rdi=starts) - nisl + 2 zeros
isl_zero:
    mov     ecx, [rip+rb_nisl]
    add     ecx, 2
    xor     eax, eax
    rep     stosd
    ret
# isl_prefix(rdi=starts, counts at +1) - prefix sums; cursors (rb_par) too
isl_prefix:
    mov     ecx, [rip+rb_nisl]
    mov     rdx, [rip+rb_par]
    xor     eax, eax
    xor     r8d, r8d
1:  cmp     r8d, ecx
    ja      9f
    add     eax, [rdi+r8*4]
    mov     [rdi+r8*4], eax
    mov     [rdx+r8*4], eax
    inc     r8d
    jmp     1b
9:  ret

# -----------------------------------------------------------------------------
# The solver
# -----------------------------------------------------------------------------
# kmass(xmm0=direction, rdi=rA, rsi=rB; r12 A, r13 B) -> xmm0 = 1 / k
kmass:
    movaps  xmm7, xmm0
    movss   xmm6, [r12+BD_IM]
    addss   xmm6, [r13+BD_IM]
    movaps  xmm1, [rdi]                 # c = rA x d; + c . IA c
    CROSS   xmm2, xmm1, xmm7, xmm3
    MV3     xmm3, r12+BD_IIW, xmm2, xmm4, xmm5
    DOT3    xmm3, xmm2
    addss   xmm6, xmm3
    movaps  xmm1, [rsi]
    CROSS   xmm2, xmm1, xmm7, xmm3
    MV3     xmm3, r13+BD_IIW, xmm2, xmm4, xmm5
    DOT3    xmm3, xmm2
    addss   xmm6, xmm3
    maxss   xmm6, [rip+rx_tiny]
    movss   xmm0, [rip+rx_one]
    divss   xmm0, xmm6
    ret

# relvel(rdi=rA, rsi=rB; r12, r13) -> xmm0 = (vB + wB x rB) - (vA + wA x rA)
relvel:
    movaps  xmm1, [r13+BD_W]
    movaps  xmm2, [rsi]
    CROSS   xmm0, xmm1, xmm2, xmm3
    addps   xmm0, [r13+BD_V]
    movaps  xmm1, [r12+BD_W]
    movaps  xmm2, [rdi]
    CROSS   xmm4, xmm1, xmm2, xmm3
    addps   xmm4, [r12+BD_V]
    subps   xmm0, xmm4
    ret

# impulse(xmm0=P, rdi=rA, rsi=rB; r12, r13) - -P on A, +P on B (moving ones)
impulse:
    movaps  xmm7, xmm0
    cmp     dword ptr [r12+BD_TYPE], 1
    jne     1f
    movss   xmm1, [r12+BD_IM]
    shufps  xmm1, xmm1, 0
    mulps   xmm1, xmm7
    movaps  xmm2, [r12+BD_V]
    subps   xmm2, xmm1
    movaps  [r12+BD_V], xmm2
    movaps  xmm1, [rdi]
    CROSS   xmm2, xmm1, xmm7, xmm3
    MV3     xmm3, r12+BD_IIW, xmm2, xmm4, xmm5
    movaps  xmm2, [r12+BD_W]
    subps   xmm2, xmm3
    movaps  [r12+BD_W], xmm2
1:  cmp     dword ptr [r13+BD_TYPE], 1
    jne     2f
    movss   xmm1, [r13+BD_IM]
    shufps  xmm1, xmm1, 0
    mulps   xmm1, xmm7
    addps   xmm1, [r13+BD_V]
    movaps  [r13+BD_V], xmm1
    movaps  xmm1, [rsi]
    CROSS   xmm2, xmm1, xmm7, xmm3
    MV3     xmm3, r13+BD_IIW, xmm2, xmm4, xmm5
    addps   xmm3, [r13+BD_W]
    movaps  [r13+BD_W], xmm3
2:  ret

# ang_impulse(xmm0=direction x impulse) - -on A, +on B (angular only)
ang_impulse:
    movaps  xmm7, xmm0
    cmp     dword ptr [r12+BD_TYPE], 1
    jne     1f
    MV3     xmm1, r12+BD_IIW, xmm7, xmm2, xmm3
    movaps  xmm2, [r12+BD_W]
    subps   xmm2, xmm1
    movaps  [r12+BD_W], xmm2
1:  cmp     dword ptr [r13+BD_TYPE], 1
    jne     2f
    MV3     xmm1, r13+BD_IIW, xmm7, xmm2, xmm3
    addps   xmm1, [r13+BD_W]
    movaps  [r13+BD_W], xmm1
2:  ret

# mf_bodies(rbx=manifold) -> r12, r13 its bodies
.macro MFB
    mov     eax, [rbx+MF_A]
    BODY    r12, rax
    mov     eax, [rbx+MF_B]
    BODY    r13, rax
.endm

# mf_prestep(rbx=manifold) - each point's rows for the step (normal,
#   tangents: the cross products and the inverse inertias times them, the
#   effective masses), the gap's base, the speed it meets at
mf_prestep:
    push    r14
    push    r15
    sub     rsp, 8
    MFB
    xor     r14d, r14d
1:  cmp     r14d, [rbx+MF_N]
    jae     9f
    imul    r15, r14, CP_SZ
    lea     r15, [rbx+MF_PTS+r15]
    lea     rdi, [r15+CP_RN]
    movaps  xmm0, [rbx+MF_NRM]
    call    row_make
    movss   [r15+CP_MN], xmm0
    lea     rdi, [r15+CP_RT1]
    movaps  xmm0, [rbx+MF_T1]
    call    row_make
    movss   [r15+CP_MT1], xmm0
    lea     rdi, [r15+CP_RT2]
    movaps  xmm0, [rbx+MF_T2]
    call    row_make
    movss   [r15+CP_MT2], xmm0
    movaps  xmm0, [r13+BD_POS]          # c0 = sep - n . (pB - pA)
    addps   xmm0, [r15+CP_RB]
    subps   xmm0, [r12+BD_POS]
    subps   xmm0, [r15+CP_RA]
    DOT3    xmm0, [rbx+MF_NRM]
    movss   xmm1, [r15+CP_SEP]
    subss   xmm1, xmm0
    movss   [r15+CP_C0], xmm1
    movaps  xmm0, [rbx+MF_NRM]
    lea     rdi, [r15+CP_RN]
    call    row_vel
    movss   [r15+CP_VN0], xmm0
    mov     dword ptr [r15+CP_JMAX], 0
    inc     r14d
    jmp     1b
9:  add     rsp, 8
    pop     r15
    pop     r14
    ret

# row_make(rdi=row, xmm0=its direction d; r15 the point, r12, r13 the
#   bodies) -> xmm0 = 1 / (mA + mB + (rA x d) IA (rA x d) + (rB x d) ...)
row_make:
    movaps  xmm7, xmm0
    movaps  xmm1, [r15+CP_RA]
    CROSS   xmm2, xmm1, xmm7, xmm3      # rA x d
    movaps  [rdi+RW_AX], xmm2
    MV3     xmm3, r12+BD_IIW, xmm2, xmm4, xmm5
    andps   xmm3, [rip+rx_xyz]
    movaps  [rdi+RW_IA], xmm3
    DOT3    xmm3, xmm2
    movss   xmm6, xmm3
    movaps  xmm1, [r15+CP_RB]
    CROSS   xmm2, xmm1, xmm7, xmm3      # rB x d
    movaps  [rdi+RW_BX], xmm2
    MV3     xmm3, r13+BD_IIW, xmm2, xmm4, xmm5
    andps   xmm3, [rip+rx_xyz]
    movaps  [rdi+RW_IB], xmm3
    DOT3    xmm3, xmm2
    addss   xmm6, xmm3
    addss   xmm6, [r12+BD_IM]
    addss   xmm6, [r13+BD_IM]
    maxss   xmm6, [rip+rx_tiny]
    movss   xmm0, [rip+rx_one]
    divss   xmm0, xmm6
    ret

# row_vel(rdi=row, xmm0=d; r12, r13) -> xmm0 = the speed along it:
#   (vB - vA) . d + wB . (rB x d) - wA . (rA x d)
row_vel:
    movaps  xmm1, [r13+BD_V]
    subps   xmm1, [r12+BD_V]
    DOT3    xmm1, xmm0
    movaps  xmm2, [r13+BD_W]
    DOT3    xmm2, [rdi+RW_BX]
    addss   xmm1, xmm2
    movaps  xmm2, [r12+BD_W]
    DOT3    xmm2, [rdi+RW_AX]
    subss   xmm1, xmm2
    movss   xmm0, xmm1
    ret

# row_push(rdi=row, xmm0=d, xmm1=the impulse; r12, r13) - -it on A, +it on
#   B (the moving ones)
row_push:
    shufps  xmm1, xmm1, 0
    cmp     dword ptr [r12+BD_TYPE], 1
    jne     1f
    movss   xmm2, [r12+BD_IM]
    shufps  xmm2, xmm2, 0
    mulps   xmm2, xmm0
    mulps   xmm2, xmm1
    movaps  xmm3, [r12+BD_V]
    subps   xmm3, xmm2
    movaps  [r12+BD_V], xmm3
    movaps  xmm2, [rdi+RW_IA]
    mulps   xmm2, xmm1
    movaps  xmm3, [r12+BD_W]
    subps   xmm3, xmm2
    movaps  [r12+BD_W], xmm3
1:  cmp     dword ptr [r13+BD_TYPE], 1
    jne     2f
    movss   xmm2, [r13+BD_IM]
    shufps  xmm2, xmm2, 0
    mulps   xmm2, xmm0
    mulps   xmm2, xmm1
    addps   xmm2, [r13+BD_V]
    movaps  [r13+BD_V], xmm2
    movaps  xmm2, [rdi+RW_IB]
    mulps   xmm2, xmm1
    addps   xmm2, [r13+BD_W]
    movaps  [r13+BD_W], xmm2
2:  ret

# mf_warm(rbx=manifold) - last time's impulses again (each substep)
mf_warm:
    push    r14
    push    r15
    sub     rsp, 8
    MFB
    xor     r14d, r14d
1:  cmp     r14d, [rbx+MF_N]
    jae     9f
    imul    r15, r14, CP_SZ
    lea     r15, [rbx+MF_PTS+r15]
    lea     rdi, [r15+CP_RN]
    movaps  xmm0, [rbx+MF_NRM]
    movss   xmm1, [r15+CP_JN]
    call    row_push
    lea     rdi, [r15+CP_RT1]
    movaps  xmm0, [rbx+MF_T1]
    movss   xmm1, [r15+CP_JT1]
    call    row_push
    lea     rdi, [r15+CP_RT2]
    movaps  xmm0, [rbx+MF_T2]
    movss   xmm1, [r15+CP_JT2]
    call    row_push
    inc     r14d
    jmp     1b
9:  add     rsp, 8
    pop     r15
    pop     r14
    ret

# mf_solve(rbx=manifold) / mf_relax - friction (within mu x the normal
#   impulse), then the normal (never pulling): the gap where the bodies are
#   now; closing: a speculative contact; overlapping: pushed apart softly
#   (mf_solve; mf_relax leaves the push out)
mf_relax:
    push    r14
    push    r15
    sub     rsp, 40                     # [rsp] the friction's limit, +4 push
    mov     dword ptr [rsp+4], 0        #  or not, +8 mass scale, +12 impulse
    jmp     mf_solve_in                 #  scale, +16 bias
mf_solve:
    push    r14
    push    r15
    sub     rsp, 40
    mov     dword ptr [rsp+4], 1
mf_solve_in:
    MFB
    xor     dword ptr [rbx+MF_DIR], 1   # each pass the other way round (no
    xor     r14d, r14d                  #  point always first)
1:  cmp     r14d, [rbx+MF_N]
    jae     9f
    mov     eax, r14d
    cmp     dword ptr [rbx+MF_DIR], 0
    je      11f
    mov     eax, [rbx+MF_N]
    sub     eax, r14d
    dec     eax
11: imul    r15, rax, CP_SZ
    lea     r15, [rbx+MF_PTS+r15]
    cmp     dword ptr [rsp+4], 0        # (relax: the normal only)
    je      12f
    movss   xmm0, [r15+CP_JN]           # the friction's limit
    mulss   xmm0, [rbx+MF_FRIC]
    movss   [rsp], xmm0
    mov     edx, MF_T1
    mov     ecx, CP_JT1
    mov     r8d, CP_MT1
    mov     r9d, CP_RT1
    call    fr_row
    mov     edx, MF_T2
    mov     ecx, CP_JT2
    mov     r8d, CP_MT2
    mov     r9d, CP_RT2
    call    fr_row
12:
    movaps  xmm0, [r15+CP_LB]           # the gap now: c0 + n . (pB - pA)
    MV3     xmm1, r13+BD_R, xmm0, xmm2, xmm3
    addps   xmm1, [r13+BD_POS]
    movaps  xmm0, [r15+CP_LA]
    MV3     xmm4, r12+BD_R, xmm0, xmm2, xmm3
    addps   xmm4, [r12+BD_POS]
    subps   xmm1, xmm4
    DOT3    xmm1, [rbx+MF_NRM]
    addss   xmm1, [r15+CP_C0]           # s
    movss   xmm5, [rip+rx_one]          # mass scale,
    xorps   xmm6, xmm6                  #  impulse scale,
    xorps   xmm7, xmm7                  #  bias
    comiss  xmm1, xmm6
    jbe     2f
    movss   xmm7, xmm1                  # apart: close no faster than s / h
    divss   xmm7, [rip+rb_h]
    jmp     3f
2:  cmp     dword ptr [rsp+4], 0
    je      3f
    lea     rax, [rip+rb_brate]         # overlapping: a soft push (stiffer
    cmp     dword ptr [r12+BD_TYPE], 2  #  against a static body)
    je      21f
    cmp     dword ptr [r13+BD_TYPE], 2
    jne     22f
21: lea     rax, [rip+rb_brate_s]
22: addss   xmm1, [rip+rx_slop]
    minss   xmm1, xmm6
    mulss   xmm1, [rax]
    movss   xmm7, [rip+rx_pushmax]
    xorps   xmm7, [rip+rx_sign]
    maxss   xmm7, xmm1
    movss   xmm5, [rax+4]
    movss   xmm6, [rax+8]
3:  movss   [rsp+8], xmm5
    movss   [rsp+12], xmm6
    movss   [rsp+16], xmm7
    lea     rdi, [r15+CP_RN]
    movaps  xmm0, [rbx+MF_NRM]
    call    row_vel                     # vn
    addss   xmm0, [rsp+16]              # -m ms (vn + bias) - is acc
    mulss   xmm0, [r15+CP_MN]
    mulss   xmm0, [rsp+8]
    xorps   xmm0, [rip+rx_sign]
    movss   xmm2, [r15+CP_JN]
    movss   xmm1, xmm2
    mulss   xmm1, [rsp+12]
    subss   xmm0, xmm1
    addss   xmm0, xmm2
    xorps   xmm3, xmm3
    maxss   xmm0, xmm3
    movss   [r15+CP_JN], xmm0
    movss   xmm1, [r15+CP_JMAX]
    maxss   xmm1, xmm0
    movss   [r15+CP_JMAX], xmm1
    subss   xmm0, xmm2
    movss   xmm1, xmm0
    lea     rdi, [r15+CP_RN]
    movaps  xmm0, [rbx+MF_NRM]
    call    row_push
    inc     r14d
    jmp     1b
9:  add     rsp, 40
    pop     r15
    pop     r14
    ret

# mf_bounce(rbx=manifold) - after the substeps: points that met faster than
#   1 m/s and pushed leave at their restitution x that speed
mf_bounce:
    push    r14
    push    r15
    sub     rsp, 8
    MFB
    xorps   xmm0, xmm0                  # (no bounce: nothing to do - a
    comiss  xmm0, [rbx+MF_REST]         #  speculative contact's pushing must
    jae     9f                          #  not stop a body short)
    xor     r14d, r14d
1:  cmp     r14d, [rbx+MF_N]
    jae     9f
    imul    r15, r14, CP_SZ
    lea     r15, [rbx+MF_PTS+r15]
    movss   xmm0, [rip+rx_bounce]
    xorps   xmm0, [rip+rx_sign]
    comiss  xmm0, [r15+CP_VN0]
    jbe     2f
    xorps   xmm0, xmm0
    comiss  xmm0, [r15+CP_JMAX]
    jae     2f
    lea     rdi, [r15+CP_RN]
    movaps  xmm0, [rbx+MF_NRM]
    call    row_vel
    movss   xmm1, [r15+CP_VN0]          # -m (vn + e vn0)
    mulss   xmm1, [rbx+MF_REST]
    addss   xmm0, xmm1
    mulss   xmm0, [r15+CP_MN]
    xorps   xmm0, [rip+rx_sign]
    movss   xmm2, [r15+CP_JN]
    addss   xmm0, xmm2
    xorps   xmm3, xmm3
    maxss   xmm0, xmm3
    movss   [r15+CP_JN], xmm0
    subss   xmm0, xmm2
    movss   xmm1, xmm0
    lea     rdi, [r15+CP_RN]
    movaps  xmm0, [rbx+MF_NRM]
    call    row_push
2:  inc     r14d
    jmp     1b
9:  add     rsp, 8
    pop     r15
    pop     r14
    ret

# fr_row(edx=tangent's offset in the manifold, ecx=its impulse's, r8d=its
#   mass's, r9d=its row's in the point; [rsp+8] = the limit) - one friction
#   direction
fr_row:
    push    r9
    push    r10
    push    r11
    mov     r10d, ecx
    mov     r11d, r8d
    mov     eax, edx
    movaps  xmm0, [rbx+rax]             # d (row_vel, row_push keep the GPRs)
    lea     rdi, [r15+r9]
    call    row_vel
    xorps   xmm0, [rip+rx_sign]         # -vt m
    mulss   xmm0, [r15+r11]
    movss   xmm2, [r15+r10]
    addss   xmm0, xmm2
    movss   xmm1, [rsp+32]              # (the caller's [rsp])
    minss   xmm0, xmm1
    xorps   xmm1, [rip+rx_sign]
    maxss   xmm0, xmm1
    movss   [r15+r10], xmm0
    subss   xmm0, xmm2
    movss   xmm1, xmm0
    lea     rdi, [r15+r9]
    mov     eax, edx
    movaps  xmm0, [rbx+rax]
    call    row_push
    pop     r11
    pop     r10
    pop     r9
    ret

# jr_prestep(rbx=joint) - anchors, errors, axes
jr_prestep:
    sub     rsp, 8
    test    dword ptr [rbx+JR_FL], 4    # (broken: nothing)
    jnz     9f
    mov     dword ptr [rbx+JR_MACC], 0
    mov     eax, [rbx+JR_A]
    BODY    r12, rax
    mov     eax, [rbx+JR_B]
    BODY    r13, rax
    movaps  xmm0, [rbx+JR_LA]
    MV3     xmm1, r12+BD_R, xmm0, xmm2, xmm3
    movaps  [rbx+JR_RA], xmm1
    addps   xmm1, [r12+BD_POS]
    movaps  xmm0, [rbx+JR_LB]
    MV3     xmm4, r13+BD_R, xmm0, xmm2, xmm3
    movaps  [rbx+JR_RB], xmm4
    addps   xmm4, [r13+BD_POS]
    subps   xmm4, xmm1
    movaps  [rbx+JR_C], xmm4            # pB - pA
    movaps  xmm0, [rbx+JR_AXA]          # the axis (world, from A)
    MV3     xmm6, r12+BD_R, xmm0, xmm2, xmm3
    movaps  [rbx+JR_AW], xmm6
    cmp     dword ptr [rbx+JR_TYPE], 4  # a slider: two rows square to it,
    jne     11f                         #  the angle held like fixed; where
    movaps  xmm0, xmm4                  #  it is: (pA - pB) . a (A's, from B)
    DOT3    xmm0, xmm6
    xorps   xmm0, [rip+rx_sign]
    movss   [rbx+JR_POS], xmm0
    sub     rsp, MF_SZ
    movaps  [rsp+MF_NRM], xmm6
    lea     rdi, [rsp]
    call    mf_tangents
    movaps  xmm0, [rsp+MF_T1]
    movaps  [rbx+JR_P], xmm0
    movaps  xmm0, [rsp+MF_T2]
    movaps  [rbx+JR_Q], xmm0
    add     rsp, MF_SZ
    jmp     1f
11: cmp     dword ptr [rbx+JR_TYPE], 2
    jne     1f
    movaps  xmm0, [rbx+JR_AXA]          # hinge: a, b; p, q square to a; a x b
    MV3     xmm6, r12+BD_R, xmm0, xmm2, xmm3
    movaps  xmm0, [rbx+JR_AXB]
    MV3     xmm5, r13+BD_R, xmm0, xmm2, xmm3
    CROSS   xmm4, xmm6, xmm5, xmm3
    movaps  [rbx+JR_ERR], xmm4
    sub     rsp, MF_SZ                  # (mf_tangents on a scratch normal)
    movaps  [rsp+MF_NRM], xmm6
    lea     rdi, [rsp]
    call    mf_tangents
    movaps  xmm0, [rsp+MF_T1]
    movaps  [rbx+JR_P], xmm0
    movaps  xmm0, [rsp+MF_T2]
    movaps  [rbx+JR_Q], xmm0
    add     rsp, MF_SZ
    cmp     dword ptr [rbx+JR_FL], 0    # (its angle: for limits, a motor)
    je      9f
1:  cmp     dword ptr [rbx+JR_TYPE], 3
    je      9f
    movaps  xmm0, [r13+BD_Q]            # 2 vec(qB conj(qA) conj(q0)) (fixed,
                                        #  slider: the error; hinge: its angle)
    movaps  xmm1, [r12+BD_Q]
    xorps   xmm1, [rip+rx_sign]
    call    q_mul
    movaps  xmm1, [rbx+JR_Q0]
    xorps   xmm1, [rip+rx_sign]
    call    q_mul
    movaps  xmm1, xmm0
    shufps  xmm1, xmm1, 0xFF
    xorps   xmm2, xmm2
    comiss  xmm1, xmm2
    jae     2f
    xorps   xmm0, [rip+rx_sign]
2:  cmp     dword ptr [rbx+JR_TYPE], 2  # a hinge: A's angle about its axis,
    jne     3f                          #  from B: -2 atan2(v . a, |w|)
    movaps  xmm1, xmm0
    DOT3    xmm1, [rbx+JR_AW]
    xorps   xmm1, [rip+rx_sign]
    movaps  xmm2, xmm0
    shufps  xmm2, xmm2, 0xFF
    andps   xmm2, [rip+rx_abs]
    movss   xmm0, xmm1
    movss   xmm1, xmm2
    call    rb_atan2
    addss   xmm0, xmm0
    movss   [rbx+JR_POS], xmm0
    jmp     9f
3:  addps   xmm0, xmm0
    andps   xmm0, [rip+rx_xyz]
    movaps  [rbx+JR_ERR], xmm0
9:  add     rsp, 8
    ret

# rb_atan2(xmm0=y, xmm1=x) -> xmm0 (re-entrant: x87 on the stack)
rb_atan2:
    sub     rsp, 8
    movss   [rsp], xmm0
    movss   [rsp+4], xmm1
    fld     dword ptr [rsp]
    fld     dword ptr [rsp+4]
    fpatan
    fstp    dword ptr [rsp]
    movss   xmm0, [rsp]
    add     rsp, 8
    ret

# jr_solve(rbx=joint) / jr_relax - the anchors together (three rows), then
#   the rotation: hinge, two rows square to its axis; fixed, three (jr_relax:
#   velocities only, no pull back)
jr_relax:
    push    r14
    push    r15
    sub     rsp, 24
    mov     dword ptr [rsp+20], 0
    jmp     jr_solve_in
jr_solve:
    push    r14
    push    r15
    sub     rsp, 24
    mov     eax, [rip+rx_one]
    mov     [rsp+20], eax               # (how much of the error to pull back)
jr_solve_in:
    test    dword ptr [rbx+JR_FL], 4    # (broken: nothing)
    jnz     9f
    mov     eax, [rbx+JR_A]
    BODY    r12, rax
    mov     eax, [rbx+JR_B]
    BODY    r13, rax
    xor     r14d, r14d
1:  cmp     r14d, 3
    jae     2f
    mov     eax, r14d
    shl     eax, 4
    lea     rcx, [rip+rx_ident]
    movaps  xmm0, [rcx+rax]
    cmp     dword ptr [rbx+JR_TYPE], 4  # a slider: its two rows square to
    jne     11f                         #  the axis only
    cmp     r14d, 2
    jae     2f
    movaps  xmm0, [rbx+JR_P]
    test    r14d, r14d
    jz      11f
    movaps  xmm0, [rbx+JR_Q]
11: movaps  [rsp], xmm0
    lea     rdi, [rbx+JR_RA]
    lea     rsi, [rbx+JR_RB]
    call    kmass
    movss   [rsp+16], xmm0
    lea     rdi, [rbx+JR_RA]
    lea     rsi, [rbx+JR_RB]
    call    relvel
    DOT3    xmm0, [rsp]                 # velocity along it
    movaps  xmm1, [rbx+JR_C]            # target: -beta (C . d) / h
    DOT3    xmm1, [rsp]
    mulss   xmm1, [rip+rx_beta]
    mulss   xmm1, [rsp+20]
    divss   xmm1, [rip+rb_h]
    xorps   xmm1, [rip+rx_sign]
    subss   xmm1, xmm0
    mulss   xmm1, [rsp+16]
    movss   xmm2, xmm1                  # (the joint's load, by row)
    addss   xmm2, [rbx+JR_IMP+r14*4]
    movss   [rbx+JR_IMP+r14*4], xmm2
    shufps  xmm1, xmm1, 0
    mulps   xmm1, [rsp]
    movaps  xmm0, xmm1
    lea     rdi, [rbx+JR_RA]
    lea     rsi, [rbx+JR_RB]
    call    impulse
    inc     r14d
    jmp     1b
2:  call    jr_extra                    # limits, a motor
    cmp     dword ptr [rbx+JR_TYPE], 3
    je      9f
    xor     r14d, r14d                  # angular rows
3:  cmp     dword ptr [rbx+JR_TYPE], 2
    jne     31f
    cmp     r14d, 2
    jae     9f
    lea     rax, [rbx+JR_P]
    test    r14d, r14d
    jz      32f
    lea     rax, [rbx+JR_Q]
32: movaps  xmm0, [rax]
    movaps  xmm1, [rbx+JR_ERR]
    DOT3    xmm1, xmm0
    jmp     33f
31: cmp     r14d, 3
    jae     9f
    mov     eax, r14d
    shl     eax, 4
    lea     rcx, [rip+rx_ident]
    movaps  xmm0, [rcx+rax]
    movss   xmm1, [rbx+JR_ERR+r14*4]
33: movaps  [rsp], xmm0                 # d; target -beta err / h
    mulss   xmm1, [rip+rx_beta]
    mulss   xmm1, [rsp+20]
    divss   xmm1, [rip+rb_h]
    xorps   xmm1, [rip+rx_sign]
    movss   [rsp+16], xmm1
    MV3     xmm1, r12+BD_IIW, xmm0, xmm2, xmm3   # k = d IA d + d IB d
    DOT3    xmm1, xmm0
    MV3     xmm4, r13+BD_IIW, xmm0, xmm2, xmm3
    DOT3    xmm4, xmm0
    addss   xmm1, xmm4
    maxss   xmm1, [rip+rx_tiny]
    movaps  xmm2, [r13+BD_W]            # (wB - wA) . d
    subps   xmm2, [r12+BD_W]
    DOT3    xmm2, xmm0
    movss   xmm3, [rsp+16]
    subss   xmm3, xmm2
    divss   xmm3, xmm1
    shufps  xmm3, xmm3, 0
    mulps   xmm3, [rsp]
    movaps  xmm0, xmm3
    call    ang_impulse
    inc     r14d
    jmp     3b
9:  add     rsp, 24
    pop     r15
    pop     r14
    ret

# jr_extra(rbx=joint, r12, r13 its bodies) - a hinge's or slider's limits
#   (one way: only pushing it back in) and motor (its speed, within its
#   torque / force over the substep)
jr_extra:
    push    r14
    sub     rsp, 16
    mov     eax, [rbx+JR_FL]
    test    eax, 3
    jz      9f
    mov     ecx, [rbx+JR_TYPE]
    cmp     ecx, 2
    je      1f
    cmp     ecx, 4
    jne     9f
1:  test    eax, 1                      # limits
    jz      5f
    movss   xmm0, [rbx+JR_LO]           # below: push up (the speed it needs
    subss   xmm0, [rbx+JR_POS]          #  to be back, beta-damped)
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    jbe     2f
    mulss   xmm0, [rip+rx_beta]
    divss   xmm0, [rip+rb_h]
    mov     r14d, 1                     # (pushing +)
    jmp     3f
2:  movss   xmm0, [rbx+JR_HI]           # above: push down
    subss   xmm0, [rbx+JR_POS]
    comiss  xmm0, xmm1
    jae     5f
    mulss   xmm0, [rip+rx_beta]
    divss   xmm0, [rip+rb_h]
    mov     r14d, -1
3:  mulss   xmm0, [rsp+52]              # (none in the relax pass)
    movss   [rsp], xmm0                 # target speed along the axis
    call    jr_axis_speed               # xmm0 = now, xmm1 = 1 / k
    movss   xmm2, [rsp]
    subss   xmm2, xmm0                  # dv = target - now: only that way
    xorps   xmm3, xmm3
    test    r14d, r14d
    js      31f
    comiss  xmm2, xmm3
    jbe     5f
    jmp     32f
31: comiss  xmm2, xmm3
    jae     5f
32: mulss   xmm2, xmm1
    movss   xmm0, xmm2
    call    jr_axis_push
5:  test    dword ptr [rbx+JR_FL], 2    # a motor
    jz      9f
    call    jr_axis_speed
    movss   xmm2, [rbx+JR_MS]
    subss   xmm2, xmm0
    mulss   xmm2, xmm1                  # the impulse it wants; the most over
    movss   xmm3, [rbx+JR_MF]           #  this substep: force x h
    mulss   xmm3, [rip+rb_h]
    movss   xmm4, [rbx+JR_MACC]
    addss   xmm2, xmm4
    minss   xmm2, xmm3
    xorps   xmm3, [rip+rx_sign]
    maxss   xmm2, xmm3
    movss   [rbx+JR_MACC], xmm2
    subss   xmm2, xmm4
    movss   xmm0, xmm2
    call    jr_axis_push
9:  add     rsp, 16
    pop     r14
    ret

# jr_axis_speed(rbx, r12, r13) -> xmm0 = the joint's speed along its axis
#   (A's, from B: hinge wA - wB; slider vA - vB at the anchors), xmm1 = its
#   effective mass
jr_axis_speed:
    sub     rsp, 24
    cmp     dword ptr [rbx+JR_TYPE], 2
    jne     1f
    movaps  xmm0, [rbx+JR_AW]           # k = a IA a + a IB a
    MV3     xmm1, r12+BD_IIW, xmm0, xmm2, xmm3
    DOT3    xmm1, xmm0
    MV3     xmm4, r13+BD_IIW, xmm0, xmm2, xmm3
    DOT3    xmm4, xmm0
    addss   xmm1, xmm4
    maxss   xmm1, [rip+rx_tiny]
    movss   xmm5, [rip+rx_one]
    divss   xmm5, xmm1
    movaps  xmm2, [r12+BD_W]            # (A's, from B)
    subps   xmm2, [r13+BD_W]
    DOT3    xmm2, xmm0
    movss   xmm0, xmm2
    movss   xmm1, xmm5
    add     rsp, 24
    ret
1:  movaps  xmm0, [rbx+JR_AW]           # a slider
    lea     rdi, [rbx+JR_RA]
    lea     rsi, [rbx+JR_RB]
    call    kmass
    movss   [rsp], xmm0
    lea     rdi, [rbx+JR_RA]
    lea     rsi, [rbx+JR_RB]
    call    relvel
    DOT3    xmm0, [rbx+JR_AW]
    xorps   xmm0, [rip+rx_sign]         # (A's, from B)
    movss   xmm1, [rsp]
    add     rsp, 24
    ret

# jr_axis_push(xmm0=impulse along the axis; rbx, r12, r13) - +on A, -on B
jr_axis_push:
    sub     rsp, 8
    xorps   xmm0, [rip+rx_sign]
    shufps  xmm0, xmm0, 0
    mulps   xmm0, [rbx+JR_AW]
    cmp     dword ptr [rbx+JR_TYPE], 2
    jne     1f
    call    ang_impulse                 # a hinge: turning
    jmp     9f
1:  lea     rdi, [rbx+JR_RA]            # a slider: at the anchors
    lea     rsi, [rbx+JR_RB]
    call    impulse
9:  add     rsp, 8
    ret

# jr_breaks - after a step: a joint whose load passed its breaking force
#   (impulse over the step's time) is gone for the rest of the run; the
#   loads start again
jr_breaks:
    xor     ecx, ecx
1:  cmp     ecx, [rip+rb_njr]
    jae     9f
    imul    rax, rcx, JR_SZ
    add     rax, [rip+rb_jr]
    movss   xmm0, [rax+JR_BRK]
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    jbe     2f
    mulss   xmm0, [rip+rb_dt]           # (force x dt: an impulse)
    movss   xmm1, [rax+JR_IMP]
    mulss   xmm1, xmm1
    movss   xmm2, [rax+JR_IMP+4]
    mulss   xmm2, xmm2
    addss   xmm1, xmm2
    movss   xmm2, [rax+JR_IMP+8]
    mulss   xmm2, xmm2
    addss   xmm1, xmm2
    sqrtss  xmm1, xmm1
    comiss  xmm0, xmm1
    jae     2f
    or      dword ptr [rax+JR_FL], 4
    inc     dword ptr [rip+rb_nbroken]
2:  mov     dword ptr [rax+JR_IMP], 0
    mov     dword ptr [rax+JR_IMP+4], 0
    mov     dword ptr [rax+JR_IMP+8], 0
    inc     ecx
    jmp     1b
9:  ret

# island_job(rdi=ctx, esi=begin, edx=end)
island_job:
    push    rbx
    push    r12
    push    r13
    mov     r12d, esi
    mov     r13d, edx
1:  cmp     r12d, r13d
    jae     9f
    mov     rax, [rip+rb_iaw]
    cmp     dword ptr [rax+r12*4], 0
    je      2f
    mov     edi, r12d
    call    isl_big
    jnz     2f                          # (solved after, across the workers)
    mov     edi, r12d
    call    solve_island
2:  inc     r12d
    jmp     1b
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# solve_island(edi=island) - the step in substeps: forces, last time's
#   impulses, the joints and contacts (iterations), the bodies moved, a
#   relax pass; then restitution, and rest
solve_island:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    and     rsp, -16
    sub     rsp, 48
    mov     [rsp], edi
    mov     edi, [rsp]                  # once a step: masses, gaps
    lea     rsi, [rip+mf_prestep]
    call    isl_each_mf
    mov     dword ptr [rsp+12], 0       # substeps
.Lsi_sub:
    mov     eax, [rsp+12]
    cmp     eax, [rip+rb_nsub]
    jae     .Lsi_end
    # forces: gravity, damping
    mov     edi, [rsp]
    mov     rax, [rip+rb_isb]
    mov     r14d, [rax+rdi*4]
    mov     r15d, [rax+rdi*4+4]
1:  cmp     r14d, r15d
    jae     2f
    mov     rax, [rip+rb_ib]
    mov     eax, [rax+r14*4]
    BODY    rdi, rax
    call    body_force
    inc     r14d
    jmp     1b
2:  mov     edi, [rsp]
    lea     rsi, [rip+mf_warm]
    call    isl_each_mf
    mov     edi, [rsp]
    lea     rsi, [rip+jr_prestep]
    call    isl_each_jr
    mov     dword ptr [rsp+4], 0        # iterations
3:  mov     eax, [rsp+4]
    cmp     eax, [rip+rb_iter]
    jae     4f
    mov     edi, [rsp]
    lea     rsi, [rip+jr_solve]
    call    isl_each_jr
    mov     edi, [rsp]
    lea     rsi, [rip+mf_solve]
    call    isl_each_mf
    inc     dword ptr [rsp+4]
    jmp     3b
4:  mov     edi, [rsp]                  # move
    mov     rax, [rip+rb_isb]
    mov     r14d, [rax+rdi*4]
    mov     r15d, [rax+rdi*4+4]
41: cmp     r14d, r15d
    jae     42f
    mov     rax, [rip+rb_ib]
    mov     eax, [rax+r14*4]
    BODY    rdi, rax
    call    integrate
    inc     r14d
    jmp     41b
42: mov     edi, [rsp]                  # relax
    lea     rsi, [rip+jr_prestep]
    call    isl_each_jr
    mov     edi, [rsp]
    lea     rsi, [rip+jr_relax]
    call    isl_each_jr
    mov     edi, [rsp]
    lea     rsi, [rip+mf_relax]
    call    isl_each_mf
    inc     dword ptr [rsp+12]
    jmp     .Lsi_sub
.Lsi_end:
    mov     edi, [rsp]
    lea     rsi, [rip+mf_bounce]
    call    isl_each_mf
    mov     edi, [rsp]
    call    isl_rest
9:  lea     rsp, [rbp-40]
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret

# isl_rest(edi=island) - each body's time at rest; all of them long enough
#   at rest: the island sleeps
isl_rest:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    and     rsp, -16
    sub     rsp, 16
    mov     [rsp], edi
    movss   xmm0, [rip+rx_sleep]
    movss   [rsp+8], xmm0               # the least time at rest
    mov     edi, [rsp]
    mov     rax, [rip+rb_isb]
    mov     r14d, [rax+rdi*4]
    mov     r15d, [rax+rdi*4+4]
5:  cmp     r14d, r15d
    jae     6f
    mov     rax, [rip+rb_ib]
    mov     eax, [rax+r14*4]
    BODY    rbx, rax
    movaps  xmm0, [rbx+BD_V]
    DOT3    xmm0, xmm0
    movaps  xmm1, [rbx+BD_W]
    DOT3    xmm1, xmm1
    maxss   xmm0, xmm1
    xorps   xmm2, xmm2
    comiss  xmm0, [rip+rx_rest2]
    jae     51f
    movss   xmm2, [rbx+BD_SLEEP]
    addss   xmm2, [rip+rb_dt]
51: movss   [rbx+BD_SLEEP], xmm2
    minss   xmm2, [rsp+8]
    movss   [rsp+8], xmm2
    inc     r14d
    jmp     5b
6:  movss   xmm0, [rsp+8]               # all at rest long enough: asleep
    comiss  xmm0, [rip+rx_sleep]
    jb      9f
    mov     edi, [rsp]
    mov     rax, [rip+rb_isb]
    mov     r14d, [rax+rdi*4]
    mov     r15d, [rax+rdi*4+4]
7:  cmp     r14d, r15d
    jae     9f
    mov     rax, [rip+rb_ib]
    mov     eax, [rax+r14*4]
    BODY    rbx, rax
    mov     dword ptr [rbx+BD_ASLEEP], 1
    xorps   xmm0, xmm0
    movaps  [rbx+BD_V], xmm0
    movaps  [rbx+BD_W], xmm0
    inc     r14d
    jmp     7b
9:  lea     rsp, [rbp-40]
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret

# body_force(rdi=body) - a substep's gravity and damping
body_force:
    movss   xmm6, [rip+rb_h]
    movaps  xmm7, [rip+rb_g]
    shufps  xmm6, xmm6, 0
    mulps   xmm7, xmm6                  # g h
    movaps  xmm0, [rdi+BD_V]
    addps   xmm0, xmm7
    movss   xmm1, [rdi+BD_DAMP]         # v / (1 + h d)
    mulss   xmm1, [rip+rb_h]
    addss   xmm1, [rip+rx_one]
    shufps  xmm1, xmm1, 0
    divps   xmm0, xmm1
    andps   xmm0, [rip+rx_xyz]
    movaps  [rdi+BD_V], xmm0
    movss   xmm1, [rip+rx_adamp]
    mulss   xmm1, [rip+rb_h]
    addss   xmm1, [rip+rx_one]
    shufps  xmm1, xmm1, 0
    movaps  xmm0, [rdi+BD_W]
    divps   xmm0, xmm1
    andps   xmm0, [rip+rx_xyz]
    movaps  [rdi+BD_W], xmm0
    ret

# isl_big(edi=island) -> ZF clear when it has 128 constraints or more (its
#   colours are solved across the workers)
isl_big:
    mov     rax, [rip+rb_ism]
    mov     ecx, [rax+rdi*4+4]
    sub     ecx, [rax+rdi*4]
    mov     rax, [rip+rb_isj]
    add     ecx, [rax+rdi*4+4]
    sub     ecx, [rax+rdi*4]
    xor     eax, eax
    cmp     ecx, 128
    setae   al
    test    eax, eax
    ret

# solve_big(edi=island) - solve_island's steps for a big island: its
#   manifolds and joints coloured (greedy: the first colour neither moving
#   body has; 64 of them, the rest serial), each colour across the workers
#   (no two of a colour share a moving body: the same result on any number
#   of threads)
solve_big:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    and     rsp, -16
    sub     rsp, 48
    mov     [rsp], edi
    # the constraints: manifolds, joints (| 1 << 31)
    mov     r12, [rip+rb_bcon]
    xor     r13d, r13d
    mov     rax, [rip+rb_ism]
    mov     r14d, [rax+rdi*4]
    mov     r15d, [rax+rdi*4+4]
1:  cmp     r14d, r15d
    jae     2f
    mov     rax, [rip+rb_imf]
    mov     eax, [rax+r14*4]
    mov     [r12+r13*4], eax
    inc     r13d
    inc     r14d
    jmp     1b
2:  mov     edi, [rsp]
    mov     rax, [rip+rb_isj]
    mov     r14d, [rax+rdi*4]
    mov     r15d, [rax+rdi*4+4]
3:  cmp     r14d, r15d
    jae     4f
    mov     rax, [rip+rb_ij]
    mov     eax, [rax+r14*4]
    or      eax, 0x80000000
    mov     [r12+r13*4], eax
    inc     r13d
    inc     r14d
    jmp     3b
4:  mov     [rsp+16], r13d              # how many
    # colours: the bodies' masks cleared, then greedy
    mov     edi, [rsp]
    mov     rax, [rip+rb_isb]
    mov     r14d, [rax+rdi*4]
    mov     r15d, [rax+rdi*4+4]
    mov     rcx, [rip+rb_bmask]
5:  cmp     r14d, r15d
    jae     6f
    mov     rax, [rip+rb_ib]
    mov     eax, [rax+r14*4]
    mov     qword ptr [rcx+rax*8], 0
    inc     r14d
    jmp     5b
6:  mov     rdi, [rip+rb_bcst]          # colour counts (at +1)
    mov     ecx, 68
    xor     eax, eax
    rep     stosd
    xor     r14d, r14d
7:  cmp     r14d, [rsp+16]
    jae     8f
    mov     edi, [r12+r14*4]
    call    con_bodies                  # r8, r9: the moving ones' masks, or 0
    xor     rax, rax
    test    r8, r8
    jz      71f
    or      rax, [r8]
71: test    r9, r9
    jz      72f
    or      rax, [r9]
72: not     rax
    mov     ecx, 64                     # (all taken: 64, the serial one)
    tzcnt   rdx, rax
    cmovc   edx, ecx
    mov     rax, [rip+rb_bcol]
    mov     [rax+r14*4], edx
    mov     rax, [rip+rb_bcst]
    inc     dword ptr [rax+rdx*4+4]
    cmp     edx, 64
    jae     74f
    xor     eax, eax
    bts     rax, rdx
    test    r8, r8
    jz      73f
    or      [r8], rax
73: test    r9, r9
    jz      74f
    or      [r9], rax
74: inc     r14d
    jmp     7b
8:  mov     rcx, [rip+rb_bcst]          # starts; sorted (stable)
    xor     eax, eax
    xor     edx, edx
81: cmp     edx, 65
    ja      82f
    add     eax, [rcx+rdx*4]
    mov     [rcx+rdx*4], eax
    inc     edx
    jmp     81b
82: sub     rsp, 272                    # (cursors)
    mov     rsi, rcx
    lea     rdi, [rsp]
    mov     ecx, 66
    rep     movsd
    xor     r14d, r14d
83: cmp     r14d, [rsp+272+16]
    jae     84f
    mov     rax, [rip+rb_bcol]
    mov     eax, [rax+r14*4]
    mov     edx, [rsp+rax*4]
    inc     dword ptr [rsp+rax*4]
    mov     ecx, [r12+r14*4]
    mov     rax, [rip+rb_bsrt]
    mov     [rax+rdx*4], ecx
    inc     r14d
    jmp     83b
84: add     rsp, 272
    # the step as stages: each colour of each pass, the bodies' passes;
    #   then the workers run them all in one go (stage_job)
    mov     dword ptr [rip+rb_nstg], 0
    mov     edi, [rsp]
    mov     rax, [rip+rb_isj]
    mov     ecx, [rax+rdi*4+4]
    sub     ecx, [rax+rdi*4]
    mov     [rip+rb_islj], ecx
    lea     rsi, [rip+mf_prestep]       # once a step: masses, gaps (all at
    lea     rdx, [rip+jr_prestep]       #  once: no body written)
    call    st_all
    mov     dword ptr [rsp+12], 0
.Lsb_sub:
    mov     eax, [rsp+12]
    cmp     eax, [rip+rb_nsub]
    jae     .Lsb_end
    mov     edi, [rsp]
    lea     rsi, [rip+body_force]
    call    st_bodies
    lea     rsi, [rip+mf_warm]
    xor     edx, edx
    call    st_colours
    cmp     dword ptr [rsp+12], 0       # (the first substep's joints: the
    je      90f                         #  prestep did them)
    cmp     dword ptr [rip+rb_islj], 0
    je      90f
    xor     esi, esi
    lea     rdx, [rip+jr_prestep]
    call    st_all
90: mov     dword ptr [rsp+4], 0
91: mov     eax, [rsp+4]
    cmp     eax, [rip+rb_iter]
    jae     92f
    lea     rsi, [rip+mf_solve]
    lea     rdx, [rip+jr_solve]
    call    st_colours
    inc     dword ptr [rsp+4]
    jmp     91b
92: mov     edi, [rsp]
    lea     rsi, [rip+integrate]
    call    st_bodies
    cmp     dword ptr [rip+rb_islj], 0
    je      93f
    xor     esi, esi
    lea     rdx, [rip+jr_prestep]
    call    st_all
93: lea     rsi, [rip+mf_relax]
    lea     rdx, [rip+jr_relax]
    call    st_colours
    inc     dword ptr [rsp+12]
    jmp     .Lsb_sub
.Lsb_end:
    lea     rsi, [rip+mf_bounce]
    xor     edx, edx
    call    st_colours
    cmp     dword ptr [rip+rb_nstg], ST_MAX
    jbe     94f
    mov     edi, [rsp]                  # (too many stages: one thread)
    call    solve_island
    jmp     96f
94: mov     rdi, [rip+rb_scnt]          # counters cleared; run
    mov     ecx, [rip+rb_nstg]
    shl     ecx, 7
    xor     eax, eax
    rep     stosb
    mov     eax, [rip+n_workers]        # lanes: the threads, but no more
    inc     eax                         #  than half of them past 8 (spinning
    mov     edx, eax                    #  hyperthreads slow their siblings),
    shr     edx, 1                      #  nor one for less than 256
    cmp     edx, 8                      #  constraints
    jae     941f
    mov     edx, 8
941:cmp     edx, eax
    cmova   edx, eax
    mov     eax, [rsp+16]
    shr     eax, 8
    cmp     eax, 1
    adc     eax, 0
    cmp     edx, eax
    cmova   edx, eax
    lea     rdi, [rip+stage_job]
    xor     esi, esi
    mov     ecx, 1
    call    parallel_for
    mov     edi, [rsp]
    call    isl_rest
96: lea     rsp, [rbp-40]
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret

# con_bodies(edi=constraint) -> r8, r9 = its bodies' colour masks when they
#   move, else 0
con_bodies:
    test    edi, edi
    js      1f
    imul    rax, rdi, MF_SZ
    add     rax, [rip+rb_mf]
    mov     ecx, [rax+MF_A]
    mov     edx, [rax+MF_B]
    jmp     2f
1:  and     edi, 0x7fffffff
    imul    rax, rdi, JR_SZ
    add     rax, [rip+rb_jr]
    mov     ecx, [rax+JR_A]
    mov     edx, [rax+JR_B]
2:  xor     r8d, r8d
    xor     r9d, r9d
    BODY    rax, rcx
    cmp     dword ptr [rax+BD_TYPE], 1
    jne     3f
    mov     r8, [rip+rb_bmask]
    lea     r8, [r8+rcx*8]
3:  BODY    rax, rdx
    cmp     dword ptr [rax+BD_TYPE], 1
    jne     4f
    mov     r9, [rip+rb_bmask]
    lea     r9, [r9+rdx*8]
4:  ret

# ---- stages ----------------------------------------------------------------

# st_add(rdi=items, esi=count, edx=block size, ecx=kind, r8=fn, r9=fn) -
#   a stage at the end (none when full: the step is not run that way)
st_add:
    test    esi, esi
    jz      9f
    mov     eax, [rip+rb_nstg]
    inc     dword ptr [rip+rb_nstg]
    cmp     eax, ST_MAX
    jae     9f
    imul    rax, rax, ST_SZ
    add     rax, [rip+rb_stg]
    mov     [rax+ST_BASE], rdi
    mov     [rax+ST_N], esi
    mov     [rax+ST_GR], edx
    mov     [rax+ST_KIND], ecx
    mov     [rax+ST_FMF], r8
    mov     [rax+ST_FJR], r9
9:  ret

# st_colours(rsi=fn for manifolds, rdx=fn for joints) - a stage per colour
#   (the last, the serial one, a single block)
st_colours:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r14, rsi
    mov     r15, rdx
    xor     ebx, ebx
1:  cmp     ebx, 64
    ja      9f
    mov     rax, [rip+rb_bcst]
    mov     r12d, [rax+rbx*4]
    mov     r13d, [rax+rbx*4+4]
    sub     r13d, r12d
    jz      8f
    mov     rdi, [rip+rb_bsrt]
    lea     rdi, [rdi+r12*4]
    mov     esi, r13d
    mov     edx, 16
    cmp     ebx, 64
    jne     2f
    mov     edx, r13d
2:  xor     ecx, ecx
    mov     r8, r14
    mov     r9, r15
    call    st_add
8:  inc     ebx
    jmp     1b
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# st_all(rsi, rdx) - one stage of every constraint (passes that write no
#   body)
st_all:
    mov     r8, rsi
    mov     r9, rdx
    mov     rax, [rip+rb_bcst]
    mov     esi, [rax+65*4]
    mov     rdi, [rip+rb_bsrt]
    mov     edx, 32
    xor     ecx, ecx
    jmp     st_add

# st_bodies(edi=island, rsi=fn(rdi=body)) - a stage of its bodies
st_bodies:
    mov     r8, rsi
    xor     r9d, r9d
    mov     rax, [rip+rb_isb]
    mov     ecx, [rax+rdi*4]
    mov     esi, [rax+rdi*4+4]
    sub     esi, ecx
    mov     rdi, [rip+rb_ib]
    lea     rdi, [rdi+rcx*4]
    mov     edx, 64
    mov     ecx, 1
    jmp     st_add

# stage_job(rdi=ctx, esi=begin, edx=end) - a lane: every stage in turn; in
#   each it takes blocks while there are some, then waits until all of them
#   are done (a lane that starts late holds no block: no one waits on it)
stage_job:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r12d, esi
    mov     r13d, edx
1:  cmp     r12d, r13d
    jae     9f
    xor     r14d, r14d                  # stage
2:  cmp     r14d, [rip+rb_nstg]
    jae     8f
    imul    rbx, r14, ST_SZ
    add     rbx, [rip+rb_stg]
    mov     eax, [rbx+ST_N]             # blocks
    add     eax, [rbx+ST_GR]
    dec     eax
    xor     edx, edx
    div     dword ptr [rbx+ST_GR]
    mov     r15d, eax
3:  mov     rcx, r14                    # take a block
    shl     rcx, 7
    add     rcx, [rip+rb_scnt]
    mov     eax, 1
    lock xadd [rcx], eax
    cmp     eax, r15d
    jae     5f
    push    rcx
    push    rcx
    mov     edi, eax
    call    st_block
    pop     rcx
    pop     rcx
    lock inc dword ptr [rcx+64]
    jmp     3b
5:  cmp     [rcx+64], r15d              # all of them done
    jae     6f
    pause
    jmp     5b
6:  inc     r14d
    jmp     2b
8:  inc     r12d
    jmp     1b
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# st_block(edi=block; rbx = its stage) - the stage's fn on that block
st_block:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r15, rbx
    mov     r14d, edi
    imul    r14d, [r15+ST_GR]           # first,
    mov     r13d, r14d                  #  end
    add     r13d, [r15+ST_GR]
    cmp     r13d, [r15+ST_N]
    jbe     1f
    mov     r13d, [r15+ST_N]
1:  cmp     r14d, r13d
    jae     9f
    mov     rax, [r15+ST_BASE]
    mov     eax, [rax+r14*4]
    cmp     dword ptr [r15+ST_KIND], 1
    je      4f
    test    eax, eax
    js      2f
    mov     rcx, [r15+ST_FMF]
    test    rcx, rcx
    jz      8f
    imul    rbx, rax, MF_SZ
    add     rbx, [rip+rb_mf]
    push    r13                         # (the fns take r12, r13 for the
    push    r13                         #  bodies)
    call    rcx
    pop     r13
    pop     r13
    jmp     8f
2:  mov     rcx, [r15+ST_FJR]
    test    rcx, rcx
    jz      8f
    and     eax, 0x7fffffff
    imul    rbx, rax, JR_SZ
    add     rbx, [rip+rb_jr]
    push    r13
    push    r13
    call    rcx
    pop     r13
    pop     r13
    jmp     8f
4:  BODY    rdi, rax                    # a body
    push    r13
    push    r13
    call    [r15+ST_FMF]
    pop     r13
    pop     r13
8:  inc     r14d
    jmp     1b
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# isl_each_mf(edi=island, rsi=fn(rbx=manifold)) / isl_each_jr (rbx=joint)
isl_each_mf:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r15, rsi
    mov     rax, [rip+rb_ism]
    mov     r14d, [rax+rdi*4]
    mov     r13d, [rax+rdi*4+4]
1:  cmp     r14d, r13d
    jae     9f
    mov     rax, [rip+rb_imf]
    mov     eax, [rax+r14*4]
    imul    rbx, rax, MF_SZ
    add     rbx, [rip+rb_mf]
    push    r12
    push    r13
    call    r15
    pop     r13
    pop     r12
    inc     r14d
    jmp     1b
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
isl_each_jr:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r15, rsi
    mov     rax, [rip+rb_isj]
    mov     r14d, [rax+rdi*4]
    mov     r13d, [rax+rdi*4+4]
1:  cmp     r14d, r13d
    jae     9f
    mov     rax, [rip+rb_ij]
    mov     eax, [rax+r14*4]
    imul    rbx, rax, JR_SZ
    add     rbx, [rip+rb_jr]
    push    r12
    push    r13
    call    r15
    pop     r13
    pop     r12
    inc     r14d
    jmp     1b
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# integrate(rdi=body) - position, orientation (q += dt/2 (w, 0) q), the rest
integrate:
    push    rbx
    mov     rbx, rdi
    movss   xmm6, [rip+rb_h]
    shufps  xmm6, xmm6, 0
    movaps  xmm0, [rbx+BD_V]
    mulps   xmm0, xmm6
    addps   xmm0, [rbx+BD_POS]
    andps   xmm0, [rip+rx_xyz]
    movaps  [rbx+BD_POS], xmm0
    movaps  xmm0, [rbx+BD_W]
    andps   xmm0, [rip+rx_xyz]
    movaps  xmm1, [rbx+BD_Q]
    call    q_mul
    movss   xmm6, [rip+rb_h]
    mulss   xmm6, [rip+rx_half]
    shufps  xmm6, xmm6, 0
    mulps   xmm0, xmm6
    addps   xmm0, [rbx+BD_Q]
    movaps  xmm1, xmm0
    dpps    xmm1, xmm1, 0xF1
    sqrtss  xmm1, xmm1
    shufps  xmm1, xmm1, 0
    divps   xmm0, xmm1
    movaps  [rbx+BD_Q], xmm0
    mov     rdi, rbx
    call    body_update
    pop     rbx
    ret

# -----------------------------------------------------------------------------
# Frames
# -----------------------------------------------------------------------------
# rb_sethash -> rax = a stamp of the settings (not the kept start)
rb_sethash:
    push    rbx
    mov     rbx, [rip+an_cur]
    mov     rax, 0x9E3779B97F4A7C15
    mov     r8, rax
    xor     rax, [rbx+AN_NRB_]          # (with the joints' count)
    imul    rax, r8
    lea     rsi, [rbx+AN_RW_]
    mov     ecx, RW_SZ_/8
1:  xor     rax, [rsi]
    imul    rax, r8
    add     rsi, 8
    dec     ecx
    jnz     1b
    xor     edx, edx
2:  cmp     edx, [rbx+AN_NRB_]
    jae     4f
    imul    rsi, rdx, RB_SZ_
    lea     rsi, [rbx+AN_RB_+rsi]
    mov     ecx, 4
3:  mov     r9, [rsi]
    cmp     ecx, 1                      # (not RB_FLAGS bit 0: the start kept)
    jne     31f
    btr     r9, 32
31: xor     rax, r9
    imul    rax, r8
    add     rsi, 8
    dec     ecx
    jnz     3b
    sub     rsi, 32                     # its velocity too (not the start
    xor     rax, [rsi+RB_VEL]           #  before it: play keeps that)
    imul    rax, r8
    mov     r9d, [rsi+RB_VEL+8]
    xor     rax, r9
    imul    rax, r8
    inc     edx
    jmp     2b
4:  mov     ecx, [rbx+AN_NJT_]
    imul    ecx, ecx, JT_SZ_/8
    lea     rsi, [rbx+AN_JT_]
5:  test    ecx, ecx
    jz      9f
    xor     rax, [rsi]
    imul    rax, r8
    add     rsi, 8
    dec     ecx
    jmp     5b
9:  pop     rbx
    ret

# rb_reset - a new scene: no simulation
rb_reset:
    jmp     rb_free

# rb_frame(xmm0=frame) - the simulation at that frame: none at or before the
#   start (objects back where they began); a cached frame played back; else
#   stepped on (or begun again when going back or when the key changed),
#   each whole frame reached kept in the cache, bodies into objects
rb_frame:
    push    rbx
    push    r12
    sub     rsp, 56
    cmp     dword ptr [rip+rb_busy], 0
    jne     .Lrf_ret
    mov     dword ptr [rip+rb_busy], 1
    movss   [rsp], xmm0
    mov     rbx, [rip+an_cur]
    test    rbx, rbx
    jz      .Lrf_gone
    cmp     dword ptr [rbx+AN_NRB_], 0
    je      .Lrf_gone
    cvtsi2ss xmm1, dword ptr [rbx+AN_START]
    movss   [rsp+4], xmm1
    call    rb_key
    mov     r12, rax
    xor     edi, edi
    mov     rsi, r12
    mov     edx, [rbx+AN_START]
    call    sc_check
    mov     [rsp+32], eax               # baked
    movss   xmm0, [rsp]
    comiss  xmm0, [rsp+4]
    jbe     .Lrf_none
    cvttss2si esi, xmm0                 # a cached frame?
    cvtsi2ss xmm1, esi
    cmp     dword ptr [rsp+32], 0
    je      11f
    xor     edi, edi                    # baked: the frame (or the last)
    mov     [rsp+36], esi
    call    sc_last
    mov     esi, [rsp+36]
    cmp     esi, eax
    cmovg   esi, eax
    jmp     12f
11: cmp     dword ptr [rip+rb_islive], 0  # (play mode: always simulated)
    jne     13f
    ucomiss xmm0, xmm1
    jne     13f
12: xor     edi, edi
    call    sc_get
    test    rax, rax
    jz      13f
    mov     [rsp+40], rax
    call    rb_capture
    mov     rdi, [rsp+40]
    call    rb_play
    jmp     .Lrf_out
13: cmp     dword ptr [rsp+32], 0       # (baked, nothing there: as it is)
    jne     .Lrf_out
    cmp     dword ptr [rip+rb_on], 0
    je      2f
    cmp     r12, [rip+rb_hash]
    jne     1f
    movss   xmm0, [rsp]
    comiss  xmm0, [rip+rb_fnow]
    jae     3f
1:  call    rb_free                     # changed / going back: again
    call    rb_restore
2:  call    rb_build
    cmp     dword ptr [rip+rb_on], 0
    je      .Lrf_out
    mov     [rip+rb_hash], r12
    mov     dword ptr [rip+rb_time], 0
    call    rb_pend_apply
3:  call    now_ms                      # steps up to the frame's time
    mov     [rsp+8], rax
    movss   xmm1, [rbx+AN_FPS]
    xorps   xmm2, xmm2
    comiss  xmm1, xmm2
    ja      31f
    movss   xmm1, [rip+rx_24]
31: movss   [rsp+20], xmm1              # fps
    movss   xmm0, [rsp]
    subss   xmm0, [rsp+4]
    divss   xmm0, xmm1
    movss   [rsp+16], xmm0              # the time to reach
4:  cmp     dword ptr [rip+rb_islive], 0  # (play mode: nothing kept)
    jne     41f
    xor     edi, edi                    # a whole frame reached: kept
    call    sc_last
    inc     eax
    cvtsi2ss xmm0, eax
    comiss  xmm0, [rsp]
    ja      41f
    mov     [rsp+24], eax
    subss   xmm0, [rsp+4]
    divss   xmm0, [rsp+20]
    movss   xmm1, [rip+rb_dt]
    mulss   xmm1, [rip+rx_half]
    addss   xmm1, [rip+rb_time]
    comiss  xmm1, xmm0
    jb      41f
    mov     esi, [rsp+24]
    call    rb_record
    test    rax, rax
    jnz     4b
41: movss   xmm0, [rip+rb_dt]
    mulss   xmm0, [rip+rx_half]
    addss   xmm0, [rip+rb_time]
    comiss  xmm0, [rsp+16]
    jae     5f
    call    rb_step
    movss   xmm0, [rip+rb_time]
    addss   xmm0, [rip+rb_dt]
    movss   [rip+rb_time], xmm0
    jmp     4b
5:  call    now_ms
    sub     rax, [rsp+8]
    cvtsi2ss xmm0, rax
    movss   [rip+rb_ms], xmm0
    movss   xmm0, [rsp]
    movss   [rip+rb_fnow], xmm0
    call    writeback
    mov     dword ptr [rip+dirty], 1
    jmp     .Lrf_out
.Lrf_gone:                              # no bodies: nothing cached
    xor     edi, edi
    call    sc_clear
.Lrf_none:                              # no simulation: objects as they began
    call    rb_free
    call    rb_restore
.Lrf_out:
    mov     dword ptr [rip+rb_busy], 0
.Lrf_ret:
    add     rsp, 56
    pop     r12
    pop     rbx
    ret

# rb_live(edi=1 on / 0 off) - play mode: the simulation runs live (no
#   cached frames played or kept: logic graphs push bodies); either way it
#   is made again from the start at the next frame
rb_live:
    mov     [rip+rb_islive], edi
    mov     qword ptr [rip+rb_hash], 0
    mov     dword ptr [rip+rb_npend], 0
    ret

# rb_pend_apply - the impulses waiting for the bodies
rb_pend_apply:
    push    rbx
    xor     ebx, ebx
1:  cmp     ebx, [rip+rb_npend]
    jae     9f
    mov     eax, ebx
    shl     eax, 5
    lea     rcx, [rip+rb_pend]
    mov     rdi, [rcx+rax]
    movaps  xmm0, [rcx+rax+16]
    call    rb_impulse_now
    inc     ebx
    jmp     1b
9:  mov     dword ptr [rip+rb_npend], 0
    pop     rbx
    ret

# rb_impulse(rdi=object, xmm0=impulse x y z) -> eax = 1 when it is a moving
#   body: its velocity changes by impulse / mass, and it wakes (before the
#   bodies are made: when they are)
rb_impulse:
    cmp     dword ptr [rip+rb_on], 0    # no bodies yet: when they are made
    jne     rb_impulse_now
    mov     eax, [rip+rb_npend]
    cmp     eax, 16
    jae     1f
    inc     dword ptr [rip+rb_npend]
    shl     eax, 5
    lea     rcx, [rip+rb_pend]
    mov     [rcx+rax], rdi
    movaps  [rcx+rax+16], xmm0
    mov     eax, 1
    ret
1:  xor     eax, eax
    ret
rb_impulse_now:
    xor     eax, eax
    cmp     dword ptr [rip+rb_on], 0
    je      9f
    xor     ecx, ecx
1:  cmp     ecx, [rip+rb_nb]
    jae     9f
    BODY    rdx, rcx
    cmp     [rdx+BD_OBJ], rdi
    jne     2f
    cmp     dword ptr [rdx+BD_TYPE], 1
    jne     9f
    movss   xmm1, [rdx+BD_IM]
    shufps  xmm1, xmm1, 0
    mulps   xmm1, xmm0
    andps   xmm1, [rip+rb_xyzmask]
    addps   xmm1, [rdx+BD_V]
    movaps  [rdx+BD_V], xmm1
    mov     dword ptr [rdx+BD_ASLEEP], 0
    mov     dword ptr [rdx+BD_SLEEP], 0
    mov     eax, 1
    ret
2:  inc     ecx
    jmp     1b
9:  ret

.section .rodata
.align 16
rb_xyzmask:     .long -1, -1, -1, 0
.text

# body_pose(rdi=body, rsi=out: loc, rot) - its object's place: loc = P - R com,
#   the rotation as Euler angles
body_pose:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12
    and     rsp, -16
    sub     rsp, 128
    mov     rbx, rdi
    mov     r12, rsi
    movaps  xmm0, [rbx+BD_COM]
    MV3     xmm1, rbx+BD_R, xmm0, xmm2, xmm3
    movaps  xmm0, [rbx+BD_POS]
    subps   xmm0, xmm1                  # loc
    movaps  [rsp+64], xmm0
    xor     ecx, ecx                    # [R | loc]
1:  mov     eax, ecx
    shl     eax, 4
    movaps  xmm1, [rbx+BD_R+rax]
    movaps  [rsp+rax], xmm1
    movss   xmm1, [rsp+64+rcx*4]
    movss   [rsp+rax+12], xmm1
    inc     ecx
    cmp     ecx, 3
    jb      1b
    lea     rdi, [rsp+80-60]            # (pose_from_mat writes at +60)
    lea     rsi, [rsp]
    call    pose_from_mat
    mov     rax, [rsp+80]               # loc, rot (not the scale)
    mov     [r12], rax
    mov     rax, [rsp+88]
    mov     [r12+8], rax
    mov     rax, [rsp+96]
    mov     [r12+16], rax
    lea     rsp, [rbp-16]
    pop     r12
    pop     rbx
    pop     rbp
    ret

# writeback - each moving body's place into its object
writeback:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 32
    xor     r12d, r12d
1:  mov     eax, [rip+rb_nb]
    dec     eax
    cmp     r12d, eax
    jae     9f
    BODY    rbx, r12
    cmp     dword ptr [rbx+BD_TYPE], 1
    jne     2f
    mov     r13, [rbx+BD_OBJ]
    test    r13, r13
    jz      2f
    cmp     dword ptr [rbx+BD_INST], 0
    je      3f
    mov     rdi, rbx                    # an instance: its matrix
    call    inst_writeback
    jmp     2f
3:  mov     rdi, rbx
    lea     rsi, [rsp]
    call    body_pose
    mov     rax, [rsp]
    mov     [r13+OB_LOC], rax
    mov     eax, [rsp+8]
    mov     [r13+OB_LOC+8], eax
    mov     rax, [rsp+12]
    mov     [r13+OB_ROT], rax
    mov     eax, [rsp+20]
    mov     [r13+OB_ROT+8], eax
2:  inc     r12d
    jmp     1b
9:  call    rbi_touch
    add     rsp, 32
    pop     r13
    pop     r12
    pop     rbx
    ret

# rb_record(esi=frame) -> rax = 0 when not kept: the moving bodies' places
#   into the cache: the objects' count, the instances' count, then uid,
#   loc, rot for each object; uid, index, matrix (12 floats) each instance
rb_record:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r14d, esi
    xor     r12d, r12d                  # how many objects,
    xor     r15d, r15d                  #  instances
    xor     ecx, ecx
1:  mov     eax, [rip+rb_nb]
    dec     eax
    cmp     ecx, eax
    jae     2f
    BODY    rdx, rcx
    cmp     dword ptr [rdx+BD_TYPE], 1
    jne     11f
    cmp     qword ptr [rdx+BD_OBJ], 0
    je      11f
    cmp     dword ptr [rdx+BD_INST], 0
    je      12f
    inc     r15d
    jmp     11f
12: inc     r12d
11: inc     ecx
    jmp     1b
2:  imul    edx, r12d, 28
    imul    eax, r15d, 56
    add     edx, eax
    add     edx, 8
    xor     edi, edi
    mov     esi, r14d
    call    sc_add
    test    rax, rax
    jz      9f
    mov     r13, rax
    mov     [r13], r12d
    mov     [r13+4], r15d
    imul    r15d, r12d, 28              # (where the instances go)
    lea     r15, [r13+8+r15]
    add     r13, 8
    xor     r12d, r12d
3:  mov     eax, [rip+rb_nb]
    dec     eax
    cmp     r12d, eax
    jae     8f
    BODY    rbx, r12
    cmp     dword ptr [rbx+BD_TYPE], 1
    jne     4f
    mov     rax, [rbx+BD_OBJ]
    test    rax, rax
    jz      4f
    mov     eax, [rax+OB_UID]
    cmp     dword ptr [rbx+BD_INST], 0
    jne     5f
    mov     [r13], eax
    mov     rdi, rbx
    lea     rsi, [r13+4]
    call    body_pose
    add     r13, 28
    jmp     4f
5:  mov     [r15], eax                  # an instance: uid, index, matrix
    mov     eax, [rbx+BD_INST]
    dec     eax
    mov     [r15+4], eax
    mov     rdi, rbx
    lea     rsi, [r15+8]
    call    inst_matrix
    add     r15, 56
4:  inc     r12d
    jmp     3b
8:  mov     eax, 1
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# rb_play(rdi=record) - a cached frame's places into the objects (and
#   instances)
rb_play:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rbx, rdi
    mov     r12d, [rbx]
    mov     r14d, [rbx+4]
    add     rbx, 8
1:  test    r12d, r12d
    jz      3f
    mov     edi, [rbx]
    call    obj_by_uid
    test    rax, rax
    jz      2f
    mov     rcx, [rbx+4]
    mov     [rax+OB_LOC], rcx
    mov     ecx, [rbx+12]
    mov     [rax+OB_LOC+8], ecx
    mov     rcx, [rbx+16]
    mov     [rax+OB_ROT], rcx
    mov     ecx, [rbx+24]
    mov     [rax+OB_ROT+8], ecx
2:  add     rbx, 28
    dec     r12d
    jmp     1b
3:  test    r14d, r14d                  # instances: into their object's mesh
    jz      9f
    mov     edi, [rbx]
    call    obj_by_uid
    test    rax, rax
    jz      4f
    mov     rdi, rax
    call    rbi_make
    test    rax, rax
    jz      4f
    mov     rax, [rax+RBI_OUT]
    mov     rax, [rax+ME_INST]
    mov     ecx, [rbx+4]
    cmp     ecx, [rax+IB_N_]
    jae     4f
    imul    rcx, rcx, 48
    lea     rdi, [rax+IB_DATA_+rcx]
    lea     rsi, [rbx+8]
    mov     ecx, 48
    rep     movsb
4:  add     rbx, 56
    dec     r14d
    jmp     3b
9:  call    rbi_touch
    mov     dword ptr [rip+dirty], 1
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ---- instances as bodies ------------------------------------------------------
# rb_inst_mesh(rdi=object) -> rax = the mesh its moving instances are in, or
#   0 (obj_eval asks first)
rb_inst_mesh:
    xor     eax, eax
    cmp     dword ptr [rip+rb_noinst], 0
    jne     9f
    lea     rcx, [rip+rbi_tab]
    xor     edx, edx
1:  cmp     edx, [rip+rbi_n]
    jae     9f
    cmp     [rcx+RBI_OBJ], rdi
    je      2f
    add     rcx, RBI_SZ
    inc     edx
    jmp     1b
2:  mov     rax, [rcx+RBI_OUT]
9:  ret

# rbi_find(rdi=object) -> rax = its entry, or 0
rbi_find:
    lea     rax, [rip+rbi_tab]
    xor     edx, edx
1:  cmp     edx, [rip+rbi_n]
    jae     8f
    cmp     [rax+RBI_OBJ], rdi
    je      9f
    add     rax, RBI_SZ
    inc     edx
    jmp     1b
8:  xor     eax, eax
9:  ret

# rbi_make(rdi=object) -> rax = its entry (made when new: a copy of its
#   evaluated mesh with an instance block of its own), or 0
rbi_make:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    call    rbi_find
    test    rax, rax
    jnz     9f
    cmp     dword ptr [rip+rbi_n], RBI_MAX
    jae     8f
    mov     eax, [rip+rb_noinst]
    push    rax
    push    rax
    mov     dword ptr [rip+rb_noinst], 1
    mov     rdi, rbx
    call    obj_eval
    pop     rcx
    pop     rcx
    mov     [rip+rb_noinst], ecx
    test    rax, rax
    jz      8f
    cmp     qword ptr [rax+ME_INST], 0
    je      8f
    mov     r12, rax
    mov     rdi, rax
    call    mesh_copy
    test    rax, rax
    jz      8f
    mov     r13, rax
    mov     rdi, [r12+ME_INST]          # its own block (the same instances)
    lea     rsi, [rip+rx_ident]
    call    inst_xform
    test    rax, rax
    jz      7f
    mov     rdi, [r13+ME_INST]
    mov     [r13+ME_INST], rax
    call    inst_unref
    mov     eax, [rip+rbi_n]
    inc     dword ptr [rip+rbi_n]
    imul    rax, rax, RBI_SZ
    lea     r12, [rip+rbi_tab]
    add     r12, rax
    mov     [r12+RBI_OBJ], rbx
    mov     [r12+RBI_OUT], r13
    mov     rdi, rbx                    # the object's inverse matrix
    lea     rsi, [r12+RBI_WINV]
    call    m34_inv_obj
    mov     rax, r12
    jmp     9f
7:  mov     rdi, r13
    call    mesh_unref
8:  xor     eax, eax
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# rbi_drop - no moving instances (their objects show their meshes again)
rbi_drop:
    push    rbx
    push    r12
    sub     rsp, 8
    xor     ebx, ebx
    lea     r12, [rip+rbi_tab]
1:  cmp     ebx, [rip+rbi_n]
    jae     2f
    mov     rdi, [r12+RBI_OUT]
    call    mesh_unref
    add     r12, RBI_SZ
    inc     ebx
    jmp     1b
2:  cmp     dword ptr [rip+rbi_n], 0
    je      9f
    mov     dword ptr [rip+rbi_n], 0
    mov     dword ptr [rip+dirty], 1
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# rbi_touch - the moving instances' meshes changed (their version)
rbi_touch:
    lea     rax, [rip+rbi_tab]
    xor     edx, edx
1:  cmp     edx, [rip+rbi_n]
    jae     9f
    mov     rcx, [rax+RBI_OUT]
    inc     dword ptr [rcx+ME_VER]
    add     rax, RBI_SZ
    inc     edx
    jmp     1b
9:  ret

# inst_bodies(edi=first index, rsi=entry, rdx=object) -> eax = bodies made:
#   one per instance of the object's mesh, its prototype placed by the
#   object's matrix times the instance's (rotation and scale split: the
#   columns' lengths)
inst_bodies:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    and     rsp, -16
    sub     rsp, 240
    mov     [rsp], edi
    mov     [rsp+8], rsi
    mov     [rsp+16], rdx
    xor     r15d, r15d                  # made
    mov     rdi, rdx
    call    rbi_make
    test    rax, rax
    jz      9f
    mov     rbx, [rax+RBI_OUT]
    mov     rbx, [rbx+ME_INST]          # the block
    mov     rdi, [rsp+16]               # W
    lea     rsi, [rsp+32]
    call    obj_matrix
    xor     r12d, r12d
1:  cmp     r12d, [rbx+IB_N_]
    jae     9f
    imul    rdx, r12, 48                # C = W M
    lea     rdx, [rbx+IB_DATA_+rdx]
    lea     rsi, [rsp+32]
    lea     rdi, [rsp+80]
    call    inst_mul
    xor     ecx, ecx                    # columns' lengths: the scale
2:  movss   xmm0, [rsp+80+rcx*4]
    mulss   xmm0, xmm0
    movss   xmm1, [rsp+96+rcx*4]
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    movss   xmm1, [rsp+112+rcx*4]
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    maxss   xmm0, [rip+rx_tiny2]
    sqrtss  xmm0, xmm0
    movss   [rsp+192+rcx*4], xmm0       # scale (vec4 at +192)
    inc     ecx
    cmp     ecx, 3
    jb      2b
    mov     dword ptr [rsp+204], 0
    xor     ecx, ecx                    # rows (3 x vec4 at +128): C / scale,
3:  mov     eax, ecx                    #  loc (vec4 at +176)
    shl     eax, 4
    xor     edx, edx
31: imul    r8d, ecx, 16
    lea     r9d, [r8+rdx*4]
    movss   xmm0, [rsp+80+r9]
    divss   xmm0, [rsp+192+rdx*4]
    movss   [rsp+128+r9], xmm0
    inc     edx
    cmp     edx, 3
    jb      31b
    mov     dword ptr [rsp+128+rax+12], 0
    movss   xmm0, [rsp+80+rax+12]
    movss   [rsp+176+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      3b
    mov     dword ptr [rsp+188], 0
    mov     rdi, rbx                    # its prototype
    call    inst_pids
    movzx   eax, byte ptr [rax+r12]
    mov     rcx, [rbx+IB_PROTO_+rax*8]
    mov     edi, [rsp]
    add     edi, r15d
    mov     [rsp+24], edi
    mov     rsi, [rsp+8]
    mov     rdx, [rsp+16]
    lea     r8, [rsp+128]
    call    make_body_ex
    mov     eax, [rsp+24]
    BODY    rcx, rax
    lea     eax, [r12+1]
    mov     [rcx+BD_INST], eax
    inc     r15d
    inc     r12d
    jmp     1b
9:  mov     eax, r15d
    lea     rsp, [rbp-40]
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret

# inst_matrix(rdi=body, rsi=out 12 floats) - its instance's matrix:
#   W^-1 [R diag(s) | P - R com]
inst_matrix:
    push    rbx
    push    r12
    sub     rsp, 72
    mov     rbx, rdi
    mov     r12, rsi
    movaps  xmm0, [rbx+BD_COM]
    MV3     xmm1, rbx+BD_R, xmm0, xmm2, xmm3
    movaps  xmm0, [rbx+BD_POS]
    subps   xmm0, xmm1                  # loc
    movaps  [rsp+48], xmm0
    xor     ecx, ecx
1:  mov     eax, ecx
    shl     eax, 4
    movaps  xmm1, [rbx+BD_R+rax]        # row i of R, times the scale
    mulps   xmm1, [rbx+BD_SCL]
    movaps  [rsp+rax], xmm1
    movss   xmm1, [rsp+48+rcx*4]
    movss   [rsp+rax+12], xmm1
    inc     ecx
    cmp     ecx, 3
    jb      1b
    mov     rdi, [rbx+BD_OBJ]
    call    rbi_find
    test    rax, rax
    jz      9f
    lea     rsi, [rax+RBI_WINV]
    lea     rdx, [rsp]
    mov     rdi, r12
    call    inst_mul
9:  add     rsp, 72
    pop     r12
    pop     rbx
    ret

# m34_inv_obj(rdi=object, rsi=out 3x4) - the inverse of its matrix: the
#   adjugate over the determinant (its columns b x c, c x a, a x b of the
#   rows a, b, c); t' = -inv t
m34_inv_obj:
    push    rbx
    push    r12
    sub     rsp, 104
    mov     r12, rsi
    lea     rsi, [rsp]                  # the matrix (rows at +0)
    call    obj_matrix
    movaps  xmm0, [rsp]
    andps   xmm0, [rip+rx_xyz]
    movaps  xmm1, [rsp+16]
    andps   xmm1, [rip+rx_xyz]
    movaps  xmm2, [rsp+32]
    andps   xmm2, [rip+rx_xyz]
    CROSS   xmm3, xmm1, xmm2, xmm6      # b x c
    CROSS   xmm4, xmm2, xmm0, xmm6      # c x a
    CROSS   xmm5, xmm0, xmm1, xmm6      # a x b
    movaps  xmm6, xmm0                  # det = a . (b x c)
    DOT3    xmm6, xmm3
    movaps  xmm7, xmm6
    andps   xmm7, [rip+rx_abs]
    comiss  xmm7, [rip+rx_tiny]
    ja      1f
    movss   xmm6, [rip+rx_tiny]         # (singular)
1:  movss   xmm7, [rip+rx_one]
    divss   xmm7, xmm6
    shufps  xmm7, xmm7, 0
    mulps   xmm3, xmm7
    mulps   xmm4, xmm7
    mulps   xmm5, xmm7
    movaps  [rsp+48], xmm3              # the inverse's columns (+48)
    movaps  [rsp+64], xmm4
    movaps  [rsp+80], xmm5
    xor     ecx, ecx                    # out[i][j] = col_j[i]
2:  mov     eax, ecx
    shl     eax, 4                      # out row i
    movss   xmm0, [rsp+48+rcx*4]
    movss   [r12+rax], xmm0
    movss   xmm0, [rsp+64+rcx*4]
    movss   [r12+rax+4], xmm0
    movss   xmm0, [rsp+80+rcx*4]
    movss   [r12+rax+8], xmm0
    movss   xmm0, [r12+rax]             # t'_i = -(inv_i . t)
    mulss   xmm0, [rsp+12]
    movss   xmm1, [r12+rax+4]
    mulss   xmm1, [rsp+28]
    addss   xmm0, xmm1
    movss   xmm1, [r12+rax+8]
    mulss   xmm1, [rsp+44]
    addss   xmm0, xmm1
    xorps   xmm0, [rip+rx_sign]
    movss   [r12+rax+12], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      2b
    add     rsp, 104
    pop     r12
    pop     rbx
    ret

# inst_writeback(rdi=body) - its matrix into the moving mesh's block
inst_writeback:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    mov     rdi, [rbx+BD_OBJ]
    call    rbi_find
    test    rax, rax
    jz      9f
    mov     rax, [rax+RBI_OUT]
    mov     rax, [rax+ME_INST]
    mov     ecx, [rbx+BD_INST]
    dec     ecx
    imul    rcx, rcx, 48
    lea     rsi, [rax+IB_DATA_+rcx]
    mov     rdi, rbx
    call    inst_matrix
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# rb_capture - each body's start kept (RB_INIT) before its object moves
rb_capture:
    push    rbx
    push    r12
    push    r13
    mov     rbx, [rip+an_cur]
    xor     r12d, r12d
1:  cmp     r12d, [rbx+AN_NRB_]
    jae     9f
    imul    r13, r12, RB_SZ_
    lea     r13, [rbx+AN_RB_+r13]
    test    dword ptr [r13+RB_FLAGS], 1
    jnz     2f
    mov     rdi, r13
    call    rb_entry_obj
    test    rax, rax
    jz      2f
    lea     rsi, [rax+OB_LOC]
    lea     rdi, [r13+RB_INIT]
    mov     ecx, 36
    rep     movsb
    or      dword ptr [r13+RB_FLAGS], 1
2:  inc     r12d
    jmp     1b
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# rb_key -> rax: the settings, the frame range, each body's start and mesh
#   (what the cache belongs to)
rb_key:
    push    rbx
    push    r12
    push    r13
    mov     dword ptr [rip+rb_noinst], 1
    call    rb_sethash
    xor     rax, RB_CVER                # (the records' kind)
    mov     rbx, [rip+an_cur]
    lea     rdi, [rbx+AN_START]
    mov     esi, 12
    call    sc_mix
    xor     r12d, r12d
1:  cmp     r12d, [rbx+AN_NRB_]
    jae     9f
    push    rax
    imul    r13, r12, RB_SZ_
    lea     r13, [rbx+AN_RB_+r13]
    mov     rdi, r13
    call    rb_entry_obj
    mov     rdx, rax
    pop     rax
    test    rdx, rdx
    jz      2f
    push    rdx
    lea     rdi, [r13+RB_INIT]          # where it starts
    test    dword ptr [r13+RB_FLAGS], 1
    jnz     11f
    lea     rdi, [rdx+OB_LOC]
11: mov     esi, 36
    call    sc_mix
    pop     rdx
    test    dword ptr [r13+RB_FLAGS], 2
    jz      12f
    push    rax                         # instances: what makes them (the
    push    rdx                         #  evaluated mesh's instances)
    mov     rdi, rdx
    call    obj_eval
    mov     rcx, rax
    pop     rdx
    pop     rax
    test    rcx, rcx
    jz      12f
    mov     rcx, [rcx+ME_INST]
    test    rcx, rcx
    jz      12f
    push    rdx
    push    rcx
    imul    esi, dword ptr [rcx+IB_N_], 48
    lea     rdi, [rcx+IB_DATA_]
    call    sc_mix
    pop     rcx
    pop     rdx
12: mov     rdi, [rdx+OB_MESH]
    call    sc_meshhash
2:  inc     r12d
    jmp     1b
9:  mov     dword ptr [rip+rb_noinst], 0
    pop     r13
    pop     r12
    pop     rbx
    ret

# rb_info(edi=what) -> xmm0: 0 bodies, 1 contact points, 2 awake, 3 islands,
#   4 the last frame's simulation (ms), 5 manifolds, 6 steps, 7 parts
rb_info:
    xorps   xmm0, xmm0
    cmp     dword ptr [rip+rb_on], 0
    je      9f
    cmp     edi, 1000                   # 1000 + 4 i + c: contact point i's
    jb      .Lri_n                      #  place (c 0-2, on A), gap (3)
    sub     edi, 1000
    mov     r8d, edi
    shr     r8d, 2                      # i
    and     edi, 3
    xor     ecx, ecx
    mov     rdx, [rip+rb_mf]
.Lri_d1:
    cmp     ecx, [rip+rb_nmf]
    jae     9f
    cmp     r8d, [rdx+MF_N]
    jb      .Lri_d2
    sub     r8d, [rdx+MF_N]
    add     rdx, MF_SZ
    inc     ecx
    jmp     .Lri_d1
.Lri_d2:
    imul    r8, r8, CP_SZ
    lea     rdx, [rdx+MF_PTS+r8]
    cmp     edi, 3
    je      .Lri_d3
    movss   xmm0, [rdx+CP_WA+rdi*4]
    ret
.Lri_d3:
    movss   xmm0, [rdx+CP_SEP]
    ret
.Lri_n:
    cmp     edi, 0
    jne     1f
    mov     eax, [rip+rb_nb]
    dec     eax
    jmp     8f
1:  cmp     edi, 1
    jne     3f
    xor     eax, eax
    xor     ecx, ecx
    mov     rdx, [rip+rb_mf]
2:  cmp     ecx, [rip+rb_nmf]
    jae     8f
    add     eax, [rdx+MF_N]
    add     rdx, MF_SZ
    inc     ecx
    jmp     2b
3:  cmp     edi, 2
    jne     5f
    xor     eax, eax
    xor     ecx, ecx
4:  mov     edx, [rip+rb_nb]
    cmp     ecx, edx
    jae     8f
    BODY    rdx, rcx
    cmp     dword ptr [rdx+BD_TYPE], 1
    jne     41f
    cmp     dword ptr [rdx+BD_ASLEEP], 0
    jne     41f
    inc     eax
41: inc     ecx
    jmp     4b
5:  mov     eax, [rip+rb_nisl]
    cmp     edi, 3
    je      8f
    movss   xmm0, [rip+rb_ms]
    cmp     edi, 4
    je      9f
    mov     eax, [rip+rb_nmf]
    cmp     edi, 5
    je      8f
    mov     eax, [rip+rb_npt]
    cmp     edi, 7
    je      8f
    mov     eax, [rip+rb_mffull]
    cmp     edi, 14                     # 14: pairs that found no manifold
    je      8f
    mov     eax, [rip+rb_nbroken]
    cmp     edi, 15                     # 15: joints broken
    je      8f
    cmp     edi, 16                     # 16: every body's place, turn and
    je      6f                          #  speeds, hashed (24 bits: exact)
    cmp     edi, 8                      # 8-13: ms in the broad phase, the
    jb      7f                          #  narrow, islands, solving, the
    cmp     edi, 13                     #  hash, compacting
    ja      7f
    lea     rax, [rip+rb_tns]
    cvtsi2sd xmm0, qword ptr [rax+rdi*8-64]
    divsd   xmm0, [rip+rx_1e6d]
    cvtsd2ss xmm0, xmm0
    ret
7:  mov     eax, [rip+rb_stepno]
8:  cvtsi2ss xmm0, eax
9:  ret
6:  mov     eax, 0x811c9dc5             # (FNV-1a over the bytes)
    xor     ecx, ecx
61: cmp     ecx, [rip+rb_nb]
    jae     63f
    BODY    rdx, rcx
    mov     esi, 64
62: xor     al, [rdx]
    imul    eax, eax, 0x01000193
    inc     rdx
    dec     esi
    jnz     62b
    inc     ecx
    jmp     61b
63: mov     edx, eax
    shr     edx, 24
    xor     eax, edx
    and     eax, 0xffffff
    jmp     8b

# =============================================================================
#  Operators
# =============================================================================
OPERATOR op_rb_add,   "rigid.add",    "Add Rigid Body",    do_rb_add, flags=OPF_AI_SAFE|OPF_UNDO, doc="Make the selected objects rigid bodies (or change them): rigid.add [active|passive] [box|sphere|capsule|hull|compound] [instances|object] [mass m] [friction f] [bounce b] [damping d]. Active ones fall when the frame goes past the start; instances: each instance of the object's geometry (nodes) is a body of its own, shaped like its prototype", form=form_rigid
OPERATOR op_rb_rem,   "rigid.remove", "Remove Rigid Body", do_rb_rem, flags=OPF_AI_SAFE|OPF_UNDO, doc="The selected objects are no longer rigid bodies"
OPERATOR op_rb_joint, "rigid.joint",  "Add Joint",         do_rb_joint, flags=OPF_AI_SAFE|OPF_UNDO, doc="Tie two bodies (or one to the world): rigid.joint <fixed|hinge|point|slider> <object> <object|world> [pivot x y z] [axis x y z] [break force] [limits lo hi] [motor speed force] (pivot: the first object's place; axis: Y; hinge limits and motor speed in degrees)", form=form_rjoint
OPERATOR op_rb_world, "rigid.world",  "Physics World",     do_rb_world, flags=OPF_AI_SAFE|OPF_UNDO, doc="Physics settings: rigid.world [gravity x y z] [rate steps-a-second] [iterations n (a step, over its substeps)] [substeps n (1-64; 4)]"

.section .rodata
k_active:       .asciz "active"
k_velocity:     .asciz "velocity"
k_group:        .asciz "group"
k_collide:      .asciz "collide"
k_material:     .asciz "material"
pm_names:       .quad k_pm_def, k_pm_rubber, k_pm_ice, k_pm_wood, k_pm_metal, k_pm_stone, 0
k_pm_def:       .asciz "default"
k_pm_rubber:    .asciz "rubber"
k_pm_ice:       .asciz "ice"
k_pm_wood:      .asciz "wood"
k_pm_metal:     .asciz "metal"
k_pm_stone:     .asciz "stone"
.align 4
pm_vals:        .float 0.5, 0.0,  0.9, 0.8,  0.02, 0.05,  0.5, 0.3,  0.35, 0.15,  0.7, 0.1
s_rb_mffull:    .asciz "  rigid bodies: no room for more contacts - some bodies may pass through others"
k_instances:    .asciz "instances"
k_object:       .asciz "object"
k_passive:      .asciz "passive"
shape_names:    .quad k_box, k_sphere, k_capsule, k_hull, k_compound, k_mesh, k_plane, 0
k_box:          .asciz "box"
k_sphere:       .asciz "sphere"
k_capsule:      .asciz "capsule"
k_hull:         .asciz "hull"
k_compound:     .asciz "compound"
k_mesh:         .asciz "mesh"
k_plane:        .asciz "plane"
rb_keys:        .quad k_mass, k_friction, k_bounce, k_damping, 0
k_mass:         .asciz "mass"
k_friction:     .asciz "friction"
k_bounce:       .asciz "bounce"
k_damping:      .asciz "damping"
jt_names:       .quad k_dash, k_fixed, k_hinge, k_point, k_slider, 0
k_slider:       .asciz "slider"
k_break:        .asciz "break"
k_limits:       .asciz "limits"
k_motor:        .asciz "motor"
.align 4
rx_deg:         .float 0.017453292
k_dash:         .asciz "-"
k_fixed:        .asciz "fixed"
k_hinge:        .asciz "hinge"
k_point:        .asciz "point"
k_world:        .asciz "world"
k_pivot:        .asciz "pivot"
k_axis:         .asciz "axis"
k_gravity:      .asciz "gravity"
k_rate:         .asciz "rate"
k_iter:         .asciz "iterations"
k_substeps:     .asciz "substeps"
s_rb_bad:       .asciz "  rigid.add [active|passive] [box|sphere|capsule|hull|compound] [mass m] [friction f] [bounce b] [damping d] - not understood: "
s_rb_none:      .asciz "  select mesh objects to make rigid bodies"
s_rb_full:      .asciz "  no room for more rigid bodies / joints"
s_rb_added:     .asciz "  rigid bodies: "
s_jt_bad:       .asciz "  rigid.joint <fixed|hinge|point|slider> <object> <object|world> [pivot x y z] [axis x y z] [break force] [limits lo hi] [motor speed force] - not understood: "
s_rw_bad:       .asciz "  rigid.world [gravity x y z] [rate n] [iterations n] [substeps n] - not understood: "
.text

# rb_word_index(rdi=word, rsi=names) -> eax = its place or -1
rb_word_index:
    push    rbx
    push    r12
    push    r13
    mov     r12, rdi
    mov     r13, rsi
    xor     ebx, ebx
1:  mov     rsi, [r13+rbx*8]
    test    rsi, rsi
    jz      8f
    mov     rdi, r12
    call    str_eq
    test    eax, eax
    jnz     2f
    inc     ebx
    jmp     1b
2:  mov     eax, ebx
    jmp     9f
8:  mov     eax, -1
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# rb_num(rsi=text) -> xmm0, eax = 1 (0: none), rsi after
rb_num:
    push    rbx
    call    im_next_word
    mov     rbx, rsi
    test    eax, eax
    jz      8f
    lea     rsi, [rip+im_word]
    lea     rdx, [rsi+rax]
    call    parse_float
    mov     rsi, rbx
    pop     rbx
    ret
8:  xor     eax, eax
    mov     rsi, rbx
    pop     rbx
    ret

# rb_find(rbx=block, edi=uid) -> eax = its entry, or -1
rb_find:
    xor     eax, eax
1:  cmp     eax, [rbx+AN_NRB_]
    jae     8f
    imul    rcx, rax, RB_SZ_
    cmp     [rbx+AN_RB_+rcx], edi
    je      9f
    inc     eax
    jmp     1b
8:  mov     eax, -1
9:  ret

# rigid.add [active|passive] [shape] [key value ...]
do_rb_add:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 80                     # (+32 velocity, +44 group, +48 the
                                        #  groups it does not meet)
    mov     dword ptr [rsp], 1          # type
    mov     dword ptr [rsp+4], 0        # shape
    mov     eax, [rip+rx_one]
    mov     [rsp+8], eax                # mass
    mov     eax, [rip+rx_fric]
    mov     [rsp+12], eax               # friction
    mov     dword ptr [rsp+16], 0       # bounce
    mov     dword ptr [rsp+20], 0       # damping
    mov     dword ptr [rsp+24], 0       # (which were given: bits)
    mov     r12, [rip+op_arg]
1:  mov     rsi, r12
    call    im_next_word
    mov     r12, rsi
    test    eax, eax
    jz      5f
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_active]
    call    str_eq
    test    eax, eax
    jz      2f
    mov     dword ptr [rsp], 1
    or      dword ptr [rsp+24], 1
    jmp     1b
2:  lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_passive]
    call    str_eq
    test    eax, eax
    jz      3f
    mov     dword ptr [rsp], 2
    or      dword ptr [rsp+24], 1
    jmp     1b
3:  lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_instances]
    call    str_eq
    test    eax, eax
    jz      31f
    mov     dword ptr [rsp+28], 2       # its instances
    or      dword ptr [rsp+24], 64
    jmp     1b
31: lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_object]
    call    str_eq
    test    eax, eax
    jz      32f
    mov     dword ptr [rsp+28], 0       # the object itself
    or      dword ptr [rsp+24], 64
    jmp     1b
32: lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_velocity]
    call    str_eq
    test    eax, eax
    jz      33f
    mov     rsi, r12                    # velocity x y z
    lea     rdi, [rsp+32]
    call    rb_vec3
    mov     r12, rsi
    test    eax, eax
    jz      .Lra_bad
    or      dword ptr [rsp+24], 128
    jmp     1b
33: lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_group]
    call    str_eq
    test    eax, eax
    jz      34f
    mov     rsi, r12                    # group n (0-15)
    call    rb_num
    mov     r12, rsi
    test    eax, eax
    jz      .Lra_bad
    cvttss2si eax, xmm0
    and     eax, 15
    mov     [rsp+44], eax
    or      dword ptr [rsp+24], 256
    jmp     1b
34: lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_collide]
    call    str_eq
    test    eax, eax
    jz      35f
    mov     rsi, r12                    # collide m: the groups it meets (bits)
    call    rb_num
    mov     r12, rsi
    test    eax, eax
    jz      .Lra_bad
    cvttss2si eax, xmm0
    not     eax
    and     eax, 0xffff
    mov     [rsp+20+28], eax
    or      dword ptr [rsp+24], 512
    jmp     1b
35: lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_material]
    call    str_eq
    test    eax, eax
    jz      36f
    mov     rsi, r12                    # material <preset>: friction, bounce
    call    im_next_word
    mov     r12, rsi
    test    eax, eax
    jz      .Lra_bad
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+pm_names]
    call    rb_word_index
    test    eax, eax
    js      .Lra_bad
    lea     rcx, [rip+pm_vals]
    mov     edx, [rcx+rax*8]
    mov     [rsp+12], edx               # friction
    mov     edx, [rcx+rax*8+4]
    mov     [rsp+16], edx               # bounce
    or      dword ptr [rsp+24], 8|16
    jmp     1b
36: lea     rdi, [rip+im_word]
    lea     rsi, [rip+shape_names]
    call    rb_word_index
    test    eax, eax
    js      4f
    mov     [rsp+4], eax
    or      dword ptr [rsp+24], 2
    jmp     1b
4:  lea     rdi, [rip+im_word]
    lea     rsi, [rip+rb_keys]
    call    rb_word_index
    test    eax, eax
    js      .Lra_bad
    mov     r13d, eax
    mov     rsi, r12
    call    rb_num
    mov     r12, rsi
    test    eax, eax
    jz      .Lra_bad
    xorps   xmm1, xmm1
    maxss   xmm0, xmm1
    movss   [rsp+8+r13*4], xmm0
    mov     ecx, r13d
    add     ecx, 2
    bts     dword ptr [rsp+24], ecx
    jmp     1b
5:  xor     edi, edi                    # each selected mesh object
    call    an_own_g
    test    rax, rax
    jz      .Lra_full
    mov     rbx, rax
    xor     r14d, r14d                  # done
    xor     r15d, r15d
6:  cmp     r15d, [rip+obj_count]
    jae     7f
    mov     edi, r15d
    call    obj_at
    test    dword ptr [rax+OB_FLAGS], OBF_SELECTED
    jz      61f
    cmp     dword ptr [rax+OB_TYPE], OT_MESH
    jne     61f
    mov     r13, rax
    mov     edi, [r13+OB_UID]
    call    rb_find
    test    eax, eax
    jns     62f
    mov     eax, [rbx+AN_NRB_]          # a new entry: the defaults
    cmp     eax, RB_MAX_
    jae     .Lra_full
    inc     dword ptr [rbx+AN_NRB_]
    imul    rcx, rax, RB_SZ_
    lea     rdi, [rbx+AN_RB_+rcx]
    push    rax
    push    rax
    xor     eax, eax
    mov     ecx, RB_SZ_
    rep     stosb
    pop     rax
    pop     rax
    imul    rcx, rax, RB_SZ_
    lea     rdi, [rbx+AN_RB_+rcx]
    mov     edx, [r13+OB_UID]
    mov     [rdi+RB_UID], edx
    mov     dword ptr [rdi+RB_TYPE], 1
    mov     edx, [rip+rx_one]
    mov     [rdi+RB_MASS], edx
    mov     edx, [rip+rx_fric]
    mov     [rdi+RB_FRIC], edx
62: imul    rcx, rax, RB_SZ_            # what was given
    lea     rdi, [rbx+AN_RB_+rcx]
    mov     edx, [rsp+24]
    test    edx, 1
    jz      63f
    mov     ecx, [rsp]
    mov     [rdi+RB_TYPE], ecx
63: test    edx, 2
    jz      64f
    mov     ecx, [rsp+4]
    mov     [rdi+RB_SHAPE], ecx
64: xor     ecx, ecx
65: lea     r8d, [rcx+2]
    bt      edx, r8d
    jnc     66f
    mov     r8d, [rsp+8+rcx*4]
    mov     [rdi+RB_MASS+rcx*4], r8d
66: inc     ecx
    cmp     ecx, 4
    jb      65b
    test    edx, 64
    jz      67f
    and     dword ptr [rdi+RB_FLAGS], ~2
    mov     ecx, [rsp+28]
    or      [rdi+RB_FLAGS], ecx
67: test    edx, 128                    # velocity
    jz      68f
    mov     rcx, [rsp+32]
    mov     [rdi+RB_VEL], rcx
    mov     ecx, [rsp+40]
    mov     [rdi+RB_VEL+8], ecx
68: test    edx, 256                    # group
    jz      69f
    and     dword ptr [rdi+RB_FLAGS], ~(15 << RBF_GRP)
    mov     ecx, [rsp+44]
    shl     ecx, RBF_GRP
    or      [rdi+RB_FLAGS], ecx
69: test    edx, 512                    # the groups it meets
    jz      70f
    and     dword ptr [rdi+RB_FLAGS], 0xffff
    mov     ecx, [rsp+48]
    shl     ecx, RBF_IGN
    or      [rdi+RB_FLAGS], ecx
70: and     dword ptr [rdi+RB_FLAGS], ~1  # (its start: from where it is)
    inc     r14d
61: inc     r15d
    jmp     6b
7:  test    r14d, r14d
    jz      .Lra_none
    call    fmt_reset
    lea     rdi, [rip+s_rb_added]
    call    fmt_str
    mov     edi, [rbx+AN_NRB_]
    call    fmt_int
    lea     rdi, [rip+fmt_buf]
    call    log_line
    jmp     .Lra_out
.Lra_none:
    lea     rdi, [rip+s_rb_none]
    call    log_line
    call    undo_drop_last
    jmp     .Lra_out
.Lra_full:
    lea     rdi, [rip+s_rb_full]
    call    log_line
    call    undo_drop_last
    jmp     .Lra_out
.Lra_bad:
    lea     rdi, [rip+s_rb_bad]
    lea     rsi, [rip+im_word]
    call    log_pair
    call    undo_drop_last
.Lra_out:
    add     rsp, 80
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# rigid.remove - the selected objects' entries (and their joints) go
do_rb_rem:
    push    rbx
    push    r12
    push    r13
    xor     edi, edi
    call    an_own_g
    test    rax, rax
    jz      9f
    mov     rbx, rax
    call    rb_free                     # (back to the start first)
    call    rb_restore
    xor     r12d, r12d
1:  cmp     r12d, [rip+obj_count]
    jae     9f
    mov     edi, r12d
    call    obj_at
    test    dword ptr [rax+OB_FLAGS], OBF_SELECTED
    jz      5f
    mov     r13d, [rax+OB_UID]
    mov     edi, r13d
    call    rb_find
    test    eax, eax
    js      3f
    imul    rdi, rax, RB_SZ_            # the entry: the last into its place
    lea     rdi, [rbx+AN_RB_+rdi]
    mov     ecx, [rbx+AN_NRB_]
    dec     ecx
    mov     [rbx+AN_NRB_], ecx
    imul    rsi, rcx, RB_SZ_
    lea     rsi, [rbx+AN_RB_+rsi]
    mov     ecx, RB_SZ_
    rep     movsb
3:  xor     ecx, ecx                    # its joints
4:  cmp     ecx, [rbx+AN_NJT_]
    jae     5f
    imul    rdi, rcx, JT_SZ_
    lea     rdi, [rbx+AN_JT_+rdi]
    cmp     [rdi+JT_A], r13d
    je      41f
    cmp     [rdi+JT_B], r13d
    jne     42f
41: mov     eax, [rbx+AN_NJT_]
    dec     eax
    mov     [rbx+AN_NJT_], eax
    imul    rsi, rax, JT_SZ_
    lea     rsi, [rbx+AN_JT_+rsi]
    push    rcx
    push    rcx
    mov     ecx, JT_SZ_
    rep     movsb
    pop     rcx
    pop     rcx
    jmp     4b
42: inc     ecx
    jmp     4b
5:  inc     r12d
    jmp     1b
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# rb_vec3(rsi=text, rdi=out 3 floats) -> eax = 1, rsi after
rb_vec3:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     r12, rdi
    xor     ebx, ebx
1:  call    rb_num
    test    eax, eax
    jz      9f
    movss   [r12+rbx*4], xmm0
    inc     ebx
    cmp     ebx, 3
    jb      1b
    mov     eax, 1
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# rigid.joint <type> <a> <b|world> [pivot x y z] [axis x y z]
do_rb_joint:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 72
    lea     rdi, [rsp]                  # the record
    xor     eax, eax
    mov     ecx, JT_SZ_
    rep     stosb
    mov     eax, [rip+rx_one]
    mov     [rsp+JT_AXIS+4], eax
    mov     rsi, [rip+op_arg]
    call    im_next_word
    mov     r12, rsi
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+jt_names]
    call    rb_word_index
    test    eax, eax
    jle     .Lrj_bad
    mov     [rsp+JT_TYPE], eax
    mov     rsi, r12
    call    im_next_word
    mov     r12, rsi
    lea     rdi, [rip+im_word]
    call    obj_find
    test    eax, eax
    jz      .Lrj_bad
    mov     edi, eax
    call    obj_get
    mov     r13, rax
    mov     eax, [r13+OB_UID]
    mov     [rsp+JT_A], eax
    mov     rax, [r13+OB_LOC]           # pivot: A's place
    mov     [rsp+JT_PIV], rax
    mov     eax, [r13+OB_LOC+8]
    mov     [rsp+JT_PIV+8], eax
    mov     rsi, r12
    call    im_next_word
    mov     r12, rsi
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_world]
    call    str_eq
    test    eax, eax
    jnz     1f
    lea     rdi, [rip+im_word]
    call    obj_find
    test    eax, eax
    jz      .Lrj_bad
    mov     edi, eax
    call    obj_get
    mov     eax, [rax+OB_UID]
    cmp     eax, [rsp+JT_A]
    je      .Lrj_bad
    mov     [rsp+JT_B], eax
1:  mov     rsi, r12                    # options
    call    im_next_word
    mov     r12, rsi
    test    eax, eax
    jz      3f
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_pivot]
    call    str_eq
    lea     rdi, [rsp+JT_PIV]
    test    eax, eax
    jnz     2f
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_axis]
    call    str_eq
    test    eax, eax
    jnz     21f
    lea     rdi, [rip+im_word]          # break <force>
    lea     rsi, [rip+k_break]
    call    str_eq
    test    eax, eax
    jz      22f
    mov     rsi, r12
    call    rb_num
    mov     r12, rsi
    test    eax, eax
    jz      .Lrj_bad
    movss   [rsp+JT_BRK], xmm0
    jmp     1b
22: lea     rdi, [rip+im_word]          # limits <lo> <hi> (hinge: degrees;
    lea     rsi, [rip+k_limits]         #  slider: m)
    call    str_eq
    test    eax, eax
    jz      23f
    lea     r14, [rsp+JT_LO]
    or      dword ptr [rsp+JT_FLG], 1
    jmp     24f
23: lea     rdi, [rip+im_word]          # motor <speed> <force> (hinge:
    lea     rsi, [rip+k_motor]          #  degrees / s, torque; slider: m/s,
    call    str_eq                      #  force)
    test    eax, eax
    jz      .Lrj_bad
    lea     r14, [rsp+JT_MSPD]
    or      dword ptr [rsp+JT_FLG], 2
24: mov     rsi, r12
    call    rb_num
    mov     r12, rsi
    test    eax, eax
    jz      .Lrj_bad
    cmp     dword ptr [rsp+JT_TYPE], 2  # (a hinge's in degrees)
    jne     25f
    mulss   xmm0, [rip+rx_deg]
25: movss   [r14], xmm0
    mov     rsi, r12
    call    rb_num
    mov     r12, rsi
    test    eax, eax
    jz      .Lrj_bad
    lea     rax, [rsp+JT_LO]            # (a limit's second: an angle too; a
    cmp     r14, rax                    #  motor's force: as it is)
    jne     26f
    cmp     dword ptr [rsp+JT_TYPE], 2
    jne     26f
    mulss   xmm0, [rip+rx_deg]
26: movss   [r14+4], xmm0
    jmp     1b
21: lea     rdi, [rsp+JT_AXIS]
2:  mov     rsi, r12
    call    rb_vec3
    mov     r12, rsi
    test    eax, eax
    jz      .Lrj_bad
    jmp     1b
3:  xor     edi, edi
    call    an_own_g
    test    rax, rax
    jz      .Lrj_full
    mov     rbx, rax
    mov     eax, [rbx+AN_NJT_]
    cmp     eax, JT_MAX_
    jae     .Lrj_full
    inc     dword ptr [rbx+AN_NJT_]
    imul    rdi, rax, JT_SZ_
    lea     rdi, [rbx+AN_JT_+rdi]
    lea     rsi, [rsp]
    mov     ecx, JT_SZ_
    rep     movsb
    jmp     .Lrj_out
.Lrj_full:
    lea     rdi, [rip+s_rb_full]
    call    log_line
    call    undo_drop_last
    jmp     .Lrj_out
.Lrj_bad:
    lea     rdi, [rip+s_jt_bad]
    lea     rsi, [rip+im_word]
    call    log_pair
    call    undo_drop_last
.Lrj_out:
    add     rsp, 72
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# rigid.world [gravity x y z] [rate n] [iterations n] [substeps n]
do_rb_world:
    push    rbx
    push    r12
    sub     rsp, 8
    xor     edi, edi
    call    an_own_g
    test    rax, rax
    jz      9f
    lea     rbx, [rax+AN_RW_]
    mov     r12, [rip+op_arg]
1:  mov     rsi, r12
    call    im_next_word
    mov     r12, rsi
    test    eax, eax
    jz      9f
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_gravity]
    call    str_eq
    test    eax, eax
    jz      2f
    mov     rsi, r12
    lea     rdi, [rbx+RW_GRAV]
    call    rb_vec3
    mov     r12, rsi
    test    eax, eax
    jz      8f
    mov     dword ptr [rbx+RW_SET], 1
    jmp     1b
2:  lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_rate]
    call    str_eq
    mov     r8d, RW_RATE
    test    eax, eax
    jnz     3f
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_iter]
    call    str_eq
    mov     r8d, RW_ITER
    test    eax, eax
    jnz     3f
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_substeps]
    call    str_eq
    mov     r8d, RW_SUB
    test    eax, eax
    jz      8f
3:  push    r8
    push    r8
    mov     rsi, r12
    call    rb_num
    mov     r12, rsi
    pop     r8
    pop     r8
    test    eax, eax
    jz      8f
    cvttss2si eax, xmm0
    cmp     eax, 1
    jge     4f
    mov     eax, 1
4:  mov     ecx, 1000
    cmp     r8d, RW_SUB
    jne     41f
    mov     ecx, 64
41: cmp     eax, ecx
    jle     5f
    mov     eax, ecx
5:  mov     [rbx+r8], eax
    jmp     1b
8:  lea     rdi, [rip+s_rw_bad]
    lea     rsi, [rip+im_word]
    call    log_pair
    call    undo_drop_last
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

.section .note.GNU-stack,"",@progbits
