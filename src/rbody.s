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
#  bodies only) solved in parallel: sequential impulses with warm starting,
#  friction, restitution, speculative contacts and Baumgarte correction,
#  then integration. An island at rest for half a second sleeps until
#  something awake touches it.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

.globl rb_frame
.globl rb_gravity
.globl rb_info
.globl rb_reset

# the settings (anim block)
.equ RW_GRAV,   0                       # gravity (3 floats; all 0: -9.81 Y)
.equ RW_RATE,   12                      # steps a second (0: 120)
.equ RW_ITER,   16                      # solver iterations (0: 10)
.equ RW_SET,    20                      # gravity was set
.equ RB_UID,    0
.equ RB_TYPE,   4                       # 1 active, 2 passive
.equ RB_SHAPE,  8                       # 0 box 1 sphere 2 capsule 3 hull 4 compound
.equ RB_MASS,   12
.equ RB_FRIC,   16
.equ RB_REST,   20
.equ RB_DAMP,   24
.equ RB_FLAGS,  28                      # bit 0: RB_INIT holds the start
.equ RB_INIT,   32                      # loc rot scale at the start (9 floats)
.equ JT_TYPE,   0                       # 1 fixed, 2 hinge, 3 point
.equ JT_A,      4                       # object uids (B 0: the world)
.equ JT_B,      8
.equ JT_PIV,    16                      # the pivot (world, at the start)
.equ JT_AXIS,   28                      # hinge: its axis (world)
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
.equ BD_SZ,     288
# a part (collide.s)
.equ PT_TYPE,   0
.equ PT_NV,     4
.equ PT_VERTS,  8
.equ PT_RAD,    16
.equ PT_BODY,   20
.equ PT_HALF,   32
.equ PT_OFF,    48
.equ PT_SZ,     64
.equ PT_MAXB,   16                      # parts a body
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
.equ MF_PTS,    80
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
.equ CP_SZ,     112
.equ MF_SZ,     MF_PTS + 4*CP_SZ
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
.equ JR_SZ,     192
.equ MARGIN,    0                       # (as floats in rodata)
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
rx_xy:          .long -1, -1, 0, 0
rx_yz:          .long 0, -1, -1, 0
rx_tiny4:       .float 1e-9, 1e-9, 1e-9, 1
rx_ident:       .float 1, 0, 0, 0,  0, 1, 0, 0,  0, 0, 1, 0
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
rx_small:       .float 1.0e-6
rx_margin:      .float 0.02                 # contacts begin this far apart
rx_keep:        .float 0.04                 # points kept this far apart,
rx_drift2:      .float 0.0004               #  sliding less than 2 cm
rx_same2:       .float 0.0004               # a new point this near an old one
rx_slop:        .float 0.005
rx_pushmax:     .float 1.0
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
rx_1000:        .float 1000.0
rx_24:          .float 24.0
rx_conc:        .float 0.05                 # compound: a part's hollowness / size
rx_0577:        .float 0.57735

.section .bss
.align 16
rb_on:          .skip 4                 # a simulation exists
rb_nb:          .skip 4                 # bodies (the world last)
rb_npt:         .skip 4
rb_nvx:         .skip 4
rb_nmf:         .skip 4
rb_capmf:       .skip 4
rb_npr:         .skip 4
rb_njr:         .skip 4
rb_nisl:        .skip 4
rb_hmask:       .skip 4
rb_stepno:      .skip 4
rb_iter:        .skip 4
rb_base:        .skip 8                 # the mapping, its size
rb_bytes:       .skip 8
rb_bd:          .skip 8
rb_pt:          .skip 8
rb_vx:          .skip 8
rb_mf:          .skip 8
rb_pr:          .skip 8
rb_hs:          .skip 8
rb_ord:         .skip 8
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
rb_ms:          .skip 4                 # the last frame's simulation time
rb_busy:        .skip 4
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
    movaps  xmm0, [r13+PT_OFF]          # centre = P + R off
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
2:  movaps  [rbx+BD_MIN], xmm6
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
    mov     rbx, [rip+an_cur]
    xor     r12d, r12d                  # bodies, the largest mesh
    xor     r13d, r13d
    xor     r14d, r14d                  # (its vertices, triangles)
