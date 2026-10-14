# The B-rep kernel's records (nurbs.s, brep.s, bssi.s, bbool.s, btess.s,
# bfeat.s, step.s). Everything is doubles; records live in arenas and are
# named by index (the arena's base + index * size).

# ---- curves (bk_cv) ------------------------------------------------------------
.equ CV_SZ,      128
.equ CV_TYPE,    0
.equ CV_DIM,     4                      # 3, or 2 for a curve in a face's (u, v)
.equ CV_DEG,     8                      # NURBS: degree,
.equ CV_N,       12                     #  control points,
.equ CV_KN,      16                     #  knots (N + p + 1 doubles),
.equ CV_CP,      24                     #  homogeneous points (w x, w y, w z, w)
.equ CV_O,       32                     # line: O + t X; circle O + R (cos t X +
.equ CV_X,       56                     #  sin t Y); ellipse O + R1 cos t X +
.equ CV_Y,       80                     #  R2 sin t Y
.equ CV_R1,      104
.equ CV_R2,      112
.equ CV_FLAGS,   120
.equ CT_LINE,    1
.equ CT_CIRCLE,  2
.equ CT_ELLIPSE, 3
.equ CT_NURBS,   4

# ---- surfaces (bk_sf) ----------------------------------------------------------
.equ SF_SZ,      192
.equ SF_TYPE,    0
.equ SF_DU,      4
.equ SF_DV,      8
.equ SF_NU,      12
.equ SF_NV,      16
.equ SF_FLAGS,   20
.equ SF_KU,      24
.equ SF_KV,      32
.equ SF_CP,      40                     # nu * nv points, u major
.equ SF_O,       48
.equ SF_X,       72
.equ SF_Y,       96
.equ SF_Z,       120                    # (Z = X x Y)
.equ SF_R1,      144                    # radius / major radius
.equ SF_R2,      152                    # torus: minor radius; cone: half angle
.equ SF_SA,      160                    # cone: sin, cos of the half angle
.equ SF_CA,      168
.equ SF_ID,      176
.equ ST_PLANE,   1
.equ ST_CYL,     2
.equ ST_CONE,    3
.equ ST_SPHERE,  4
.equ ST_TORUS,   5
.equ ST_NURBS,   6

# ---- topology (brep.s) ---------------------------------------------------------
.equ VX_SZ,      32                     # a vertex: its point, tolerance
.equ VX_P,       0
.equ VX_TOL,     24

.equ ED_SZ,      64                     # an edge: a curve from t0 (v0) to t1 (v1)
.equ ED_CURVE,   0
.equ ED_V0,      4
.equ ED_V1,      8
.equ ED_FLAGS,   12
.equ ED_T0,      16
.equ ED_T1,      24
.equ ED_TOL,     32
.equ ED_POLY,    40                     # tessellation: (x, y, z, t) per point
.equ ED_NPOLY,   48
.equ ED_MARK,    52
.equ ED_AUX,     56
.equ EF_DEGEN,   1                      # collapsed to a point (a sphere's pole)
.equ EF_SEAM,    2

.equ CE_SZ,      48                     # a coedge: an edge used by a loop
.equ CE_EDGE,    0
.equ CE_REV,     4                      # 1: walked v1 -> v0
.equ CE_PC,      8                      # its curve in the face's (u, v)
.equ CE_LOOP,    12
.equ CE_P0,      16                     # the (u, v) curve's parameter at the
.equ CE_P1,      24                     #  coedge's start and end
.equ CE_AUX,     32

.equ LP_SZ,      16                     # a loop: coedges first .. first + n - 1
.equ LP_FIRST,   0
.equ LP_N,       4
.equ LP_FACE,    8
.equ LP_FLAGS,   12

.equ FC_SZ,      64                     # a face: part of a surface inside its loops
.equ FC_SURF,    0
.equ FC_SENSE,   4                      # 1: the outside is -(Su x Sv)
.equ FC_LOOP,    8                      # loops first .. first + n - 1 (the
.equ FC_NLOOP,   12                     #  first is the outer one)
.equ FC_COLOR,   16
.equ FC_FLAGS,   20
.equ FC_U0,      24                     # its (u, v) box
.equ FC_U1,      32
.equ FC_V0,      40
.equ FC_V1,      48
.equ FC_SRC,     56                     # the face it came from (booleans)
.equ FC_MARK,    60

.equ BD_SZ,      64                     # a body: faces first .. first + n - 1
.equ BD_FIRST,   0
.equ BD_NF,      4
.equ BD_FLAGS,   8
.equ BD_TRI,     16                     # tessellation (btess.s): a mesh
.equ BD_TOL,     24                     # linear tolerance
.equ BD_MIN,     32                     # box (floats)
.equ BD_MAX,     44