1:  cmp     r12d, [rbx+AN_NRB_]
    jae     2f
    imul    rdi, r12, RB_SZ_
    lea     rdi, [rbx+AN_RB_+rdi]
    call    rb_entry_obj
    test    rax, rax
    jz      11f
    inc     r13d
    mov     rdi, rax
    call    obj_eval
    test    rax, rax
    jz      11f
    mov     ecx, [rax+ME_NVERTS]
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
    call    rb_lay
    lea     rdi, [rip+rb_vx]            # hulls, then scratch for a mesh
    imul    rsi, r15, PT_MAXB*HULL_MAX*16
    mov     eax, [rsp+8]
    imul    rax, rax, 48
    add     rsi, rax
    mov     eax, [rsp]
    imul    rax, rax, 16
    add     rsi, rax
    add     rsi, 65536
    call    rb_lay
    imul    eax, r15d, 16               # manifolds
    add     eax, 4096
    mov     [rip+rb_capmf], eax
    lea     rdi, [rip+rb_mf]
    imul    rsi, rax, MF_SZ
    call    rb_lay
    lea     rdi, [rip+rb_pr]
    mov     esi, [rip+rb_capmf]
    shl     rsi, 3
    call    rb_lay
    mov     eax, [rip+rb_capmf]         # the hash: a power of two >= 4 x
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
    mov     [rip+rb_npt], eax
    mov     [rip+rb_nvx], eax
    mov     [rip+rb_nmf], eax
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
43: mov     edi, r13d
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
    test    rax, rax
    jz      2f
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
    mov     [rip+rb_iter], edx
    cvtsi2ss xmm0, ecx
    movss   xmm1, [rip+rx_one]
    divss   xmm1, xmm0
    movss   [rip+rb_dt], xmm1
    ret

# make_body(edi=index, rsi=entry, rdx=object)
make_body:
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
    mov     [rbx+BD_OBJ], r13
    mov     ecx, [r12+RB_TYPE]
    mov     [rbx+BD_TYPE], ecx
    mov     eax, [rip+rb_npt]
    mov     [rbx+BD_P0], eax
    # rotation: from the Euler angles (scale 1)
    xorps   xmm0, xmm0
    movups  [rsp], xmm0                 # loc 0
    movups  xmm0, [r13+OB_ROT]
    movups  [rsp+12], xmm0              # rot
    mov     eax, [rip+rx_one]
    mov     [rsp+24], eax
    mov     [rsp+28], eax
    mov     [rsp+32], eax
    lea     rdi, [rsp-OB_LOC]
    lea     rsi, [rsp+48]
    call    obj_matrix
    lea     rdi, [rsp+48]
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
    mov     rdi, r13
    call    obj_eval
    mov     r14, rax
    movups  xmm0, [r14+ME_BMIN]
    movups  xmm1, [r14+ME_BMAX]
    movups  xmm2, [r13+OB_SCALE]
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
    cmp     eax, 3
    jae     .Lmb_hull
    # box / sphere / capsule: one part
    call    new_part
    mov     r15, rax
    movaps  xmm1, [rsp+112]
    cmp     dword ptr [r12+RB_SHAPE], 0
    jne     2f
    cmp     dword ptr [r12+RB_TYPE], 2  # a thin passive box: deep below
    jne     1f
    xor     ecx, ecx
11: movss   xmm0, [rsp+112+rcx*4]
    comiss  xmm0, [rip+rx_thin]
    jae     12f
    movss   xmm3, [rip+rx_thick]
    movss   [rsp+112+rcx*4], xmm3
    subss   xmm3, xmm0
    movss   xmm4, [rsp+96+rcx*4]
    subss   xmm4, xmm3
    movss   [rsp+96+rcx*4], xmm4
12: inc     ecx
    cmp     ecx, 3
    jb      11b
    movaps  xmm1, [rsp+112]
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
    cmp     dword ptr [r12+RB_SHAPE], 4
    je      .Lmb_comp
    mov     rdi, rax
    mov     esi, ecx
    xorps   xmm0, xmm0
    call    hull_part
    jmp     .Lmb_mass
.Lmb_comp:
    mov     [rip+dc_body], rbx
    mov     rdi, r14
    mov     rsi, rax
    call    decompose
.Lmb_mass:
    mov     eax, [rip+rb_npt]
    sub     eax, [rbx+BD_P0]
    mov     [rbx+BD_NP], eax
    movaps  xmm0, [rsp+96]              # the centre of mass: the bounds' centre
    movaps  [rbx+BD_COM], xmm0
    MV3     xmm1, rbx+BD_R, xmm0, xmm2, xmm3    # pos = loc + R com
    movups  xmm2, [r13+OB_LOC]
    andps   xmm2, [rip+rx_xyz]
    addps   xmm1, xmm2
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
    lea     rsp, [rbp-40]
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret

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
    call    hash_all                    # the manifolds into the hash
    call    broad                       # pairs of parts: manifolds kept / made
    call    compact                     # the rest go
    lea     rdi, [rip+narrow_job]       # contacts, in parallel
    xor     esi, esi
    mov     edx, [rip+rb_nmf]
    mov     ecx, 16
    test    edx, edx
    jz      1f
    call    parallel_for
1:  call    islands
    lea     rdi, [rip+island_job]       # each island solved, in parallel
    xor     esi, esi
    mov     edx, [rip+rb_nisl]
    mov     ecx, 1
    test    edx, edx
    jz      2f
    call    parallel_for
2:  add     rsp, 16
    pop     rbx
    ret

# mf_hash(edi=part a, esi=part b) -> eax = the slot to start at
mf_hash:
    imul    eax, edi, 73856093
    imul    ecx, esi, 19349663
    xor     eax, ecx
    and     eax, [rip+rb_hmask]
    ret

# hash_all - the hash cleared, then every manifold in it
hash_all:
    push    rbx
    mov     rdi, [rip+rb_hs]
    mov     ecx, [rip+rb_hmask]
    inc     ecx
    xor     eax, eax
    rep     stosd
    xor     ebx, ebx
1:  cmp     ebx, [rip+rb_nmf]
    jae     9f
    imul    rdx, rbx, MF_SZ
    add     rdx, [rip+rb_mf]
    mov     edi, [rdx+MF_PA]
    mov     esi, [rdx+MF_PB]
    call    mf_hash
    mov     rcx, [rip+rb_hs]
2:  cmp     dword ptr [rcx+rax*4], 0
    je      3f
    inc     eax
    and     eax, [rip+rb_hmask]
    jmp     2b
3:  lea     edx, [rbx+1]
    mov     [rcx+rax*4], edx
    inc     ebx
    jmp     1b
9:  pop     rbx
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
    imul    rbx, rdx, MF_SZ
    add     rbx, [rip+rb_mf]
    cmp     [rbx+MF_PA], r14d
    jne     2f
    cmp     [rbx+MF_PB], r15d
    jne     2f
    mov     edx, [rip+rb_stepno]
    mov     [rbx+MF_KEEP], edx
    jmp     9f
2:  inc     eax
    and     eax, [rip+rb_hmask]
    jmp     1b
3:  mov     edx, [rip+rb_nmf]           # a new one
    cmp     edx, [rip+rb_capmf]
    jae     9f
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
    mov     edx, [rip+rb_stepno]
    mov     [rbx+MF_KEEP], edx
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

# broad - sweep and prune along X: the order sorted (insertion: it barely
#   changes), overlapping bounds paired, their parts' bounds tested
broad:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    mov     r12, [rip+rb_ord]
    mov     r13, [rip+rb_bd]
    mov     ecx, 1                      # insertion sort by min x
1:  cmp     ecx, [rip+rb_nb]
    jae     3f
    mov     eax, [r12+rcx*4]
    imul    rdx, rax, BD_SZ
    movss   xmm0, [r13+rdx+BD_MIN]
    mov     edx, ecx
2:  test    edx, edx
    jz      21f
    mov     r8d, [r12+rdx*4-4]
    imul    r9, r8, BD_SZ
    comiss  xmm0, [r13+r9+BD_MIN]
    jae     21f
    mov     [r12+rdx*4], r8d
    dec     edx
    jmp     2b
21: mov     [r12+rdx*4], eax
    inc     ecx
    jmp     1b
3:  xor     r14d, r14d                  # i
4:  cmp     r14d, [rip+rb_nb]
    jae     9f
    mov     eax, [r12+r14*4]
    BODY    rbx, rax
    lea     r15d, [r14+1]               # j: while min x(j) <= max x(i)
5:  cmp     r15d, [rip+rb_nb]
    jae     8f
    mov     eax, [r12+r15*4]
    BODY    rdi, rax
    movss   xmm0, [rdi+BD_MIN]
    comiss  xmm0, [rbx+BD_MAX]
    ja      8f
    movaps  xmm0, [rbx+BD_MIN]          # y z overlap
    cmpleps xmm0, [rdi+BD_MAX]
    movaps  xmm1, [rdi+BD_MIN]
    cmpleps xmm1, [rbx+BD_MAX]
    andps   xmm0, xmm1
    movmskps eax, xmm0
    and     eax, 6
    cmp     eax, 6
    jne     7f
    cmp     dword ptr [rbx+BD_TYPE], 1  # at least one moves
    je      51f
    cmp     dword ptr [rdi+BD_TYPE], 1
    jne     7f
51: cmp     dword ptr [rbx+BD_JOINT], 0 # jointed together: no contact
    je      52f
    cmp     dword ptr [rdi+BD_JOINT], 0
    je      52f
    mov     rsi, rdi
    mov     rdi, rbx
    call    jointed
    mov     rdi, rsi
    test    eax, eax
    jnz     7f
52: mov     rsi, rdi
    mov     rdi, rbx
    call    pair_parts
7:  inc     r15d
    jmp     5b
8:  inc     r14d
    jmp     4b
9:  add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
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
9:  lea     rsp, [rbp-40]
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret

# part_bounds(rdi=body, esi=part, rdx=out min, max)
part_bounds:
    imul    rsi, rsi, PT_SZ
    add     rsi, [rip+rb_pt]
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
    movaps  xmm3, xmm1
    subps   xmm3, xmm2
    movaps  [rdx], xmm3
    addps   xmm1, xmm2
    movaps  [rdx+16], xmm1
    ret

# compact - manifolds not seen this step go
compact:
    mov     rsi, [rip+rb_mf]
    mov     rdi, rsi
    mov     edx, [rip+rb_stepno]
    xor     ecx, ecx
    xor     r8d, r8d
1:  cmp     ecx, [rip+rb_nmf]
    jae     9f
    cmp     [rsi+MF_KEEP], edx
    jne     3f
    cmp     rsi, rdi
    je      2f
    push    rcx
    push    rsi
    push    rdi
    mov     ecx, MF_SZ/8
    rep     movsq
    pop     rdi
    pop     rsi
    pop     rcx
2:  add     rdi, MF_SZ
    inc     r8d
3:  add     rsi, MF_SZ
    inc     ecx
    jmp     1b
9:  mov     [rip+rb_nmf], r8d
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
.equ MU_SZ,     416
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
    comiss  xmm5, [rip+rx_keep]
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
    lea     rdi, [rsp+MU_PXA]
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
    lea     rdi, [rsp+MU_PXA]
    lea     rsi, [rsp+MU_PXB]
    lea     rdx, [rsp+MU_RES]
    call    collide
    movss   xmm0, [rsp+MU_RES+CR_SEP]
    comiss  xmm0, [rip+rx_margin]
    jbe     4f
    mov     dword ptr [rbx+MF_N], 0     # apart
    jmp     .Lmu_out
4:  movaps  xmm0, [rsp+MU_RES+CR_N]
    movaps  [rbx+MF_NRM], xmm0
    mov     rdi, rbx
    lea     rsi, [rsp+MU_RES]
    call    cp_add
    # polytopes with few points: tilt A a little four ways for more
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
    comiss  xmm0, [rip+rx_margin]
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
    comiss  xmm0, [rip+rx_margin]
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
9:  add     rsp, 16
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
    imul    rbx, r12, MF_SZ
    add     rbx, [rip+rb_mf]
    cmp     dword ptr [rbx+MF_N], 0
    je      31f
    mov     edi, [rbx+MF_A]
    mov     esi, [rbx+MF_B]
    call    uf_union
31: inc     r12d
    jmp     3b
4:  xor     r12d, r12d                  #  joints
41: cmp     r12d, [rip+rb_njr]
    jae     5f
    imul    rbx, r12, JR_SZ
    add     rbx, [rip+rb_jr]
    mov     edi, [rbx+JR_A]
    mov     esi, [rbx+JR_B]
    call    uf_union
    inc     r12d
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
    imul    rbx, r12, MF_SZ
    add     rbx, [rip+rb_mf]
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
    imul    rbx, r12, MF_SZ
    add     rbx, [rip+rb_mf]
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
# mf_island(rbx=manifold) -> eax = its island (-1: no points / none)
mf_island:
    mov     eax, -1
    cmp     dword ptr [rbx+MF_N], 0
    je      9f
    mov     edi, [rbx+MF_A]
    mov     esi, [rbx+MF_B]
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

# mf_prestep(rbx=manifold) - masses, bias (restitution), warm start
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
    movaps  xmm0, [rbx+MF_NRM]
    lea     rdi, [r15+CP_RA]
    lea     rsi, [r15+CP_RB]
    call    kmass
    movss   [r15+CP_MN], xmm0
    movaps  xmm0, [rbx+MF_T1]
    lea     rdi, [r15+CP_RA]
    lea     rsi, [r15+CP_RB]
    call    kmass
    movss   [r15+CP_MT1], xmm0
    movaps  xmm0, [rbx+MF_T2]
    lea     rdi, [r15+CP_RA]
    lea     rsi, [r15+CP_RB]
    call    kmass
    movss   [r15+CP_MT2], xmm0
    movss   xmm0, [r15+CP_SEP]          # bias: speculative, or push out
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    jbe     2f
    subss   xmm1, xmm0
    divss   xmm1, [rip+rb_dt]
    jmp     3f
2:  subss   xmm1, xmm0
    subss   xmm1, [rip+rx_slop]
    xorps   xmm2, xmm2
    maxss   xmm1, xmm2
    mulss   xmm1, [rip+rx_beta]
    divss   xmm1, [rip+rb_dt]
    minss   xmm1, [rip+rx_pushmax]      # (overlaps part at most this fast)
3:  movss   [rsp], xmm1
    lea     rdi, [r15+CP_RA]            # restitution when they meet fast
    lea     rsi, [r15+CP_RB]
    call    relvel
    DOT3    xmm0, [rbx+MF_NRM]
    movss   xmm1, [rip+rx_bounce]
    xorps   xmm1, [rip+rx_sign]
    comiss  xmm0, xmm1
    jae     4f
    mulss   xmm0, [rbx+MF_REST]
    xorps   xmm0, [rip+rx_sign]
    maxss   xmm0, [rsp]
    movss   [rsp], xmm0
4:  movss   xmm0, [rsp]
    movss   [r15+CP_BIAS], xmm0
    movss   xmm0, [r15+CP_JN]           # warm start
    shufps  xmm0, xmm0, 0
    mulps   xmm0, [rbx+MF_NRM]
    movss   xmm1, [r15+CP_JT1]
    shufps  xmm1, xmm1, 0
    mulps   xmm1, [rbx+MF_T1]
    addps   xmm0, xmm1
    movss   xmm1, [r15+CP_JT2]
    shufps  xmm1, xmm1, 0
    mulps   xmm1, [rbx+MF_T2]
    addps   xmm0, xmm1
    lea     rdi, [r15+CP_RA]
    lea     rsi, [r15+CP_RB]
    call    impulse
    inc     r14d
    jmp     1b
9:  add     rsp, 8
    pop     r15
    pop     r14
    ret

# mf_solve(rbx=manifold) - friction (within mu x the normal impulse), then
#   the normal (never pulling)
mf_solve:
    push    r14
    push    r15
    sub     rsp, 8
    MFB
    xor     r14d, r14d
1:  cmp     r14d, [rbx+MF_N]
    jae     9f
    imul    r15, r14, CP_SZ
    lea     r15, [rbx+MF_PTS+r15]
    movss   xmm0, [r15+CP_JN]           # the friction's limit
    mulss   xmm0, [rbx+MF_FRIC]
    movss   [rsp], xmm0
    mov     edx, MF_T1
    mov     ecx, CP_JT1
    mov     r8d, CP_MT1
    call    fr_row
    mov     edx, MF_T2
    mov     ecx, CP_JT2
    mov     r8d, CP_MT2
    call    fr_row
    lea     rdi, [r15+CP_RA]            # normal
    lea     rsi, [r15+CP_RB]
    call    relvel
    DOT3    xmm0, [rbx+MF_NRM]
    movss   xmm1, [r15+CP_BIAS]
    subss   xmm1, xmm0
    mulss   xmm1, [r15+CP_MN]
    movss   xmm2, [r15+CP_JN]
    addss   xmm1, xmm2
    xorps   xmm3, xmm3
    maxss   xmm1, xmm3
    movss   [r15+CP_JN], xmm1
    subss   xmm1, xmm2
    shufps  xmm1, xmm1, 0
    mulps   xmm1, [rbx+MF_NRM]
    movaps  xmm0, xmm1
    lea     rdi, [r15+CP_RA]
    lea     rsi, [r15+CP_RB]
    call    impulse
    inc     r14d
    jmp     1b
9:  add     rsp, 8
    pop     r15
    pop     r14
    ret
# fr_row(edx=tangent's offset in the manifold, ecx=its impulse's, r8d=its
#   mass's in the point; [rsp+8] = the limit) - one friction direction
fr_row:
    push    r9
    push    r10
    push    r11
    mov     r9d, edx
    mov     r10d, ecx
    mov     r11d, r8d
    lea     rdi, [r15+CP_RA]
    lea     rsi, [r15+CP_RB]
    call    relvel
    DOT3    xmm0, [rbx+r9]
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
    shufps  xmm0, xmm0, 0
    mulps   xmm0, [rbx+r9]
    lea     rdi, [r15+CP_RA]
    lea     rsi, [r15+CP_RB]
    call    impulse
    pop     r11
    pop     r10
    pop     r9
    ret

# jr_prestep(rbx=joint) - anchors, errors, axes
jr_prestep:
    sub     rsp, 8
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
    cmp     dword ptr [rbx+JR_TYPE], 2
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
    jmp     9f
1:  cmp     dword ptr [rbx+JR_TYPE], 1
    jne     9f
    movaps  xmm0, [r13+BD_Q]            # fixed: 2 vec(qB conj(qA) conj(q0))
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
2:  addps   xmm0, xmm0
    andps   xmm0, [rip+rx_xyz]
    movaps  [rbx+JR_ERR], xmm0
9:  add     rsp, 8
    ret

# jr_solve(rbx=joint) - the anchors together (three rows), then the
#   rotation: hinge, two rows square to its axis; fixed, three
jr_solve:
    push    r14
    push    r15
    sub     rsp, 24
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
    movaps  [rsp], xmm0
    lea     rdi, [rbx+JR_RA]
    lea     rsi, [rbx+JR_RB]
    call    kmass
    movss   [rsp+16], xmm0
    lea     rdi, [rbx+JR_RA]
    lea     rsi, [rbx+JR_RB]
    call    relvel
    DOT3    xmm0, [rsp]                 # velocity along it
    movss   xmm1, [rbx+JR_C+r14*4]      # target: -beta C / dt
    mulss   xmm1, [rip+rx_beta]
    divss   xmm1, [rip+rb_dt]
    xorps   xmm1, [rip+rx_sign]
    subss   xmm1, xmm0
    mulss   xmm1, [rsp+16]
    shufps  xmm1, xmm1, 0
    mulps   xmm1, [rsp]
    movaps  xmm0, xmm1
    lea     rdi, [rbx+JR_RA]
    lea     rsi, [rbx+JR_RB]
    call    impulse
    inc     r14d
    jmp     1b
2:  cmp     dword ptr [rbx+JR_TYPE], 3
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
33: movaps  [rsp], xmm0                 # d; target -beta err / dt
    mulss   xmm1, [rip+rx_beta]
    divss   xmm1, [rip+rb_dt]
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
    call    solve_island
2:  inc     r12d
    jmp     1b
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# solve_island(edi=island)
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
    # forces: gravity, damping
    movss   xmm6, [rip+rb_dt]
    movaps  xmm7, [rip+rb_g]
    shufps  xmm6, xmm6, 0
    mulps   xmm7, xmm6                  # g dt
    mov     rax, [rip+rb_isb]
    mov     r14d, [rax+rdi*4]
    mov     r15d, [rax+rdi*4+4]
1:  cmp     r14d, r15d
    jae     2f
    mov     rax, [rip+rb_ib]
    mov     eax, [rax+r14*4]
    BODY    rbx, rax
    movaps  xmm0, [rbx+BD_V]
    addps   xmm0, xmm7
    movss   xmm1, [rbx+BD_DAMP]         # v / (1 + dt d)
    mulss   xmm1, [rip+rb_dt]
    addss   xmm1, [rip+rx_one]
    shufps  xmm1, xmm1, 0
    divps   xmm0, xmm1
    andps   xmm0, [rip+rx_xyz]
    movaps  [rbx+BD_V], xmm0
    movss   xmm1, [rip+rx_adamp]
    mulss   xmm1, [rip+rb_dt]
    addss   xmm1, [rip+rx_one]
    shufps  xmm1, xmm1, 0
    movaps  xmm0, [rbx+BD_W]
    divps   xmm0, xmm1
    andps   xmm0, [rip+rx_xyz]
    movaps  [rbx+BD_W], xmm0
    inc     r14d
    jmp     1b
2:  mov     edi, [rsp]                  # prestep
    lea     rsi, [rip+mf_prestep]
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
4:  # integrate; rest
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
    mov     rdi, rbx
    call    integrate
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
    movss   xmm6, [rip+rb_dt]
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
    movss   xmm6, [rip+rb_dt]
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
11: ucomiss xmm0, xmm1
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
4:  xor     edi, edi                    # a whole frame reached: kept
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
    mov     rdi, rbx
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
9:  add     rsp, 32
    pop     r13
    pop     r12
    pop     rbx
    ret

# rb_record(esi=frame) -> rax = 0 when not kept: the moving bodies' places
#   into the cache (count, then uid, loc, rot each)
rb_record:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     r14d, esi
    xor     r12d, r12d                  # how many
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
    inc     r12d
11: inc     ecx
    jmp     1b
2:  imul    edx, r12d, 28
    add     edx, 4
    xor     edi, edi
    mov     esi, r14d
    call    sc_add
    test    rax, rax
    jz      9f
    mov     r13, rax
    mov     [r13], r12d
    add     r13, 4
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
    mov     [r13], eax
    mov     rdi, rbx
    lea     rsi, [r13+4]
    call    body_pose
    add     r13, 28
4:  inc     r12d
    jmp     3b
8:  mov     eax, 1
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# rb_play(rdi=record) - a cached frame's places into the objects
rb_play:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12d, [rbx]
    add     rbx, 4
1:  test    r12d, r12d
    jz      9f
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
9:  mov     dword ptr [rip+dirty], 1
    pop     r13
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
    call    rb_sethash
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
    mov     rdi, [rdx+OB_MESH]
    call    sc_meshhash
2:  inc     r12d
    jmp     1b
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# rb_info(edi=what) -> xmm0: 0 bodies, 1 contact points, 2 awake, 3 islands,
#   4 the last frame's simulation (ms), 5 manifolds, 6 steps, 7 parts
rb_info:
    xorps   xmm0, xmm0
    cmp     dword ptr [rip+rb_on], 0
    je      9f
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
    mov     eax, [rip+rb_stepno]
8:  cvtsi2ss xmm0, eax
9:  ret

# =============================================================================
#  Operators
# =============================================================================
OPERATOR op_rb_add,   "rigid.add",    "Add Rigid Body",    do_rb_add, flags=OPF_AI_SAFE|OPF_UNDO, doc="Make the selected objects rigid bodies (or change them): rigid.add [active|passive] [box|sphere|capsule|hull|compound] [mass m] [friction f] [bounce b] [damping d]. Active ones fall when the frame goes past the start"
OPERATOR op_rb_rem,   "rigid.remove", "Remove Rigid Body", do_rb_rem, flags=OPF_AI_SAFE|OPF_UNDO, doc="The selected objects are no longer rigid bodies"
OPERATOR op_rb_joint, "rigid.joint",  "Add Joint",         do_rb_joint, flags=OPF_AI_SAFE|OPF_UNDO, doc="Tie two bodies (or one to the world): rigid.joint <fixed|hinge|point> <object> <object|world> [pivot x y z] [axis x y z] (pivot: the first object's place; axis: Y)"
OPERATOR op_rb_world, "rigid.world",  "Physics World",     do_rb_world, flags=OPF_AI_SAFE|OPF_UNDO, doc="Physics settings: rigid.world [gravity x y z] [rate steps-a-second] [iterations n]"

.section .rodata
k_active:       .asciz "active"
k_passive:      .asciz "passive"
shape_names:    .quad k_box, k_sphere, k_capsule, k_hull, k_compound, 0
k_box:          .asciz "box"
k_sphere:       .asciz "sphere"
k_capsule:      .asciz "capsule"
k_hull:         .asciz "hull"
k_compound:     .asciz "compound"
rb_keys:        .quad k_mass, k_friction, k_bounce, k_damping, 0
k_mass:         .asciz "mass"
k_friction:     .asciz "friction"
k_bounce:       .asciz "bounce"
k_damping:      .asciz "damping"
jt_names:       .quad k_dash, k_fixed, k_hinge, k_point, 0
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
s_rb_bad:       .asciz "  rigid.add [active|passive] [box|sphere|capsule|hull|compound] [mass m] [friction f] [bounce b] [damping d] - not understood: "
s_rb_none:      .asciz "  select mesh objects to make rigid bodies"
s_rb_full:      .asciz "  no room for more rigid bodies / joints"
s_rb_added:     .asciz "  rigid bodies: "
s_jt_bad:       .asciz "  rigid.joint <fixed|hinge|point> <object> <object|world> [pivot x y z] [axis x y z] - not understood: "
s_rw_bad:       .asciz "  rigid.world [gravity x y z] [rate n] [iterations n] - not understood: "
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
    sub     rsp, 48
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
    and     dword ptr [rdi+RB_FLAGS], ~1  # (its start: from where it is)
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
    add     rsp, 48
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
    jz      .Lrj_bad
    lea     rdi, [rsp+JT_AXIS]
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

# rigid.world [gravity x y z] [rate n] [iterations n]
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
4:  cmp     eax, 1000
    jle     5f
    mov     eax, 1000
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
