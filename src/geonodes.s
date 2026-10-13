# =============================================================================
#  BeeModel - geometry nodes: node trees that make or change meshes.
#
#  A Geometry Nodes modifier runs a tree (ntree.s) on the mesh below it in
#  the stack. Geometry flows from the Group Input (that mesh) through
#  primitives, transforms, joins, set position, extrusion, subdivision,
#  booleans and merging to the Group Output; each node's mesh is made once
#  per evaluation. Fields - a value or vector per point - come from
#  position, normal, index, value, combine / separate, math, vector math,
#  noise and random nodes: the subgraph feeding an input compiles to a
#  program for the field VM (fieldvm.s), which runs it over the points in
#  blocks.
#
#  The types (1..35): group input, group output, grid, cube, UV sphere,
#  cylinder, mesh line, transform, join geometry, set position, extrude
#  mesh, subdivision surface, mesh boolean, merge by distance, realize
#  instances; position, normal, index, value, combine XYZ, separate XYZ,
#  math, vector math, noise texture, random value; group (another tree run
#  as one node: its Group Input gives the group node's geometry, value and
#  vector - fields cross the boundary - and its Group Output the result;
#  groups nest 8 deep); distribute points on faces (by area and density,
#  a seed, an optional minimum distance; the points keep their faces'
#  normals), instance on points (another geometry placed at every point:
#  aligned to the point's normal or up, a fixed or random turn about it, a
#  scale field - instances stay instances, inst.s, until realized); curve
#  line, curve circle, curve to mesh (a profile curve, else a round tube),
#  resample, trim, fillet and curve to points (curve.s: a curve is a chain
#  of 2-point polygons).
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

.globl gn_eval
.globl gn_type_names
.globl gn_meta
.globl gn_titles
.globl gn_defaults
.globl gn_type_index
.globl gn_ntypes
.globl op_tree_new
.globl gn_make_group

.equ GR_N,      128
.equ GR_NODES,  160
.equ NODE_SZ,   72
.equ ND_TYPE,   0
.equ ND_IN,     4
.equ ND_P,      52
.equ ND_POS,    68
.equ NT_MAXN,   48
.equ GN_NTYPES, 35
.equ GN_LEVELS, 8
# types
.equ T_GIN,     1
.equ T_GOUT,    2
.equ T_GRID,    3
.equ T_CUBE,    4
.equ T_SPHERE,  5
.equ T_CYL,     6
.equ T_LINE,    7
.equ T_XFORM,   8
.equ T_JOIN,    9
.equ T_SETPOS,  10
.equ T_EXTRUDE, 11
.equ T_SUBD,    12
.equ T_BOOL,    13
.equ T_MERGE,   14
.equ T_REALIZE, 15
.equ T_POS,     16
.equ T_NORMAL,  17
.equ T_INDEX,   18
.equ T_VALUE,   19
.equ T_COMBINE, 20
.equ T_SEP,     21
.equ T_MATH,    22
.equ T_VMATH,   23
.equ T_NOISE,   24
.equ T_RANDOM,  25
.equ T_GROUP,   26
.equ T_DIST,    27
.equ T_INST,    28
.equ T_CLINE,   29
.equ T_CCIRCLE, 30
.equ T_C2MESH,  31
.equ T_RESAMPLE,32
.equ T_TRIM,    33
.equ T_FILLET,  34
.equ T_C2PTS,   35
# field VM (fieldvm.s)
.equ OP_CONST,  1
.equ OP_PX,     2
.equ OP_NX,     5
.equ OP_INDEX,  8
.equ OP_ADD,    10
.equ OP_SUB,    11
.equ OP_MUL,    12
.equ OP_DIV,    13
.equ OP_MIN,    14
.equ OP_MAX,    15
.equ OP_LT,     16
.equ OP_GT,     17
.equ OP_POW,    18
.equ OP_MOD,    19
.equ OP_ABS,    20
.equ OP_SQRT,   21
.equ OP_FLOOR,  22
.equ OP_SIN,    23
.equ OP_COS,    24
.equ OP_NOISE,  26
.equ OP_RAND,   27
.equ OP_SEL,    29
.equ FC_N,      0
.equ FC_PROG,   8
.equ FC_NINS,   16
.equ FC_IN,     24
.equ FC_NOUT,   80
.equ FC_OUT,    88
.equ IN_SZ,     24
.equ GC_MAXI,   512
.equ GC_MAXR,   64

.section .rodata
.align 8
gn_ntypes:      .long GN_NTYPES
.align 8
gn_type_names:  .quad k_gin, k_gout, k_grid, k_cube, k_sphere, k_cyl, k_line, k_xform, k_join, k_setpos
                .quad k_extrude, k_subd, k_bool, k_merge, k_realize, k_pos, k_normal, k_index, k_value
                .quad k_combine, k_sep, k_math, k_vmath, k_noise, k_random, k_group, k_dist, k_inst
                .quad k_cline, k_ccircle, k_c2mesh, k_resample, k_trim, k_fillet, k_c2pts, 0
k_gin:          .asciz "input"
k_gout:         .asciz "output"
k_grid:         .asciz "grid"
k_cube:         .asciz "cube"
k_sphere:       .asciz "sphere"
k_cyl:          .asciz "cylinder"
k_line:         .asciz "line"
k_xform:        .asciz "transform"
k_join:         .asciz "join"
k_setpos:       .asciz "set_position"
k_extrude:      .asciz "extrude"
k_subd:         .asciz "subdivide"
k_bool:         .asciz "boolean"
k_merge:        .asciz "merge"
k_realize:      .asciz "realize"
k_pos:          .asciz "position"
k_normal:       .asciz "normal"
k_index:        .asciz "index"
k_value:        .asciz "value"
k_combine:      .asciz "combine_xyz"
k_sep:          .asciz "separate_xyz"
k_math:         .asciz "math"
k_vmath:        .asciz "vector_math"
k_noise:        .asciz "noise"
k_random:       .asciz "random"
k_group:        .asciz "group"
k_dist:         .asciz "distribute"
k_inst:         .asciz "instance"
k_cline:        .asciz "curve_line"
k_ccircle:      .asciz "curve_circle"
k_c2mesh:       .asciz "curve_to_mesh"
k_resample:     .asciz "resample"
k_trim:         .asciz "trim"
k_fillet:       .asciz "fillet"
k_c2pts:        .asciz "curve_to_points"
gn_titles:      .quad 0, n_gin, n_gout, n_grid, n_cube, n_sphere, n_cyl, n_line, n_xform, n_join, n_setpos
                .quad n_extrude, n_subd, n_bool, n_merge, n_realize, n_pos, n_normal, n_index, n_value
                .quad n_combine, n_sep, n_math, n_vmath, n_noise, n_random, n_group, n_dist, n_inst
                .quad n_cline, n_ccircle, n_c2mesh, n_resample, n_trim, n_fillet, n_c2pts
n_gin:          .asciz "Group Input"
n_gout:         .asciz "Group Output"
n_grid:         .asciz "Grid"
n_cube:         .asciz "Cube"
n_sphere:       .asciz "UV Sphere"
n_cyl:          .asciz "Cylinder"
n_line:         .asciz "Mesh Line"
n_xform:        .asciz "Transform"
n_join:         .asciz "Join Geometry"
n_setpos:       .asciz "Set Position"
n_extrude:      .asciz "Extrude Mesh"
n_subd:         .asciz "Subdivision Surface"
n_bool:         .asciz "Mesh Boolean"
n_merge:        .asciz "Merge by Distance"
n_realize:      .asciz "Realize Instances"
n_pos:          .asciz "Position"
n_normal:       .asciz "Normal"
n_index:        .asciz "Index"
n_value:        .asciz "Value"
n_combine:      .asciz "Combine XYZ"
n_sep:          .asciz "Separate XYZ"
n_math:         .asciz "Math"
n_vmath:        .asciz "Vector Math"
n_noise:        .asciz "Noise Texture"
n_random:       .asciz "Random Value"
n_group:        .asciz "Group"
n_dist:         .asciz "Distribute Points on Faces"
n_inst:         .asciz "Instance on Points"
n_cline:        .asciz "Curve Line"
n_ccircle:      .asciz "Curve Circle"
n_c2mesh:       .asciz "Curve to Mesh"
n_resample:     .asciz "Resample Curve"
n_trim:         .asciz "Trim Curve"
n_fillet:       .asciz "Fillet Curve"
n_c2pts:        .asciz "Curve to Points"
# per type (as the node editor reads it): input names, input kinds (0
#   geometry, 1 value, 2 vector), value names, value kinds (0 number, 1
#   choice, 3 whole), choices, output names, output kinds
gn_meta:        .quad 0, 0, 0, 0, 0, 0, 0
                .quad nil3, k000, nil4, k0000, 0, o_gin, k012              # group input
                .quad i_geo, k000, nil4, k0000, 0, nil3, k000              # group output
                .quad nil3, k000, p_grid, k0300, 0, o_mesh, k000           # grid
                .quad nil3, k000, p_size, k0000, 0, o_mesh, k000           # cube
                .quad nil3, k000, p_radius, k0000, 0, o_mesh, k000         # sphere
                .quad nil3, k000, p_cyl, k0000, 0, o_mesh, k000            # cylinder
                .quad nil3, k000, p_line, k3000, 0, o_mesh, k000           # line
                .quad i_xform, k022, p_rot, k0000, 0, o_geo, k000          # transform
                .quad i_join, k000, nil4, k0000, 0, o_geo, k000            # join
                .quad i_setpos, k012, nil4, k0000, 0, o_geo, k000          # set position
                .quad i_extrude, k010, p_dist, k0000, 0, o_mesh, k000      # extrude
                .quad i_mesh, k000, p_level, k3000, 0, o_mesh, k000        # subdivide
                .quad i_bool, k000, p_op, k1000, ch_bool, o_mesh, k000     # boolean
                .quad i_geo, k000, p_dist, k0000, 0, o_geo, k000           # merge
                .quad i_geo, k000, nil4, k0000, 0, o_geo, k000             # realize
                .quad nil3, k000, nil4, k0000, 0, o_pos, k222              # position
                .quad nil3, k000, nil4, k0000, 0, o_normal, k222           # normal
                .quad nil3, k000, nil4, k0000, 0, o_index, k111            # index
                .quad nil3, k000, p_value, k0000, 0, o_value, k111         # value
                .quad i_xyz, k111, nil4, k0000, 0, o_vector, k222          # combine
                .quad i_vector, k222, nil4, k0000, 0, o_xyz, k111          # separate
                .quad i_ab, k111, p_op, k1000, ch_math, o_value, k111      # math
                .quad i_abf, k221, p_op, k1000, ch_vmath, o_vv, k210       # vector math
                .quad i_vector, k222, p_noise, k0000, 0, o_noise, k120     # noise
                .quad nil3, k000, p_random, k0000, 0, o_value, k111        # random
                .quad i_group, k012, p_tree, k4000, 0, o_geo, k000         # group
                .quad i_mesh, k000, p_dist3, k0300, 0, o_points, k000      # distribute
                .quad i_inst, k001, p_inst, k1130, ch_rot, o_inst, k000    # instance
                .quad i_cline, k220, nil4, k0000, 0, o_curve, k000         # curve line
                .quad nil3, k000, p_ccircle, k3000, 0, o_curve, k000       # curve circle
                .quad i_c2mesh, k000, p_c2mesh, k0330, 0, o_mesh, k000     # curve to mesh
                .quad i_curve, k000, p_resample, k3000, 0, o_curve, k000   # resample
                .quad i_curve, k000, p_trim, k0000, 0, o_curve, k000       # trim
                .quad i_curve, k000, p_fillet, k0300, 0, o_curve, k000     # fillet
                .quad i_curve, k000, p_count, k3000, 0, o_points, k000     # curve to points
k220:           .byte 2, 2, 0, 0
k0330:          .byte 0, 3, 3, 0
k001:           .byte 0, 0, 1, 0
k0300b:         .byte 0, 3, 0, 0
k1130:          .byte 1, 1, 3, 0
k4000:          .byte 4, 0, 0, 0
nil3:           .quad 0, 0, 0
nil4:           .quad 0, 0, 0, 0
k000:           .byte 0, 0, 0, 0
k0000:          .byte 0, 0, 0, 0
k0300:          .byte 0, 3, 0, 0
k3000:          .byte 3, 0, 0, 0
k1000:          .byte 1, 0, 0, 0
k022:           .byte 0, 2, 2, 0
k012:           .byte 0, 1, 2, 0
k010:           .byte 0, 1, 0, 0
k222:           .byte 2, 2, 2, 0
k111:           .byte 1, 1, 1, 0
k221:           .byte 2, 2, 1, 0
k210:           .byte 2, 1, 0, 0
k120:           .byte 1, 2, 0, 0
.align 8
i_geo:          .quad s_geo, 0, 0
i_cline:        .quad s_start, s_end, 0
i_c2mesh:       .quad s_curve, s_profile, 0
i_curve:        .quad s_curve, 0, 0
o_curve:        .quad s_curve, 0, 0
p_ccircle:      .quad s_resolution, s_radius, 0, 0
p_c2mesh:       .quad s_radius, s_sides, s_fill, 0
p_resample:     .quad s_count, s_length, 0, 0
p_trim:         .quad s_start, s_end, 0, 0
p_fillet:       .quad s_radius, s_count, 0, 0
p_count:        .quad s_count, 0, 0, 0
i_mesh:         .quad s_mesh, 0, 0
i_xform:        .quad s_geo, s_transl, s_scale
i_join:         .quad s_geo, s_geo, s_geo
i_setpos:       .quad s_geo, s_sel, s_offset
i_extrude:      .quad s_mesh, s_sel, 0
i_bool:         .quad s_mesha, s_meshb, 0
i_xyz:          .quad s_x, s_y, s_z
i_vector:       .quad s_vector, 0, 0
i_ab:           .quad s_a, s_b, 0
i_abf:          .quad s_a, s_b, s_factor
i_group:        .quad s_geo, s_value, s_vector
o_gin:          .quad s_geo, s_value, s_vector
o_points:       .quad s_points, 0, 0
o_inst:         .quad s_instances, 0, 0
i_inst:         .quad s_points, s_instance, s_scale
p_dist3:        .quad s_density, s_seed, s_mindist, 0
p_inst:         .quad s_rotation, s_align, s_seed, 0
ch_rot:         .quad 2, c_fixed, c_randrot
p_tree:         .quad s_tree, 0, 0, 0
o_geo:          .quad s_geo, 0, 0
o_mesh:         .quad s_mesh, 0, 0
o_pos:          .quad s_position, 0, 0
o_normal:       .quad s_normal, 0, 0
o_index:        .quad s_index, 0, 0
o_value:        .quad s_value, 0, 0
o_vector:       .quad s_vector, 0, 0
o_xyz:          .quad s_x, s_y, s_z
o_vv:           .quad s_vector, s_value, 0
o_noise:        .quad s_fac, s_color, 0
p_grid:         .quad s_size, s_subdiv, 0, 0
p_size:         .quad s_size, 0, 0, 0
p_radius:       .quad s_radius, 0, 0, 0
p_cyl:          .quad s_radius, s_depth, 0, 0
p_line:         .quad s_count, s_offx, s_offy, s_offz
p_rot:          .quad s_rotx, s_roty, s_rotz, 0
p_dist:         .quad s_distance, 0, 0, 0
p_level:        .quad s_level, 0, 0, 0
p_op:           .quad s_operation, 0, 0, 0
p_value:        .quad s_value, 0, 0, 0
p_noise:        .quad s_scale, s_detail, s_rough, 0
p_random:       .quad s_min, s_max, s_seed, 0
ch_bool:        .quad 3, c_union, c_diff, c_isect
ch_math:        .quad 15, c_add, c_sub, c_mul, c_div, c_pow, c_min, c_max, c_lt, c_gt, c_sin, c_cos, c_abs, c_sqrt, c_floor, c_mod
ch_vmath:       .quad 10, c_add, c_sub, c_mul, c_scale, c_cross, c_dot, c_length, c_normalize, c_distance, c_mix
s_geo:          .asciz "Geometry"
s_mesh:         .asciz "Mesh"
s_mesha:        .asciz "Mesh A"
s_meshb:        .asciz "Mesh B"
s_transl:       .asciz "Translation"
s_scale:        .asciz "Scale"
s_sel:          .asciz "Selection"
s_offset:       .asciz "Offset"
s_x:            .asciz "X"
s_y:            .asciz "Y"
s_z:            .asciz "Z"
s_vector:       .asciz "Vector"
s_a:            .asciz "A"
s_b:            .asciz "B"
s_factor:       .asciz "Factor"
s_position:     .asciz "Position"
s_normal:       .asciz "Normal"
s_index:        .asciz "Index"
s_value:        .asciz "Value"
s_fac:          .asciz "Fac"
s_color:        .asciz "Color"
s_size:         .asciz "Size"
s_start:        .asciz "Start"
s_end:          .asciz "End"
s_curve:        .asciz "Curve"
s_profile:      .asciz "Profile Curve"
s_resolution:   .asciz "Resolution"
s_sides:        .asciz "Sides"
s_fill:         .asciz "Fill Caps"
s_length:       .asciz "Length"
s_subdiv:       .asciz "Subdivisions"
s_radius:       .asciz "Radius"
s_depth:        .asciz "Depth"
s_count:        .asciz "Count"
s_offx:         .asciz "Offset X"
s_offy:         .asciz "Offset Y"
s_offz:         .asciz "Offset Z"
s_rotx:         .asciz "Rotate X"
s_roty:         .asciz "Rotate Y"
s_rotz:         .asciz "Rotate Z"
s_distance:     .asciz "Distance"
s_level:        .asciz "Level"
s_operation:    .asciz "Operation"
s_detail:       .asciz "Detail"
s_rough:        .asciz "Roughness"
s_min:          .asciz "Min"
s_max:          .asciz "Max"
s_seed:         .asciz "Seed"
s_tree:         .asciz "Tree"
s_points:       .asciz "Points"
s_instances:    .asciz "Instances"
s_instance:     .asciz "Instance"
s_density:      .asciz "Density"
s_mindist:      .asciz "Distance Min"
s_rotation:     .asciz "Rotation"
s_align:        .asciz "Align"
c_fixed:        .asciz "Fixed"
c_randrot:      .asciz "Random"
c_union:        .asciz "Union"
c_diff:         .asciz "Difference"
c_isect:        .asciz "Intersect"
c_add:          .asciz "Add"
c_sub:          .asciz "Subtract"
c_mul:          .asciz "Multiply"
c_div:          .asciz "Divide"
c_pow:          .asciz "Power"
c_min:          .asciz "Minimum"
c_max:          .asciz "Maximum"
c_lt:           .asciz "Less Than"
c_gt:           .asciz "Greater Than"
c_sin:          .asciz "Sine"
c_cos:          .asciz "Cosine"
c_abs:          .asciz "Absolute"
c_sqrt:         .asciz "Square Root"
c_floor:        .asciz "Floor"
c_mod:          .asciz "Modulo"
c_scale:        .asciz "Scale"
c_cross:        .asciz "Cross Product"
c_dot:          .asciz "Dot Product"
c_length:       .asciz "Length"
c_normalize:    .asciz "Normalize"
c_distance:     .asciz "Distance"
c_mix:          .asciz "Mix"
# defaults per type: 4 values, then the 3 inputs' xyz
.align 4
gn_defaults:    .float 0, 0, 0, 0,  0, 0, 0,  0, 0, 0,  0, 0, 0     # input
                .float 0, 0, 0, 0,  0, 0, 0,  0, 0, 0,  0, 0, 0     # output
                .float 2, 10, 0, 0,  0, 0, 0,  0, 0, 0,  0, 0, 0    # grid
                .float 2, 0, 0, 0,  0, 0, 0,  0, 0, 0,  0, 0, 0     # cube
                .float 1, 0, 0, 0,  0, 0, 0,  0, 0, 0,  0, 0, 0     # sphere
                .float 1, 2, 0, 0,  0, 0, 0,  0, 0, 0,  0, 0, 0     # cylinder
                .float 10, 0, 0.5, 0,  0, 0, 0,  0, 0, 0,  0, 0, 0  # line
                .float 0, 0, 0, 0,  0, 0, 0,  0, 0, 0,  1, 1, 1     # transform
                .float 0, 0, 0, 0,  0, 0, 0,  0, 0, 0,  0, 0, 0     # join
                .float 0, 0, 0, 0,  0, 0, 0,  1, 1, 1,  0, 0, 0     # set position
                .float 0.2, 0, 0, 0,  0, 0, 0,  1, 1, 1,  0, 0, 0   # extrude
                .float 1, 0, 0, 0,  0, 0, 0,  0, 0, 0,  0, 0, 0     # subdivide
                .float 1, 0, 0, 0,  0, 0, 0,  0, 0, 0,  0, 0, 0     # boolean
                .float 0.001, 0, 0, 0,  0, 0, 0,  0, 0, 0,  0, 0, 0 # merge
                .float 0, 0, 0, 0,  0, 0, 0,  0, 0, 0,  0, 0, 0     # realize
                .float 0, 0, 0, 0,  0, 0, 0,  0, 0, 0,  0, 0, 0     # position
                .float 0, 0, 0, 0,  0, 0, 0,  0, 0, 0,  0, 0, 0     # normal
                .float 0, 0, 0, 0,  0, 0, 0,  0, 0, 0,  0, 0, 0     # index
                .float 0, 0, 0, 0,  0, 0, 0,  0, 0, 0,  0, 0, 0     # value
                .float 0, 0, 0, 0,  0, 0, 0,  0, 0, 0,  0, 0, 0     # combine
                .float 0, 0, 0, 0,  0, 0, 0,  0, 0, 0,  0, 0, 0     # separate
                .float 0, 0, 0, 0,  0.5, 0.5, 0.5,  0.5, 0.5, 0.5,  0, 0, 0   # math
                .float 0, 0, 0, 0,  0, 0, 0,  0, 0, 0,  1, 1, 1     # vector math
                .float 5, 2, 0.5, 0,  0, 0, 0,  0, 0, 0,  0, 0, 0   # noise
                .float 0, 1, 0, 0,  0, 0, 0,  0, 0, 0,  0, 0, 0     # random
                .float 0, 0, 0, 0,  0, 0, 0,  0, 0, 0,  0, 0, 0     # group
                .float 10, 0, 0, 0,  0, 0, 0,  0, 0, 0,  0, 0, 0    # distribute
                .float 1, 1, 0, 0,  0, 0, 0,  0, 0, 0,  1, 1, 1     # instance
                .float 0, 0, 0, 0,  0, 0, 0,  0, 1, 0,  0, 0, 0     # curve line
                .float 32, 1, 0, 0,  0, 0, 0,  0, 0, 0,  0, 0, 0    # curve circle
                .float 0.1, 8, 0, 0,  0, 0, 0,  0, 0, 0,  0, 0, 0   # curve to mesh
                .float 10, 0, 0, 0,  0, 0, 0,  0, 0, 0,  0, 0, 0    # resample
                .float 0, 1, 0, 0,  0, 0, 0,  0, 0, 0,  0, 0, 0     # trim
                .float 0.25, 4, 0, 0,  0, 0, 0,  0, 0, 0,  0, 0, 0  # fillet
                .float 10, 0, 0, 0,  0, 0, 0,  0, 0, 0,  0, 0, 0    # curve to points
gz_deg:         .float 0.017453292
gz_half:        .float 0.5
gz_third:       .float 0.33333334
gz_one:         .float 1.0
gz_tiny:        .float 1.0e-12
gz_ident:       .float 1, 0, 0, 0,  0, 1, 0, 0,  0, 0, 1, 0
s_tree_need:    .asciz "  tree.node <tree> <type> [values]: input output grid cube sphere cylinder line transform join set_position extrude subdivide boolean merge realize position normal index value combine_xyz separate_xyz math vector_math noise random group distribute instance curve_line curve_circle curve_to_mesh resample trim fillet curve_to_points"
s_tree_linkneed:.asciz "  tree.link <tree> <from[:output]> <to> <input 1-3> (no loops)"
s_tree_setneed: .asciz "  tree.node_set <tree> <node> <slot> <x> [y z]"
s_tree_delneed: .asciz "  tree.node_delete <tree> <node>"
s_tree_moveneed:.asciz "  tree.node_move <tree> <node> <x> <y>"
s_tree_groupneed:.asciz "  tree.group <tree> <node> [node ...] (not the group input / output)"
s_tree_none:    .asciz "  no node tree named: "
s_tree_made:    .asciz "  node tree: "
s_group_name:   .asciz "Group"

.section .bss
.align 8
gn_rec:         .skip 8                 # the tree being evaluated,
gn_inmesh:      .skip 8                 #  the modifier's input mesh
gn_res:         .skip 8*NT_MAXN         # each node's mesh (owned), once
gn_depth:       .skip 4
# field compilation
gc_regs:        .skip NT_MAXN*9*GN_LEVELS   # per level, node, output, component: register + 1
gn_level:       .skip 4                 # groups entered
gn_save:        .skip GN_LEVELS*(8*NT_MAXN+16)  # the outer level's state
gn_ctx_rec:     .skip 8*GN_LEVELS       # per level: the tree holding its group
gn_ctx_node:    .skip 4*GN_LEVELS       #  node, and that node
gc_prog:        .skip GC_MAXI*IN_SZ
gc_n:           .skip 4
gc_r:           .skip 4                 # registers used
gc_bad:         .skip 4
gc_depth:       .skip 4
gc_uses:        .skip 4                 # inputs read: 1 position, 2 normal, 4 index
gc_out:         .skip 12                # the registers of the field asked for
gc_tmp:         .skip 64
gn_word:        .skip 8
mg_map:         .skip 4*NT_MAXN         # make group: old -> new (inner / outer)
mg_map2:        .skip 4*NT_MAXN
mg_tmp:         .skip NODE_SZ*(NT_MAXN+1)

.text
OPERATOR op_tree_new, "tree.new", "New Node Tree", do_tree_new, flags=OPF_AI_SAFE|OPF_UNDO, doc="A new, empty geometry node tree: tree.new [name]"
OPERATOR op_tree_node, "tree.node", "Add Geometry Node", do_tree_node, flags=OPF_AI_SAFE|OPF_UNDO, doc="Add a node to a tree: tree.node <tree> <type> [values]"
OPERATOR op_tree_link, "tree.link", "Link Geometry Nodes", do_tree_link, flags=OPF_AI_SAFE|OPF_UNDO, doc="Feed a node's output into an input: tree.link <tree> <from[:output]> <to> <input 1-3> (the tree keeps itself in evaluation order)"
OPERATOR op_tree_set, "tree.node_set", "Set Geometry Node Value", do_tree_set, flags=OPF_AI_SAFE|OPF_UNDO|OPF_QUIET, doc="Set a node input (1-3) or value (4-7): tree.node_set <tree> <node> <slot> <x> [y z]"
OPERATOR op_tree_del, "tree.node_delete", "Delete Geometry Node", do_tree_del, flags=OPF_AI_SAFE|OPF_UNDO, doc="Remove a node from a tree: tree.node_delete <tree> <node>"
OPERATOR op_tree_group, "tree.group", "Make Node Group", do_tree_group, flags=OPF_AI_SAFE|OPF_UNDO, doc="Move nodes into a new tree run by one Group node: tree.group <tree> <node> [node ...]"
OPERATOR op_tree_move, "tree.node_move", "Move Geometry Node", do_tree_move, flags=OPF_AI_SAFE|OPF_UNDO|OPF_QUIET, doc="Place a node in the node editor: tree.node_move <tree> <node> <x> <y>"

# gn_type_index(rdi=name) -> eax = type (1..) or -1
gn_type_index:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     r12, rdi
    xor     ebx, ebx
1:  lea     rax, [rip+gn_type_names]
    mov     rsi, [rax+rbx*8]
    test    rsi, rsi
    jz      8f
    mov     rdi, r12
    call    str_eq
    test    eax, eax
    jnz     2f
    inc     ebx
    jmp     1b
2:  lea     eax, [rbx+1]
    jmp     9f
8:  mov     eax, -1
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Operators
# =============================================================================
# gn_next(rsi=text) -> im_word = the next word, rsi after, eax = length
gn_next:
    jmp     im_next_word

# gn_arg_tree(rsi=text) -> eax = tree (or -1, logged), rsi after
gn_arg_tree:
    push    rbx
    call    im_next_word
    mov     rbx, rsi
    test    eax, eax
    jz      8f
    lea     rdi, [rip+im_word]
    call    nt_find
    test    eax, eax
    jns     9f
8:  lea     rdi, [rip+s_tree_none]
    lea     rsi, [rip+im_word]
    call    log_pair
    mov     eax, -1
9:  mov     rsi, rbx
    pop     rbx
    ret

# gn_arg_num(rsi=text) -> xmm0, eax = 1 if a number, rsi after
gn_arg_num:
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

# tree.new [name]
do_tree_new:
    push    rbx
    mov     rsi, [rip+op_arg]
    call    im_next_word
    lea     rdi, [rip+im_word]
    test    eax, eax
    jnz     1f
    xor     edi, edi
1:  call    nt_new
    test    eax, eax
    js      8f
    mov     edi, eax
    call    nt_get
    lea     rdi, [rip+s_tree_made]
    mov     rsi, rax
    call    log_pair
    pop     rbx
    ret
8:  call    undo_drop_last
    pop     rbx
    ret

# gn_add(edi=tree, esi=type) -> eax = node or -1
gn_add:
    lea     eax, [rsi-1]
    cmp     eax, GN_NTYPES
    jae     8f
    imul    eax, eax, 52
    lea     rdx, [rip+gn_defaults]
    add     rdx, rax
    jmp     nt_add
8:  mov     eax, -1
    ret

# tree.node <tree> <type> [values p0..p3]
do_tree_node:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 24
    mov     rsi, [rip+op_arg]
    call    gn_arg_tree
    test    eax, eax
    js      .Ltn_drop
    mov     r12d, eax
    call    im_next_word
    mov     r14, rsi
    test    eax, eax
    jz      .Ltn_need
    lea     rdi, [rip+im_word]
    call    gn_type_index
    test    eax, eax
    js      .Ltn_need
    mov     edi, r12d
    mov     esi, eax
    call    gn_add
    test    eax, eax
    js      .Ltn_need
    mov     r13d, eax
    mov     ebx, 4                      # values: slots 4..7
1:  cmp     ebx, 8
    jae     2f
    mov     rsi, r14
    call    gn_arg_num
    mov     r14, rsi
    test    eax, eax
    jz      2f
    movss   [rsp], xmm0
    mov     edi, r12d
    mov     esi, r13d
    mov     edx, ebx
    lea     rcx, [rsp]
    mov     r8d, 1
    call    nt_set
    inc     ebx
    jmp     1b
2:  mov     edi, r13d
    call    say_tnode
    jmp     .Ltn_out
.Ltn_need:
    lea     rdi, [rip+s_tree_need]
    call    log_line
.Ltn_drop:
    call    undo_drop_last
.Ltn_out:
    add     rsp, 24
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# say_tnode(edi=node) - "  node N" on the console (agents read it)
say_tnode:
    push    rbx
    mov     ebx, edi
    call    fmt_reset
    lea     rdi, [rip+s_say_node]
    call    fmt_str
    mov     edi, ebx
    call    fmt_int
    lea     rdi, [rip+fmt_buf]
    call    log_line
    pop     rbx
    ret

.section .rodata
s_say_node:     .asciz "  node "
.text

# tree.link <tree> <from[:output]> <to> <input>
do_tree_link:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 24
    mov     rsi, [rip+op_arg]
    call    gn_arg_tree
    test    eax, eax
    js      .Ltl_drop
    mov     r12d, eax
    call    im_next_word                # from[:output]
    mov     r14, rsi
    test    eax, eax
    jz      .Ltl_need
    lea     rsi, [rip+im_word]
    lea     rdx, [rsi+rax]
    call    parse_float
    test    eax, eax
    jz      .Ltl_need
    cvttss2si r13d, xmm0
    mov     dword ptr [rsp+8], 0
    cmp     byte ptr [rsi], ':'
    jne     1f
    inc     rsi
    lea     rdx, [rip+im_word+64]
    call    parse_float
    cvttss2si eax, xmm0
    mov     [rsp+8], eax
1:  mov     rsi, r14
    call    gn_arg_num
    test    eax, eax
    jz      .Ltl_need
    cvttss2si eax, xmm0
    mov     [rsp], eax                  # to
    call    gn_arg_num
    test    eax, eax
    jz      .Ltl_need
    cvttss2si ecx, xmm0                 # input
    mov     edi, r12d
    mov     esi, r13d
    mov     edx, [rsp]
    mov     r8d, [rsp+8]
    call    nt_link
    test    eax, eax
    jz      .Ltl_need
    mov     edi, eax
    call    say_tnode
    jmp     .Ltl_out
.Ltl_need:
    lea     rdi, [rip+s_tree_linkneed]
    call    log_line
.Ltl_drop:
    call    undo_drop_last
.Ltl_out:
    add     rsp, 24
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# tree.node_set <tree> <node> <slot> <x> [y z]
do_tree_set:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 40
    mov     rsi, [rip+op_arg]
    call    gn_arg_tree
    test    eax, eax
    js      .Lts_drop
    mov     r12d, eax
    call    gn_arg_num
    test    eax, eax
    jz      .Lts_need
    cvttss2si r13d, xmm0
    call    gn_arg_num
    test    eax, eax
    jz      .Lts_need
    cvttss2si r14d, xmm0
    xor     ebx, ebx
1:  cmp     ebx, 3
    jae     2f
    push    rsi
    push    rsi
    call    gn_arg_num
    pop     rdx
    pop     rdx
    test    eax, eax
    jz      2f
    movss   [rsp+rbx*4], xmm0
    inc     ebx
    jmp     1b
2:  test    ebx, ebx
    jz      .Lts_need
    mov     edi, r12d
    mov     esi, r13d
    mov     edx, r14d
    lea     rcx, [rsp]
    mov     r8d, ebx
    call    nt_set
    test    eax, eax
    jz      .Lts_need
    jmp     .Lts_out
.Lts_need:
    lea     rdi, [rip+s_tree_setneed]
    call    log_line
.Lts_drop:
    call    undo_drop_last
.Lts_out:
    add     rsp, 40
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# tree.node_delete <tree> <node>
do_tree_del:
    push    rbx
    mov     rsi, [rip+op_arg]
    call    gn_arg_tree
    test    eax, eax
    js      8f
    mov     ebx, eax
    call    gn_arg_num
    test    eax, eax
    jz      7f
    cvttss2si esi, xmm0
    mov     edi, ebx
    call    nt_delete
    test    eax, eax
    jz      7f
    pop     rbx
    ret
7:  lea     rdi, [rip+s_tree_delneed]
    call    log_line
8:  call    undo_drop_last
    pop     rbx
    ret

# tree.group <tree> <node> [node ...]
do_tree_group:
    push    rbx
    push    r12
    push    r13
    mov     rsi, [rip+op_arg]
    call    gn_arg_tree
    test    eax, eax
    js      8f
    mov     ebx, eax
    xor     r12d, r12d                  # the mask
1:  call    gn_arg_num
    test    eax, eax
    jz      2f
    cvttss2si eax, xmm0
    cmp     eax, 1
    jl      1b
    cmp     eax, NT_MAXN
    ja      1b
    bts     r12, rax
    jmp     1b
2:  mov     edi, ebx
    mov     rsi, r12
    call    gn_make_group
    test    eax, eax
    jz      7f
    mov     edi, eax
    call    say_tnode
    jmp     9f
7:  lea     rdi, [rip+s_tree_groupneed]
    call    log_line
8:  call    undo_drop_last
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# tree.node_move <tree> <node> <x> <y>
do_tree_move:
    push    rbx
    push    r12
    push    r13
    mov     rsi, [rip+op_arg]
    call    gn_arg_tree
    test    eax, eax
    js      8f
    mov     ebx, eax
    call    gn_arg_num
    test    eax, eax
    jz      7f
    cvttss2si r12d, xmm0
    call    gn_arg_num
    test    eax, eax
    jz      7f
    cvttss2si r13d, xmm0
    call    gn_arg_num
    test    eax, eax
    jz      7f
    cvttss2si ecx, xmm0
    mov     edi, ebx
    mov     esi, r12d
    mov     edx, r13d
    call    nt_place
    test    eax, eax
    jz      7f
    jmp     9f
7:  lea     rdi, [rip+s_tree_moveneed]
    call    log_line
8:  call    undo_drop_last
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Evaluation
# =============================================================================
# gn_eval(rdi=mesh, esi=tree + 1) -> rax = the tree's result (a new mesh),
#   or 0: no tree, no output, or the result is the mesh itself
gn_eval:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     [rip+gn_inmesh], rdi
    xor     r12d, r12d
    lea     edi, [rsi-1]
    test    esi, esi
    jle     .Lge_out
    call    nt_get
    test    rax, rax
    jz      .Lge_out
    mov     rbx, rax
    mov     [rip+gn_rec], rax
    lea     rdi, [rip+gn_res]
    xor     eax, eax
    mov     ecx, NT_MAXN
    rep     stosq
    xor     r13d, r13d                  # the Group Output
1:  cmp     r13d, [rbx+GR_N]
    jae     .Lge_out
    cmp     r13d, NT_MAXN
    jae     .Lge_out
    imul    eax, r13d, NODE_SZ
    cmp     dword ptr [rbx+GR_NODES+rax+ND_TYPE], T_GOUT
    je      2f
    inc     r13d
    jmp     1b
2:  lea     edi, [r13+1]
    xor     esi, esi
    call    gn_input_geo                # its Geometry
    mov     r12, rax
    xor     r14d, r14d                  # the nodes' meshes go
3:  cmp     r14d, NT_MAXN
    jae     4f
    lea     rax, [rip+gn_res]
    mov     rdi, [rax+r14*8]
    call    mesh_unref
    inc     r14d
    jmp     3b
4:  cmp     r12, [rip+gn_inmesh]        # unchanged: nothing to do
    jne     .Lge_out
    mov     rdi, r12
    call    mesh_unref
    xor     r12d, r12d
.Lge_out:
    mov     rax, r12
    add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# gn_input_geo(edi=node 1.., esi=input 0..2) -> rax = the mesh fed to it (a
#   new reference), or 0
gn_input_geo:
    mov     rax, [rip+gn_rec]
    lea     ecx, [rdi-1]
    imul    ecx, ecx, NODE_SZ
    shl     esi, 4
    add     ecx, esi
    movzx   esi, word ptr [rax+GR_NODES+rcx+ND_IN]
    test    esi, esi
    jz      8f
    cmp     esi, [rax+GR_N]
    ja      8f
    mov     edi, esi
    jmp     gn_geo
8:  xor     eax, eax
    ret

# gn_geo(edi=node 1..) -> rax = its mesh (a new reference), or 0
gn_geo:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 104
    mov     r12d, edi
    lea     rax, [rip+gn_res]
    mov     rax, [rax+r12*8-8]
    test    rax, rax
    jnz     .Lgg_have
    cmp     dword ptr [rip+gn_depth], 64
    jae     .Lgg_none
    inc     dword ptr [rip+gn_depth]
    mov     rbx, [rip+gn_rec]
    lea     eax, [r12-1]
    imul    eax, eax, NODE_SZ
    lea     r13, [rbx+GR_NODES+rax]     # the node
    mov     eax, [r13+ND_TYPE]
    cmp     eax, T_GIN
    je      .Lgg_input
    cmp     eax, T_GRID
    je      .Lgg_grid
    cmp     eax, T_CUBE
    je      .Lgg_cube
    cmp     eax, T_SPHERE
    je      .Lgg_sphere
    cmp     eax, T_CYL
    je      .Lgg_cyl
    cmp     eax, T_LINE
    je      .Lgg_line
    cmp     eax, T_XFORM
    je      .Lgg_xform
    cmp     eax, T_JOIN
    je      .Lgg_join
    cmp     eax, T_SETPOS
    je      .Lgg_setpos
    cmp     eax, T_EXTRUDE
    je      .Lgg_extrude
    cmp     eax, T_SUBD
    je      .Lgg_subd
    cmp     eax, T_BOOL
    je      .Lgg_bool
    cmp     eax, T_MERGE
    je      .Lgg_merge
    cmp     eax, T_REALIZE
    je      .Lgg_realize
    cmp     eax, T_GROUP
    je      .Lgg_group
    cmp     eax, T_DIST
    je      .Lgg_dist
    cmp     eax, T_INST
    je      .Lgg_inst
    cmp     eax, T_CLINE
    je      .Lgg_cline
    cmp     eax, T_CCIRCLE
    je      .Lgg_ccircle
    cmp     eax, T_C2MESH
    je      .Lgg_c2mesh
    lea     rcx, [rip+cn_resample]
    cmp     eax, T_RESAMPLE
    je      .Lgg_curve
    lea     rcx, [rip+cn_trim]
    cmp     eax, T_TRIM
    je      .Lgg_curve
    lea     rcx, [rip+cn_fillet]
    cmp     eax, T_FILLET
    je      .Lgg_curve
    lea     rcx, [rip+cn_points]
    cmp     eax, T_C2PTS
    je      .Lgg_curve
    xor     eax, eax
    jmp     .Lgg_done
.Lgg_cline:                             # curves (curve.s): chains of lines
    mov     rsi, r13
    call    cn_line
    jmp     .Lgg_done
.Lgg_ccircle:
    mov     rsi, r13
    call    cn_circle
    jmp     .Lgg_done
.Lgg_curve:                             # rcx = fn(rdi=curve, rsi=node)
    mov     [rsp], rcx
    mov     edi, r12d
    xor     esi, esi
    call    gn_input_geo
    test    rax, rax
    jz      .Lgg_done
    mov     r14, rax
    mov     rdi, rax
    mov     rsi, r13
    call    [rsp]
    push    rax
    push    rax
    mov     rdi, r14
    call    mesh_unref
    pop     rax
    pop     rax
    jmp     .Lgg_done
.Lgg_c2mesh:                            # curve, profile
    mov     edi, r12d
    xor     esi, esi
    call    gn_input_geo
    test    rax, rax
    jz      .Lgg_done
    mov     r14, rax
    mov     edi, r12d
    mov     esi, 1
    call    gn_input_geo
    mov     r15, rax
    mov     rdi, r14
    mov     rdx, r15
    mov     rsi, r13
    call    cn_to_mesh
    push    rax
    push    rax
    mov     rdi, r14
    call    mesh_unref
    mov     rdi, r15
    call    mesh_unref
    pop     rax
    pop     rax
    jmp     .Lgg_done
.Lgg_input:
    mov     rax, [rip+gn_inmesh]
    jmp     .Lgg_keep
.Lgg_pass:
    mov     edi, r12d
    xor     esi, esi
    call    gn_input_geo
    jmp     .Lgg_done
.Lgg_realize:                           # instances into plain geometry
    mov     edi, r12d
    xor     esi, esi
    call    gn_input_geo
    test    rax, rax
    jz      .Lgg_done
    cmp     qword ptr [rax+ME_INST], 0
    je      .Lgg_done
    mov     r14, rax
    mov     rdi, rax
    call    inst_realize
    push    rax
    push    rax
    mov     rdi, r14
    call    mesh_unref
    pop     rax
    pop     rax
    jmp     .Lgg_done
.Lgg_dist:
    mov     edi, r12d
    xor     esi, esi
    call    gn_input_geo
    test    rax, rax
    jz      .Lgg_done
    mov     r14, rax
    mov     rdi, r14
    mov     rsi, r13
    call    gn_distribute
    push    rax
    push    rax
    mov     rdi, r14
    call    mesh_unref
    pop     rax
    pop     rax
    jmp     .Lgg_done
.Lgg_inst:
    mov     edi, r12d                   # points, instance
    xor     esi, esi
    call    gn_input_geo
    test    rax, rax
    jz      .Lgg_done
    mov     r14, rax
    mov     edi, r12d
    mov     esi, 1
    call    gn_input_geo
    mov     r15, rax
    test    r15, r15
    jz      .Lgg_keep_r14
    mov     rdi, r14
    mov     rsi, r15
    mov     edx, r12d
    mov     rcx, r13
    call    gn_instance
    push    rax
    push    rax
    mov     rdi, r14
    call    mesh_unref
    mov     rdi, r15
    call    mesh_unref
    pop     rax
    pop     rax
    jmp     .Lgg_done
.Lgg_grid:
    cvttss2si edi, [r13+ND_P+4]
    cmp     edi, 1
    jge     1f
    mov     edi, 1
1:  cmp     edi, 1000
    jle     2f
    mov     edi, 1000
2:  call    prim_grid_n
    movss   xmm0, [r13+ND_P]            # 2 m -> size
    mulss   xmm0, [rip+gz_half]
    movss   xmm1, [rip+gz_one]
    movss   xmm2, xmm0
    jmp     .Lgg_scaled
.Lgg_cube:
    call    prim_cube
    movss   xmm0, [r13+ND_P]
    mulss   xmm0, [rip+gz_half]
    movss   xmm1, xmm0
    movss   xmm2, xmm0
    jmp     .Lgg_scaled
.Lgg_sphere:
    call    prim_uvsphere
    movss   xmm0, [r13+ND_P]
    movss   xmm1, xmm0
    movss   xmm2, xmm0
    jmp     .Lgg_scaled
.Lgg_cyl:
    call    prim_cylinder
    movss   xmm0, [r13+ND_P]
    movss   xmm1, [r13+ND_P+4]
    mulss   xmm1, [rip+gz_half]
    movss   xmm2, xmm0
.Lgg_scaled:                            # rax = a new mesh: scaled by x y z
    test    rax, rax
    jz      .Lgg_done
    mov     r14, rax
    movss   [rsp], xmm0
    movss   [rsp+4], xmm1
    movss   [rsp+8], xmm2
    mov     ecx, [r14+ME_NVERTS]
    mov     rdx, [r14+ME_POS]
3:  test    ecx, ecx
    jz      4f
    movss   xmm0, [rdx]
    mulss   xmm0, [rsp]
    movss   [rdx], xmm0
    movss   xmm0, [rdx+4]
    mulss   xmm0, [rsp+4]
    movss   [rdx+4], xmm0
    movss   xmm0, [rdx+8]
    mulss   xmm0, [rsp+8]
    movss   [rdx+8], xmm0
    add     rdx, 12
    dec     ecx
    jmp     3b
4:  mov     rdi, r14
    call    mesh_bbox
    mov     rax, r14
    jmp     .Lgg_done
.Lgg_line:                              # points (no faces): count, offset
    cvttss2si r14d, [r13+ND_P]
    cmp     r14d, 1
    jge     1f
    mov     r14d, 1
1:  cmp     r14d, 1000000
    jle     2f
    mov     r14d, 1000000
2:  mov     edi, r14d
    mov     esi, 8
    mov     edx, 2
    call    mesh_new
    test    rax, rax
    jz      .Lgg_done
    mov     r15, rax
    xor     ebp, ebp
3:  cmp     ebp, r14d
    jae     4f
    cvtsi2ss xmm3, ebp
    movss   xmm0, [r13+ND_P+4]
    mulss   xmm0, xmm3
    movss   xmm1, [r13+ND_P+8]
    mulss   xmm1, xmm3
    movss   xmm2, [r13+ND_P+12]
    mulss   xmm2, xmm3
    mov     rdi, r15
    call    mesh_add_vert
    inc     ebp
    jmp     3b
4:  mov     rdi, r15
    call    mesh_finish
    mov     rax, r15
    jmp     .Lgg_done
.Lgg_xform:                             # copy; R (X, Y, Z degrees), S, T
    mov     edi, r12d
    xor     esi, esi
    call    gn_input_geo
    test    rax, rax
    jz      .Lgg_done
    mov     r14, rax
    mov     rdi, r14
    call    mesh_copy
    push    rax
    push    rax
    mov     rdi, r14
    call    mesh_unref
    pop     r14
    pop     rax
    test    r14, r14
    jz      .Lgg_fail
    lea     rdi, [rsp+16]               # the matrix (3x4) at rsp+16
    mov     rsi, r13
    call    gn_matrix
    mov     ecx, [r14+ME_NVERTS]
    mov     rdx, [r14+ME_POS]
5:  test    ecx, ecx
    jz      6f
    xor     r8d, r8d
51: movss   xmm0, [rsp+16+r8*4]         # row r: m . p + t
    mulss   xmm0, [rdx]
    movss   xmm1, [rsp+20+r8*4]
    mulss   xmm1, [rdx+4]
    addss   xmm0, xmm1
    movss   xmm1, [rsp+24+r8*4]
    mulss   xmm1, [rdx+8]
    addss   xmm0, xmm1
    addss   xmm0, [rsp+28+r8*4]
    movss   [rsp+64+r8], xmm0
    add     r8d, 4
    cmp     r8d, 12
    jb      51b
    mov     eax, [rsp+64]
    mov     [rdx], eax
    mov     eax, [rsp+68]
    mov     [rdx+4], eax
    mov     eax, [rsp+72]
    mov     [rdx+8], eax
    add     rdx, 12
    dec     ecx
    jmp     5b
6:  mov     rdi, r14
    call    mesh_bbox
    inc     dword ptr [r14+ME_VER]
    mov     rdi, [r14+ME_INST]          # instances: placed by it too
    test    rdi, rdi
    jz      7f
    lea     rsi, [rsp+16]
    call    inst_xform
    push    rax
    push    rax
    mov     rdi, [r14+ME_INST]
    call    inst_unref
    pop     rax
    pop     rax
    mov     [r14+ME_INST], rax
7:  mov     rax, r14
    jmp     .Lgg_done
.Lgg_join:                              # the inputs appended in order
    xor     r14d, r14d                  # (the result so far)
    xor     ebp, ebp
1:  cmp     ebp, 3
    jae     3f
    mov     edi, r12d
    mov     esi, ebp
    call    gn_input_geo
    inc     ebp
    test    rax, rax
    jz      1b
    test    r14, r14
    jnz     2f
    mov     r14, rax
    jmp     1b
2:  mov     r15, rax
    mov     rdi, r14
    mov     rsi, r15
    call    mesh_append
    push    rax
    push    rax
    test    rax, rax                    # (instances: both lists)
    jz      21f
    mov     rdi, [r14+ME_INST]
    mov     rsi, [r15+ME_INST]
    call    inst_merge
    mov     rcx, [rsp]
    mov     [rcx+ME_INST], rax
21: mov     rdi, r14
    call    mesh_unref
    mov     rdi, r15
    call    mesh_unref
    pop     r14
    pop     rax
    jmp     1b
3:  mov     rax, r14
    jmp     .Lgg_done
.Lgg_setpos:                            # pos += offset where selected
    mov     edi, r12d
    xor     esi, esi
    call    gn_input_geo
    test    rax, rax
    jz      .Lgg_done
    mov     r14, rax
    mov     rdi, r14
    call    mesh_copy
    mov     r15, rax
    mov     rdi, r14
    call    mesh_unref
    test    r15, r15
    jz      .Lgg_fail
    mov     rdi, r15                    # selection (input 2), offset (3)
    mov     esi, r12d
    mov     edx, 1
    mov     ecx, 2
    lea     r8, [rsp+16]                # -> 4 arrays: sel, x, y, z
    call    gn_fields
    test    eax, eax
    jz      7f
    mov     ecx, [r15+ME_NVERTS]
    mov     rdx, [r15+ME_POS]
    mov     rsi, [rsp+16]
    xor     r8d, r8d
5:  cmp     r8d, ecx
    jae     6f
    movss   xmm0, [rsi+r8*4]
    comiss  xmm0, [rip+gz_half]
    jbe     51f
    mov     rax, [rsp+24]
    movss   xmm0, [rax+r8*4]
    addss   xmm0, [rdx]
    movss   [rdx], xmm0
    mov     rax, [rsp+32]
    movss   xmm0, [rax+r8*4]
    addss   xmm0, [rdx+4]
    movss   [rdx+4], xmm0
    mov     rax, [rsp+40]
    movss   xmm0, [rax+r8*4]
    addss   xmm0, [rdx+8]
    movss   [rdx+8], xmm0
51: add     rdx, 12
    inc     r8d
    jmp     5b
6:  mov     rdi, r15
    call    mesh_bbox
7:  mov     rax, r15
    jmp     .Lgg_done
.Lgg_extrude:                           # faces whose points are selected
    mov     edi, r12d
    xor     esi, esi
    call    gn_input_geo
    test    rax, rax
    jz      .Lgg_done
    mov     r14, rax
    mov     rdi, r14
    call    mesh_copy
    mov     r15, rax
    mov     rdi, r14
    call    mesh_unref
    test    r15, r15
    jz      .Lgg_fail
    mov     rdi, r15                    # selection (input 2), no vector
    mov     esi, r12d
    mov     edx, 1
    mov     ecx, -1
    lea     r8, [rsp+16]
    call    gn_fields
    test    eax, eax
    jz      7f
    mov     ecx, [r15+ME_NVERTS]
    mov     rdx, [r15+ME_VSEL]
    mov     rsi, [rsp+16]
    xor     r8d, r8d
5:  cmp     r8d, ecx
    jae     6f
    movss   xmm0, [rsi+r8*4]
    xor     eax, eax
    comiss  xmm0, [rip+gz_half]
    seta    al
    mov     [rdx+r8], al
    inc     r8d
    jmp     5b
6:  mov     rdi, r15
    movss   xmm0, [r13+ND_P]
    call    build_extrude_ind
    test    rax, rax
    jz      7f
    push    rax
    push    rax
    mov     rdi, r15
    call    mesh_unref
    pop     rax
    pop     rax
    jmp     .Lgg_done
7:  mov     rax, r15
    jmp     .Lgg_done
.Lgg_subd:
    mov     edi, r12d
    xor     esi, esi
    call    gn_input_geo
    test    rax, rax
    jz      .Lgg_done
    mov     r14, rax
    cvttss2si esi, [r13+ND_P]
    test    esi, esi
    jle     .Lgg_keep_r14
    cmp     esi, 6
    jle     1f
    mov     esi, 6
1:  mov     rdi, r14
    call    subsurf_eval
    test    rax, rax
    jz      .Lgg_keep_r14
    push    rax
    push    rax
    mov     rdi, r14
    call    mesh_unref
    pop     rax
    pop     rax
    jmp     .Lgg_done
.Lgg_keep_r14:
    mov     rax, r14
    jmp     .Lgg_done
.Lgg_bool:
    mov     edi, r12d
    xor     esi, esi
    call    gn_input_geo
    mov     r14, rax
    mov     edi, r12d
    mov     esi, 1
    call    gn_input_geo
    mov     r15, rax
    test    r14, r14
    jz      3f
    test    r15, r15
    jz      .Lgg_keep_r14
    mov     rdi, r14
    mov     rsi, r15
    lea     rdx, [rip+gz_ident]
    cvttss2si ecx, [r13+ND_P]
    call    mesh_boolean
    test    rax, rax
    jz      2f
    push    rax
    push    rax
    mov     rdi, r14
    call    mesh_unref
    mov     rdi, r15
    call    mesh_unref
    pop     rax
    pop     rax
    jmp     .Lgg_done
2:  mov     rdi, r15                    # failed: A as it was
    call    mesh_unref
    jmp     .Lgg_keep_r14
3:  mov     rax, r15
    jmp     .Lgg_done
.Lgg_merge:
    mov     edi, r12d
    xor     esi, esi
    call    gn_input_geo
    test    rax, rax
    jz      .Lgg_done
    mov     r14, rax
    mov     rdi, r14
    movss   xmm0, [r13+ND_P]
    call    mesh_merge_dist
    test    rax, rax
    jz      .Lgg_keep_r14
    push    rax
    push    rax
    mov     rdi, r14
    call    mesh_unref
    pop     rax
    pop     rax
    jmp     .Lgg_done
.Lgg_group:                             # another tree, one level in
    mov     edi, r12d
    xor     esi, esi
    call    gn_input_geo
    mov     r14, rax                    # (its geometry: the inner input)
    cvttss2si edi, [r13+ND_P]
    mov     esi, r12d
    mov     rdx, r14
    call    gn_group_eval
    test    rax, rax
    jnz     1f
    mov     rax, r14                    # (no such tree, too deep: through)
    jmp     .Lgg_done
1:  push    rax
    push    rax
    mov     rdi, r14
    call    mesh_unref
    pop     rax
    pop     rax
    jmp     .Lgg_done
.Lgg_fail:
    xor     eax, eax
    jmp     .Lgg_done
.Lgg_keep:                              # rax: borrowed - a reference of ours
    push    rax
    push    rax
    mov     rdi, rax
    call    mesh_ref
    pop     rax
    pop     rax
.Lgg_done:
    dec     dword ptr [rip+gn_depth]
    lea     rcx, [rip+gn_res]           # remembered (its own reference)
    mov     [rcx+r12*8-8], rax
.Lgg_have:
    test    rax, rax
    jz      .Lgg_out
    push    rax
    push    rax
    mov     rdi, rax
    call    mesh_ref
    pop     rax
    pop     rax
    jmp     .Lgg_out
.Lgg_none:
    xor     eax, eax
.Lgg_out:
    add     rsp, 104
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# gn_meta_row(edi=type) -> rax = its gn_meta row or 0
gn_meta_row:
    xor     eax, eax
    test    edi, edi
    jle     9f
    cmp     edi, GN_NTYPES
    ja      9f
    imul    eax, edi, 56
    lea     rcx, [rip+gn_meta]
    add     rax, rcx
9:  ret

# gn_make_group(edi=tree, rsi=selected nodes (bit n = node n)) -> eax = the
#   group node made in the tree (0: nothing to group). The selected nodes go
#   into a new tree between a Group Input and a Group Output; links into
#   them from outside come through the Group Input (its geometry, value and
#   vector: the first of each kind), the first geometry output used outside
#   becomes the group's output.
gn_make_group:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 72
    mov     [rsp], edi                  # tree
    mov     r12, rsi                    # mask
    mov     edi, [rsp]
    call    nt_get
    test    rax, rax
    jz      .Lmg_none
    mov     ecx, [rax+GR_N]             # valid nodes, not group in / out
    mov     [rsp+4], ecx
    btr     r12, 0
    xor     edx, edx
1:  inc     edx
    cmp     edx, ecx
    ja      2f
    bt      r12, rdx
    jnc     1b
    lea     r8d, [rdx-1]
    imul    r8d, r8d, NODE_SZ
    mov     r9d, [rax+GR_NODES+r8+ND_TYPE]
    cmp     r9d, T_GIN
    je      11f
    cmp     r9d, T_GOUT
    jne     1b
11: btr     r12, rdx
    jmp     1b
2:  lea     ecx, [rcx+1]                # (bits above n)
    cmp     ecx, 63
    ja      21f
    mov     rax, -1
    shl     rax, cl
    not     rax
    and     r12, rax
21: test    r12, r12
    jz      .Lmg_none
    lea     rdi, [rip+s_group_name]     # the inner tree
    call    nt_new
    test    eax, eax
    js      .Lmg_none
    mov     [rsp+8], eax
    mov     edi, eax
    mov     esi, T_GIN
    call    gn_add
    mov     edi, [rsp+8]
    mov     esi, T_GOUT
    call    gn_add
    lea     rdi, [rip+mg_map]
    xor     eax, eax
    mov     ecx, NT_MAXN
    rep     stosd
    mov     dword ptr [rsp+12], 2       # inner node count
    xor     r13d, r13d                  # the selected nodes copied in
3:  inc     r13d
    cmp     r13d, [rsp+4]
    ja      4f
    bt      r12, r13
    jnc     3b
    mov     edi, [rsp+8]
    call    nt_own
    mov     rbx, rax
    mov     edi, [rsp]
    call    nt_get
    lea     ecx, [r13-1]
    imul    ecx, ecx, NODE_SZ
    lea     rsi, [rax+GR_NODES+rcx]
    mov     ecx, [rbx+GR_N]
    imul    ecx, ecx, NODE_SZ
    lea     rdi, [rbx+GR_NODES+rcx]
    mov     ecx, NODE_SZ
    rep     movsb
    inc     dword ptr [rbx+GR_N]
    mov     eax, [rbx+GR_N]
    lea     rcx, [rip+mg_map]
    mov     [rcx+r13*4-4], eax
    jmp     3b
4:  mov     edi, [rsp+8]                # inner links: inside kept, outside
    call    nt_own                      #  through the group input
    mov     rbx, rax
    mov     dword ptr [rsp+16], 0       # ext: geometry, value, vector links
    mov     dword ptr [rsp+20], 0
    mov     dword ptr [rsp+24], 0
    mov     r13d, 3
5:  cmp     r13d, [rbx+GR_N]
    ja      6f
    lea     eax, [r13-1]
    imul    eax, eax, NODE_SZ
    lea     r14, [rbx+GR_NODES+rax]
    mov     edi, [r14+ND_TYPE]
    call    gn_meta_row
    mov     r15, rax
    xor     ebp, ebp
51: mov     eax, ebp
    shl     eax, 4
    mov     ecx, [r14+ND_IN+rax]
    movzx   edx, cx
    test    edx, edx
    jz      58f
    cmp     edx, [rsp+4]
    ja      57f
    bt      r12, rdx
    jnc     52f
    lea     r8, [rip+mg_map]            # inside: renumbered
    mov     edx, [r8+rdx*4-4]
    and     ecx, 0xffff0000
    or      ecx, edx
    mov     [r14+ND_IN+rax], ecx
    jmp     58f
52: xor     r8d, r8d                    # outside: by the input's kind
    test    r15, r15
    jz      53f
    mov     r9, [r15+8]
    movzx   r8d, byte ptr [r9+rbp]
    cmp     r8d, 2
    jbe     53f
    xor     r8d, r8d
53: cmp     dword ptr [rsp+16+r8*4], 0
    jne     54f
    mov     [rsp+16+r8*4], ecx
54: mov     ecx, r8d                    # group input (node 1), output kind
    shl     ecx, 16
    or      ecx, 1
    mov     [r14+ND_IN+rax], ecx
    jmp     58f
57: mov     dword ptr [r14+ND_IN+rax], 0
58: inc     ebp
    cmp     ebp, 3
    jb      51b
    inc     r13d
    jmp     5b
6:  mov     dword ptr [rsp+28], 0       # the output: a selected node's
    mov     edi, [rsp]                  #  geometry used outside
    call    nt_get
    mov     rbx, rax
    xor     r13d, r13d
7:  inc     r13d
    cmp     r13d, [rsp+4]
    ja      8f
    bt      r12, r13
    jc      7b
    lea     eax, [r13-1]
    imul    eax, eax, NODE_SZ
    lea     r14, [rbx+GR_NODES+rax]
    xor     ebp, ebp
71: mov     eax, ebp
    shl     eax, 4
    mov     ecx, [r14+ND_IN+rax]
    movzx   edx, cx
    test    edx, edx
    jz      72f
    cmp     edx, [rsp+4]
    ja      72f
    bt      r12, rdx
    jnc     72f
    lea     eax, [rdx-1]                # its output: geometry?
    imul    eax, eax, NODE_SZ
    mov     edi, [rbx+GR_NODES+rax+ND_TYPE]
    push    rcx
    push    rcx
    call    gn_meta_row
    pop     rcx
    pop     rcx
    test    rax, rax
    jz      72f
    mov     r8, [rax+48]
    mov     edx, ecx
    shr     edx, 16
    and     edx, 0xff
    cmp     byte ptr [r8+rdx], 0
    jne     72f
    mov     [rsp+28], ecx
    jmp     8f
72: inc     ebp
    cmp     ebp, 3
    jb      71b
    jmp     7b
8:  mov     ecx, [rsp+28]               # inner Group Output <- it
    test    ecx, ecx
    jz      81f
    movzx   edx, cx
    lea     r8, [rip+mg_map]
    mov     edx, [r8+rdx*4-4]
    and     ecx, 0xffff0000
    or      ecx, edx
    push    rcx
    push    rcx
    mov     edi, [rsp+16+8]
    call    nt_own
    pop     rcx
    pop     rcx
    mov     [rax+GR_NODES+NODE_SZ+ND_IN], ecx   # (node 2: the output)
81: # the outer tree: the others kept, a group node after them
    mov     edi, [rsp]
    call    nt_own
    mov     rbx, rax
    lea     rdi, [rip+mg_map2]
    xor     eax, eax
    mov     ecx, NT_MAXN
    rep     stosd
    xor     r14d, r14d                  # kept so far
    xor     r13d, r13d
    xor     r15d, r15d                  # the selected nodes' place (sum)
    xor     ebp, ebp
9:  inc     r13d
    cmp     r13d, [rsp+4]
    ja      10f
    lea     eax, [r13-1]
    imul    eax, eax, NODE_SZ
    lea     rsi, [rbx+GR_NODES+rax]
    bt      r12, r13
    jnc     91f
    movsx   eax, word ptr [rsi+ND_POS]  # (selected: where they were)
    add     r15d, eax
    movsx   eax, word ptr [rsi+ND_POS+2]
    add     ebp, eax
    jmp     9b
91: imul    eax, r14d, NODE_SZ
    lea     rdi, [rip+mg_tmp]
    add     rdi, rax
    mov     ecx, NODE_SZ
    rep     movsb
    inc     r14d
    lea     rcx, [rip+mg_map2]
    mov     [rcx+r13*4-4], r14d
    jmp     9b
10: inc     r14d                        # the group node
    mov     [rsp+32], r14d
    lea     eax, [r14-1]
    imul    eax, eax, NODE_SZ
    lea     rdi, [rip+mg_tmp]
    add     rdi, rax
    push    rdi
    push    rdi
    xor     eax, eax
    mov     ecx, NODE_SZ/4
    rep     stosd
    pop     rdi
    pop     rdi
    mov     dword ptr [rdi+ND_TYPE], T_GROUP
    mov     eax, [rsp+8]
    inc     eax
    cvtsi2ss xmm0, eax
    movss   [rdi+ND_P], xmm0
    xor     ecx, ecx                    # its inputs: the outside links
101:mov     eax, [rsp+16+rcx*4]
    movzx   edx, ax
    test    edx, edx
    jz      102f
    lea     r8, [rip+mg_map2]
    mov     edx, [r8+rdx*4-4]
    and     eax, 0xffff0000
    or      eax, edx
    test    edx, edx
    jnz     103f
102:xor     eax, eax
103:mov     r8d, ecx
    shl     r8d, 4
    mov     [rdi+ND_IN+r8], eax
    inc     ecx
    cmp     ecx, 3
    jb      101b
    popcnt  rcx, r12                    # its place: the selection's middle
    mov     eax, r15d
    cdq
    idiv    ecx
    mov     [rdi+ND_POS], ax
    mov     eax, ebp
    cdq
    idiv    ecx
    mov     [rdi+ND_POS+2], ax
    xor     r13d, r13d                  # the kept nodes' links renumbered
11: cmp     r13d, r14d
    jae     12f
    imul    eax, r13d, NODE_SZ
    lea     rdi, [rip+mg_tmp]
    lea     rdi, [rdi+rax+ND_IN]
    lea     eax, [r13+1]
    cmp     eax, [rsp+32]
    je      114f
    xor     ebp, ebp
111:mov     ecx, [rdi]
    movzx   edx, cx
    test    edx, edx
    jz      113f
    cmp     edx, [rsp+4]
    ja      112f
    bt      r12, rdx
    jc      115f
    lea     r8, [rip+mg_map2]
    mov     edx, [r8+rdx*4-4]
    and     ecx, 0xffff0000
    or      ecx, edx
    mov     [rdi], ecx
    jmp     113f
115:cmp     ecx, [rsp+28]               # the group's output: the group node
    jne     112f
    mov     ecx, [rsp+32]
    mov     [rdi], ecx
    jmp     113f
112:mov     dword ptr [rdi], 0
113:add     rdi, 16
    inc     ebp
    cmp     ebp, 3
    jb      111b
114:inc     r13d
    jmp     11b
12: lea     rsi, [rip+mg_tmp]           # back into the tree
    lea     rdi, [rbx+GR_NODES]
    imul    ecx, r14d, NODE_SZ
    rep     movsb
    mov     ecx, [rsp+4]                # (the rest cleared)
    sub     ecx, r14d
    jle     13f
    imul    ecx, ecx, NODE_SZ
    xor     eax, eax
    rep     stosb
13: mov     [rbx+GR_N], r14d
    mov     eax, [rsp+32]
    jmp     .Lmg_out
.Lmg_none:
    xor     eax, eax
.Lmg_out:
    add     rsp, 72
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# gn_group_eval(edi=tree number, esi=the group node, rdx=its input mesh or
#   0) -> rax = the inner tree's result (a new reference) or 0
gn_group_eval:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r12d, esi
    mov     r13, rdx
    dec     edi
    js      8f
    mov     ecx, [rip+gn_level]
    cmp     ecx, GN_LEVELS-1
    jae     8f
    call    nt_get
    test    rax, rax
    jz      8f
    cmp     rax, [rip+gn_rec]           # (itself: never)
    je      8f
    mov     r14, rax
    mov     ecx, [rip+gn_level]         # the outer state saved
    imul    ecx, ecx, 8*NT_MAXN+16
    lea     rbx, [rip+gn_save]
    add     rbx, rcx
    lea     rsi, [rip+gn_res]
    mov     rdi, rbx
    mov     ecx, NT_MAXN
    rep     movsq
    mov     rax, [rip+gn_rec]
    mov     [rdi], rax
    mov     rax, [rip+gn_inmesh]
    mov     [rdi+8], rax
    mov     ecx, [rip+gn_level]         # the context of the level entered
    inc     ecx
    lea     rax, [rip+gn_ctx_rec]
    mov     rdx, [rip+gn_rec]
    mov     [rax+rcx*8], rdx
    lea     rax, [rip+gn_ctx_node]
    mov     [rax+rcx*4], r12d
    mov     [rip+gn_level], ecx
    mov     [rip+gn_rec], r14
    mov     [rip+gn_inmesh], r13
    lea     rdi, [rip+gn_res]
    xor     eax, eax
    mov     ecx, NT_MAXN
    rep     stosq
    xor     r15d, r15d                  # its Group Output's geometry
    xor     ecx, ecx
1:  cmp     ecx, [r14+GR_N]
    jae     3f
    cmp     ecx, NT_MAXN
    jae     3f
    imul    eax, ecx, NODE_SZ
    cmp     dword ptr [r14+GR_NODES+rax+ND_TYPE], T_GOUT
    je      2f
    inc     ecx
    jmp     1b
2:  lea     edi, [rcx+1]
    xor     esi, esi
    call    gn_input_geo
    mov     r15, rax
3:  xor     r12d, r12d                  # the inner meshes go
4:  lea     rax, [rip+gn_res]
    mov     rdi, [rax+r12*8]
    call    mesh_unref
    inc     r12d
    cmp     r12d, NT_MAXN
    jb      4b
    lea     rsi, [rbx]                  # the outer state back
    lea     rdi, [rip+gn_res]
    mov     ecx, NT_MAXN
    rep     movsq
    mov     rax, [rsi]
    mov     [rip+gn_rec], rax
    mov     rax, [rsi+8]
    mov     [rip+gn_inmesh], rax
    dec     dword ptr [rip+gn_level]
    mov     rax, r15
    jmp     9f
8:  xor     eax, eax
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Scattering
# =============================================================================
.section .bss
.align 8
gd_mesh:        .skip 8                 # distribute: the source, the points,
gd_out:         .skip 8
gd_off:         .skip 8                 #  per triangle: its first point
gd_density:     .skip 4
gd_seed:        .skip 4
gi_pts:         .skip 8                 # instance on points: the points,
gi_ib:          .skip 8                 #  the block, the scales, the node
gi_scale:       .skip 8
gi_rot:         .skip 4
gi_align:       .skip 4
gi_seed:        .skip 4
.section .rodata
.align 4
gz_2pi:         .float 6.2831853
gz_inv24:       .float 5.9604645e-8
.text

# gn_hash(edi, esi, edx) -> eax: 32 mixed bits; gn_u01 -> xmm0 in [0, 1)
gn_hash:
    imul    edi, edi, 0x27d4eb2d
    imul    esi, esi, 0x165667b1
    imul    edx, edx, 0x9e3779b1
    xor     edi, esi
    xor     edi, edx
    mov     eax, edi
    shr     eax, 15
    xor     eax, edi
    imul    eax, eax, 0x2c1b3c6d
    mov     edx, eax
    shr     edx, 12
    xor     eax, edx
    imul    eax, eax, 0x297a2d39
    mov     edx, eax
    shr     edx, 15
    xor     eax, edx
    ret
gn_u01:
    call    gn_hash
    shr     eax, 8
    cvtsi2ss xmm0, eax
    mulss   xmm0, [rip+gz_inv24]
    ret

# gd_tri(rdi=mesh, esi=triangle, rdx=out float[9] corners, r8 = out normal
#   (unit) float[3]) -> xmm0 = its area
gd_tri:
    push    rbx
    mov     rbx, rdx
    lea     eax, [rsi+rsi*2]
    mov     rcx, [rdi+ME_TRIS]
    lea     rcx, [rcx+rax*4]
    xor     eax, eax
1:  mov     edx, [rcx+rax*4]
    lea     rdx, [rdx+rdx*2]
    shl     rdx, 2
    add     rdx, [rdi+ME_POS]
    imul    r9d, eax, 12
    mov     r10, [rdx]
    mov     [rbx+r9], r10
    mov     r10d, [rdx+8]
    mov     [rbx+r9+8], r10d
    inc     eax
    cmp     eax, 3
    jb      1b
    movss   xmm0, [rbx+12]              # e1 = v1 - v0, e2 = v2 - v0
    subss   xmm0, [rbx]
    movss   xmm1, [rbx+16]
    subss   xmm1, [rbx+4]
    movss   xmm2, [rbx+20]
    subss   xmm2, [rbx+8]
    movss   xmm3, [rbx+24]
    subss   xmm3, [rbx]
    movss   xmm4, [rbx+28]
    subss   xmm4, [rbx+4]
    movss   xmm5, [rbx+32]
    subss   xmm5, [rbx+8]
    movss   xmm6, xmm1                  # n = e1 x e2
    mulss   xmm6, xmm5
    movss   xmm7, xmm2
    mulss   xmm7, xmm4
    subss   xmm6, xmm7
    movss   xmm7, xmm2
    mulss   xmm7, xmm3
    mulss   xmm5, xmm0
    subss   xmm7, xmm5
    mulss   xmm0, xmm4
    mulss   xmm1, xmm3
    subss   xmm0, xmm1
    movss   [r8], xmm6
    movss   [r8+4], xmm7
    movss   [r8+8], xmm0
    mulss   xmm6, xmm6
    mulss   xmm7, xmm7
    mulss   xmm0, xmm0
    addss   xmm6, xmm7
    addss   xmm6, xmm0
    sqrtss  xmm6, xmm6                  # |n| = 2 area
    maxss   xmm6, [rip+gz_tiny]
    movss   xmm1, [rip+gz_one]
    divss   xmm1, xmm6
    movss   xmm0, [r8]
    mulss   xmm0, xmm1
    movss   [r8], xmm0
    movss   xmm0, [r8+4]
    mulss   xmm0, xmm1
    movss   [r8+4], xmm0
    movss   xmm0, [r8+8]
    mulss   xmm0, xmm1
    movss   [r8+8], xmm0
    movss   xmm0, xmm6
    mulss   xmm0, [rip+gz_half]
    pop     rbx
    ret

# gd_count(esi=triangle) -> eax = its points: area x density, rounded by
#   chance (the seed)
gd_count:
    push    rbx
    sub     rsp, 64
    mov     ebx, esi
    mov     rdi, [rip+gd_mesh]
    lea     rdx, [rsp]
    lea     r8, [rsp+48]
    call    gd_tri
    mulss   xmm0, [rip+gd_density]
    movss   [rsp+40], xmm0
    mov     edi, ebx
    mov     esi, [rip+gd_seed]
    mov     edx, 0x51ed
    call    gn_u01
    addss   xmm0, [rsp+40]
    cvttss2si eax, xmm0
    test    eax, eax
    jns     1f
    xor     eax, eax
1:  add     rsp, 64
    pop     rbx
    ret

# gn_distribute(rdi=mesh, rsi=node) -> rax = the points (a new mesh: no
#   faces, point normals), or 0
gn_distribute:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     rbx, rdi
    mov     r12, rsi
    mov     [rip+gd_mesh], rdi
    movss   xmm0, [r12+ND_P]
    xorps   xmm1, xmm1
    maxss   xmm0, xmm1
    movss   [rip+gd_density], xmm0
    cvttss2si eax, [r12+ND_P+4]
    mov     [rip+gd_seed], eax
    mov     edi, [rbx+ME_NTRIS]         # per triangle: how many, where
    lea     edi, [rdi*4+16]
    call    gn_fa
    test    rax, rax
    jz      8f
    mov     [rip+gd_off], rax
    lea     rdi, [rip+gd_job_count]
    xor     esi, esi
    mov     edx, [rbx+ME_NTRIS]
    mov     ecx, 256
    call    parallel_for
    mov     rcx, [rip+gd_off]           # offsets
    xor     eax, eax
    xor     edx, edx
1:  cmp     edx, [rbx+ME_NTRIS]
    jae     2f
    mov     r8d, [rcx+rdx*4]
    mov     [rcx+rdx*4], eax
    add     eax, r8d
    jc      8f
    cmp     eax, 50000000               # (a bound: 50 million points)
    ja      8f
    inc     edx
    jmp     1b
2:  mov     [rcx+rdx*4], eax
    mov     r13d, eax                   # points
    lea     edi, [rax+1]
    mov     esi, 4
    mov     edx, 2
    call    mesh_new
    test    rax, rax
    jz      8f
    mov     r14, rax
    mov     [rip+gd_out], rax
    mov     rdi, r14
    call    mesh_pnrm_alloc
    test    rax, rax
    jz      7f
    mov     [r14+ME_NVERTS], r13d
    lea     rdi, [rip+gd_job_place]
    xor     esi, esi
    mov     edx, [rbx+ME_NTRIS]
    mov     ecx, 64
    call    parallel_for
    movss   xmm0, [r12+ND_P+8]          # a minimum distance: thinned
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    jbe     3f
    mov     rdi, r14
    call    gd_thin
3:  mov     rdi, r14
    call    mesh_finish
    mov     rax, r14
    jmp     9f
7:  mov     rdi, r14
    call    mesh_unref
8:  xor     eax, eax
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

gd_job_count:
    push    rbx
    push    r12
    push    r13
    mov     r12d, esi
    mov     r13d, edx
1:  cmp     r12d, r13d
    jae     9f
    mov     esi, r12d
    call    gd_count
    mov     rcx, [rip+gd_off]
    mov     [rcx+r12*4], eax
    inc     r12d
    jmp     1b
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# gd_job_place(esi, edx) - each triangle's points: uniform on it (two
#   random numbers each), its normal
gd_job_place:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 88
    mov     r12d, esi
    mov     r13d, edx
.Lgp_tri:
    cmp     r12d, r13d
    jae     .Lgp_out
    mov     rcx, [rip+gd_off]
    mov     r14d, [rcx+r12*4]           # its first point, its count
    mov     r15d, [rcx+r12*4+4]
    sub     r15d, r14d
    jz      .Lgp_next
    mov     rdi, [rip+gd_mesh]
    mov     esi, r12d
    lea     rdx, [rsp]
    lea     r8, [rsp+48]
    call    gd_tri
    xor     ebx, ebx
.Lgp_pt:
    cmp     ebx, r15d
    jae     .Lgp_next
    mov     edi, r12d                   # r1, r2
    mov     esi, ebx
    mov     edx, [rip+gd_seed]
    call    gn_u01
    movss   [rsp+64], xmm0
    lea     edi, [r12+0x3779]
    mov     esi, ebx
    mov     edx, [rip+gd_seed]
    call    gn_u01
    movss   xmm1, xmm0                  # b1 = s (1 - r2), b2 = s r2,
    sqrtss  xmm2, [rsp+64]              #  b0 = 1 - s
    movss   xmm3, [rip+gz_one]
    subss   xmm3, xmm1
    mulss   xmm3, xmm2                  # b1
    mulss   xmm1, xmm2                  # b2
    movss   xmm0, [rip+gz_one]
    subss   xmm0, xmm2                  # b0
    lea     eax, [r14+rbx]
    lea     rax, [rax+rax*2]
    shl     rax, 2
    mov     rdx, [rip+gd_out]
    mov     rdi, [rdx+ME_POS]
    add     rdi, rax
    mov     rsi, [rdx+ME_PNRM]
    add     rsi, rax
    xor     ecx, ecx
1:  movss   xmm4, [rsp+rcx*4]
    mulss   xmm4, xmm0
    movss   xmm5, [rsp+12+rcx*4]
    mulss   xmm5, xmm3
    addss   xmm4, xmm5
    movss   xmm5, [rsp+24+rcx*4]
    mulss   xmm5, xmm1
    addss   xmm4, xmm5
    movss   [rdi+rcx*4], xmm4
    mov     eax, [rsp+48+rcx*4]
    mov     [rsi+rcx*4], eax
    inc     ecx
    cmp     ecx, 3
    jb      1b
    inc     ebx
    jmp     .Lgp_pt
.Lgp_next:
    inc     r12d
    jmp     .Lgp_tri
.Lgp_out:
    add     rsp, 88
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# gd_thin(rdi=points mesh; [r12+ND_P+8] = the distance) - points closer than
#   it to one kept earlier dropped (a grid of cells that size, a hash table)
gd_thin:
    push    rbx
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 48
    mov     rbx, rdi
    movss   xmm0, [r12+ND_P+8]
    movss   [rsp], xmm0                 # d
    mulss   xmm0, xmm0
    movss   [rsp+4], xmm0               # d^2
    movss   xmm0, [rip+gz_one]
    divss   xmm0, [rsp]
    movss   [rsp+8], xmm0               # 1 / d
    mov     ebp, [rbx+ME_NVERTS]
    lea     edi, [rbp*2+16]             # table: 2n buckets (power of two)
    mov     eax, 1
1:  cmp     eax, edi
    jae     2f
    shl     eax, 1
    jmp     1b
2:  mov     [rsp+12], eax               # buckets
    lea     edi, [rax*4+16]
    call    gn_fa
    test    rax, rax
    jz      9f
    mov     r13, rax                    # heads (-1)
    mov     rdi, rax
    mov     ecx, [rsp+12]
    mov     eax, -1
    rep     stosd
    lea     edi, [rbp*4+16]
    call    gn_fa
    test    rax, rax
    jz      9f
    mov     r14, rax                    # next in bucket
    xor     r15d, r15d                  # kept
    xor     ecx, ecx                    # each point in order
.Lgt_pt:
    cmp     ecx, ebp
    jae     .Lgt_done
    mov     [rsp+16], ecx
    lea     rax, [rcx+rcx*2]
    shl     rax, 2
    add     rax, [rbx+ME_POS]
    mov     [rsp+40], rax
    xor     edx, edx                    # its cell
3:  movss   xmm0, [rax+rdx*4]
    mulss   xmm0, [rsp+8]
    roundss xmm0, xmm0, 1
    cvttss2si r8d, xmm0
    mov     [rsp+20+rdx*4], r8d
    inc     edx
    cmp     edx, 3
    jb      3b
    mov     dword ptr [rsp+32], -1      # the 27 cells around: anyone near?
.Lgt_cell:
    inc     dword ptr [rsp+32]
    mov     eax, [rsp+32]
    cmp     eax, 27
    jae     .Lgt_keep
    xor     edx, edx
    mov     ecx, 3
    div     ecx
    lea     r8d, [rdx-1]
    xor     edx, edx
    div     ecx
    lea     r9d, [rdx-1]
    lea     r10d, [rax-1]
    add     r8d, [rsp+20]
    add     r9d, [rsp+24]
    add     r10d, [rsp+28]
    call    gt_bucket                   # eax = bucket
    mov     eax, [r13+rax*4]
.Lgt_walk:
    test    eax, eax
    js      .Lgt_cell
    lea     rdx, [rax+rax*2]
    shl     rdx, 2
    add     rdx, [rbx+ME_POS]
    mov     rcx, [rsp+40]
    movss   xmm0, [rdx]
    subss   xmm0, [rcx]
    mulss   xmm0, xmm0
    movss   xmm1, [rdx+4]
    subss   xmm1, [rcx+4]
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    movss   xmm1, [rdx+8]
    subss   xmm1, [rcx+8]
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    comiss  xmm0, [rsp+4]
    jb      .Lgt_drop
    mov     eax, [r14+rax*4]
    jmp     .Lgt_walk
.Lgt_keep:                              # kept: moved down to r15, in its cell
    mov     ecx, [rsp+16]
    lea     rsi, [rcx+rcx*2]
    shl     rsi, 2
    lea     rdi, [r15+r15*2]
    shl     rdi, 2
    mov     rax, [rbx+ME_POS]
    mov     rdx, [rax+rsi]
    mov     [rax+rdi], rdx
    mov     edx, [rax+rsi+8]
    mov     [rax+rdi+8], edx
    mov     rax, [rbx+ME_PNRM]
    mov     rdx, [rax+rsi]
    mov     [rax+rdi], rdx
    mov     edx, [rax+rsi+8]
    mov     [rax+rdi+8], edx
    mov     r8d, [rsp+20]
    mov     r9d, [rsp+24]
    mov     r10d, [rsp+28]
    call    gt_bucket
    mov     edx, [r13+rax*4]
    mov     [r14+r15*4], edx
    mov     [r13+rax*4], r15d
    mov     rax, [rbx+ME_POS]           # (the kept copy is the one tested:
    lea     rdi, [r15+r15*2]            #  positions at r15 now)
    shl     rdi, 2
    add     rdi, rax
    inc     r15d
.Lgt_drop:
    mov     ecx, [rsp+16]
    inc     ecx
    jmp     .Lgt_pt
.Lgt_done:
    mov     [rbx+ME_NVERTS], r15d
9:  add     rsp, 48
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     rbx
    ret

# gt_bucket(r8d, r9d, r10d = cell; [rsp+8+12] of gd_thin = buckets) -> eax
gt_bucket:
    imul    eax, r8d, 0x8da6b343
    imul    edx, r9d, 0xd8163841
    xor     eax, edx
    imul    edx, r10d, 0xcb1ab31f
    xor     eax, edx
    mov     edx, [rsp+8+12]
    dec     edx
    and     eax, edx
    ret

# gn_instance(rdi=points, rsi=instance mesh, edx=node, rcx=node record) ->
#   rax = a new mesh with no geometry of its own and an instance of the
#   mesh at every point, or 0
gn_instance:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 32
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13d, edx
    mov     r14, rcx
    mov     [rip+gi_pts], rbx
    cvttss2si eax, [r14+ND_P]
    mov     [rip+gi_rot], eax
    cvttss2si eax, [r14+ND_P+4]
    mov     [rip+gi_align], eax
    cvttss2si eax, [r14+ND_P+8]
    mov     [rip+gi_seed], eax
    mov     rdi, rbx                    # the scale field (input 3)
    mov     esi, r13d
    mov     edx, 2
    mov     ecx, -1
    lea     r8, [rsp]
    call    gn_fields
    test    eax, eax
    jz      8f
    mov     rax, [rsp]
    mov     [rip+gi_scale], rax
    mov     edi, [rbx+ME_NVERTS]        # the block
    call    inst_new
    test    rax, rax
    jz      8f
    mov     r15, rax
    mov     [rip+gi_ib], rax
    mov     ecx, [rbx+ME_NVERTS]
    mov     [r15+4], ecx                # (its count)
    mov     rdi, r15
    mov     rsi, r12
    call    inst_proto
    lea     rdi, [rip+gi_job]
    xor     esi, esi
    mov     edx, [rbx+ME_NVERTS]
    mov     ecx, 4096
    call    parallel_for
    mov     edi, 8                      # the mesh carrying them
    mov     esi, 8
    mov     edx, 2
    call    mesh_new
    test    rax, rax
    jz      7f
    mov     [rax+ME_INST], r15
    push    rax
    push    rax
    mov     rdi, rax
    call    mesh_finish
    pop     rax
    pop     rax
    jmp     9f
7:  mov     rdi, r15
    call    inst_unref
8:  xor     eax, eax
9:  add     rsp, 32
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# gi_job(esi, edx) - each point's matrix: an up axis (the point's normal,
#   or Y), turned about it (random: by the seed), scaled, at the point
gi_job:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 96
    mov     r12d, esi
    mov     r13d, edx
    mov     rdi, [rip+gi_ib]
    call    inst_mats
    mov     r14, rax
    mov     rbx, [rip+gi_pts]
.Lgj_pt:
    cmp     r12d, r13d
    jae     .Lgj_out
    xorps   xmm0, xmm0                  # up: Y, or the normal
    movss   [rsp], xmm0
    movss   [rsp+8], xmm0
    movss   xmm0, [rip+gz_one]
    movss   [rsp+4], xmm0
    cmp     dword ptr [rip+gi_align], 0
    je      2f
    mov     rax, [rbx+ME_PNRM]
    test    rax, rax
    jz      2f
    lea     ecx, [r12+r12*2]
    lea     rax, [rax+rcx*4]
    movss   xmm0, [rax]                 # (a zero normal: Y)
    mulss   xmm0, xmm0
    movss   xmm1, [rax+4]
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    movss   xmm1, [rax+8]
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    comiss  xmm0, [rip+gz_tiny]
    jbe     2f
    mov     rcx, [rax]
    mov     [rsp], rcx
    mov     ecx, [rax+8]
    mov     [rsp+8], ecx
2:  # a side axis: perpendicular to up (x of a = x if up isn't near x)
    movss   xmm0, [rsp]
    andps   xmm0, [rip+gz_abs]
    comiss  xmm0, [rip+gz_half]
    jae     21f
    xorps   xmm0, xmm0                  # s = (1 0 0) x up = (0, -uz, uy)
    movss   [rsp+16], xmm0
    xorps   xmm0, xmm0
    subss   xmm0, [rsp+8]
    movss   [rsp+20], xmm0
    mov     eax, [rsp+4]
    mov     [rsp+24], eax
    jmp     22f
21: movss   xmm0, [rsp+8]               # s = (0 0 1) x up = (-uy, ux, 0)
    xorps   xmm0, xmm0
    subss   xmm0, [rsp+4]
    movss   [rsp+16], xmm0
    mov     eax, [rsp]
    mov     [rsp+20], eax
    mov     dword ptr [rsp+24], 0
22: lea     rdi, [rsp+16]
    call    gz_unit
    # t = up x s
    movss   xmm0, [rsp+4]
    mulss   xmm0, [rsp+24]
    movss   xmm1, [rsp+8]
    mulss   xmm1, [rsp+20]
    subss   xmm0, xmm1
    movss   [rsp+32], xmm0
    movss   xmm0, [rsp+8]
    mulss   xmm0, [rsp+16]
    movss   xmm1, [rsp]
    mulss   xmm1, [rsp+24]
    subss   xmm0, xmm1
    movss   [rsp+36], xmm0
    movss   xmm0, [rsp]
    mulss   xmm0, [rsp+20]
    movss   xmm1, [rsp+4]
    mulss   xmm1, [rsp+16]
    subss   xmm0, xmm1
    movss   [rsp+40], xmm0
    lea     rdi, [rsp]
    call    gz_unit
    lea     rdi, [rsp+32]
    call    gz_unit
    # a turn about up: angle 0, or random
    xorps   xmm0, xmm0
    cmp     dword ptr [rip+gi_rot], 0
    je      3f
    mov     edi, r12d
    mov     esi, [rip+gi_seed]
    mov     edx, 0x7a11
    call    gn_u01
    mulss   xmm0, [rip+gz_2pi]
3:  call    sincos                      # s' = s c + t s, t' = t c - s s
    movss   [rsp+48], xmm0
    movss   [rsp+52], xmm1
    xor     ecx, ecx
4:  movss   xmm2, [rsp+16+rcx*4]
    mulss   xmm2, [rsp+52]
    movss   xmm3, [rsp+32+rcx*4]
    mulss   xmm3, [rsp+48]
    addss   xmm2, xmm3
    movss   xmm3, [rsp+32+rcx*4]
    mulss   xmm3, [rsp+52]
    movss   xmm4, [rsp+16+rcx*4]
    mulss   xmm4, [rsp+48]
    subss   xmm3, xmm4
    movss   [rsp+64+rcx*4], xmm2        # x axis
    movss   [rsp+80+rcx*4], xmm3        # z axis
    inc     ecx
    cmp     ecx, 3
    jb      4b
    mov     rax, [rip+gi_scale]         # scale, the point
    movss   xmm5, [rax+r12*4]
    imul    eax, r12d, 48
    lea     rdi, [r14+rax]
    lea     ecx, [r12+r12*2]
    shl     rcx, 2
    add     rcx, [rbx+ME_POS]
    xor     edx, edx                    # rows: (x z? ) M[r] = (X[r] Y[r] Z[r]) s, p[r]
5:  movss   xmm0, [rsp+64+rdx*4]
    mulss   xmm0, xmm5
    movss   [rdi], xmm0
    movss   xmm0, [rsp+rdx*4]
    mulss   xmm0, xmm5
    movss   [rdi+4], xmm0
    movss   xmm0, [rsp+80+rdx*4]
    mulss   xmm0, xmm5
    movss   [rdi+8], xmm0
    mov     eax, [rcx+rdx*4]
    mov     [rdi+12], eax
    add     rdi, 16
    inc     edx
    cmp     edx, 3
    jb      5b
    inc     r12d
    jmp     .Lgj_pt
.Lgj_out:
    add     rsp, 96
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# gz_unit(rdi=float[3]) - normalized
gz_unit:
    movss   xmm0, [rdi]
    mulss   xmm0, xmm0
    movss   xmm1, [rdi+4]
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    movss   xmm1, [rdi+8]
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    sqrtss  xmm0, xmm0
    maxss   xmm0, [rip+gz_tiny]
    movss   xmm1, [rip+gz_one]
    divss   xmm1, xmm0
    movss   xmm0, [rdi]
    mulss   xmm0, xmm1
    movss   [rdi], xmm0
    movss   xmm0, [rdi+4]
    mulss   xmm0, xmm1
    movss   [rdi+4], xmm0
    movss   xmm0, [rdi+8]
    mulss   xmm0, xmm1
    movss   [rdi+8], xmm0
    ret

.section .rodata
.align 16
gz_abs:         .long 0x7fffffff, 0, 0, 0
.text

# gn_matrix(rdi=out float[12] rows (3x3 | t), rsi=transform node) - R(z)
#   R(y) R(x) S, then T (inputs: translation 2, scale 3; values: degrees)
gn_matrix:
    push    rbx
    push    r12
    sub     rsp, 72
    mov     rbx, rdi
    mov     r12, rsi
    xor     ecx, ecx                    # sin / cos of the three angles
1:  movss   xmm0, [r12+ND_P+rcx*4]
    mulss   xmm0, [rip+gz_deg]
    push    rcx
    push    rcx
    call    sincos
    pop     rcx
    pop     rcx
    movss   [rsp+rcx*8], xmm0           # sin at 0 8 16, cos at 4 12 20
    movss   [rsp+rcx*8+4], xmm1
    inc     ecx
    cmp     ecx, 3
    jb      1b
    # R = Rz Ry Rx: rows
    # r00 = cy cz, r01 = sx sy cz - cx sz, r02 = cx sy cz + sx sz
    # r10 = cy sz, r11 = sx sy sz + cx cz, r12 = cx sy sz - sx cz
    # r20 = -sy,   r21 = sx cy,            r22 = cx cy
    movss   xmm0, [rsp]                 # sx
    movss   xmm1, [rsp+4]               # cx
    movss   xmm2, [rsp+8]               # sy
    movss   xmm3, [rsp+12]              # cy
    movss   xmm4, [rsp+16]              # sz
    movss   xmm5, [rsp+20]              # cz
    movss   xmm6, xmm3
    mulss   xmm6, xmm5
    movss   [rbx], xmm6                 # r00
    movss   xmm6, xmm0
    mulss   xmm6, xmm2
    mulss   xmm6, xmm5
    movss   xmm7, xmm1
    mulss   xmm7, xmm4
    subss   xmm6, xmm7
    movss   [rbx+4], xmm6               # r01
    movss   xmm6, xmm1
    mulss   xmm6, xmm2
    mulss   xmm6, xmm5
    movss   xmm7, xmm0
    mulss   xmm7, xmm4
    addss   xmm6, xmm7
    movss   [rbx+8], xmm6               # r02
    movss   xmm6, xmm3
    mulss   xmm6, xmm4
    movss   [rbx+16], xmm6              # r10
    movss   xmm6, xmm0
    mulss   xmm6, xmm2
    mulss   xmm6, xmm4
    movss   xmm7, xmm1
    mulss   xmm7, xmm5
    addss   xmm6, xmm7
    movss   [rbx+20], xmm6              # r11
    movss   xmm6, xmm1
    mulss   xmm6, xmm2
    mulss   xmm6, xmm4
    movss   xmm7, xmm0
    mulss   xmm7, xmm5
    subss   xmm6, xmm7
    movss   [rbx+24], xmm6              # r12
    xorps   xmm6, xmm6
    subss   xmm6, xmm2
    movss   [rbx+32], xmm6              # r20
    movss   xmm6, xmm0
    mulss   xmm6, xmm3
    movss   [rbx+36], xmm6              # r21
    movss   xmm6, xmm1
    mulss   xmm6, xmm3
    movss   [rbx+40], xmm6              # r22
    xor     ecx, ecx                    # columns x scale; t
2:  movss   xmm0, [r12+ND_IN+32+4]      # scale x (input 3)
    mulss   xmm0, [rbx+rcx]
    movss   [rbx+rcx], xmm0
    movss   xmm0, [r12+ND_IN+32+8]
    mulss   xmm0, [rbx+rcx+4]
    movss   [rbx+rcx+4], xmm0
    movss   xmm0, [r12+ND_IN+32+12]
    mulss   xmm0, [rbx+rcx+8]
    movss   [rbx+rcx+8], xmm0
    mov     eax, ecx                    # translation (input 2)
    shr     eax, 2
    movss   xmm0, [r12+ND_IN+16+4+rax]
    movss   [rbx+rcx+12], xmm0
    add     ecx, 16
    cmp     ecx, 48
    jb      2b
    add     rsp, 72
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Fields
# =============================================================================
# gn_fields(rdi=mesh, esi=node, edx=value input (0..2, or -1), ecx=vector
#   input (or -1), r8=out: 4 pointers - the value per point, then x y z)
#   -> eax = 1 (arrays in the frame arena)
gn_fields:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 24
    mov     rbx, rdi
    mov     r12d, esi
    mov     r13d, edx
    mov     r14d, ecx
    mov     r15, r8
    lea     rdi, [rip+gc_regs]          # a fresh program
    xor     eax, eax
    mov     ecx, NT_MAXN*9*GN_LEVELS
    rep     stosb
    mov     dword ptr [rip+gc_n], 0
    mov     dword ptr [rip+gc_r], 0
    mov     dword ptr [rip+gc_bad], 0
    mov     dword ptr [rip+gc_uses], 0
    mov     dword ptr [rip+fv_ctx+FC_NOUT], 0
    mov     ebp, [rbx+ME_NVERTS]
    mov     edi, ebp                    # the outputs
    shl     edi, 4
    add     edi, 64
    call    gn_fa
    test    rax, rax
    jz      8f
    mov     [r15], rax
    lea     rcx, [rax+rbp*4]
    mov     [r15+8], rcx
    lea     rcx, [rcx+rbp*4]
    mov     [r15+16], rcx
    lea     rcx, [rcx+rbp*4]
    mov     [r15+24], rcx
    test    r13d, r13d                  # the value
    js      1f
    mov     edi, r12d
    mov     esi, r13d
    mov     edx, 1
    call    gc_input
    mov     edi, [rip+gc_out]
    mov     rsi, [r15]
    call    gc_emit_out
1:  test    r14d, r14d                  # the vector
    js      2f
    mov     edi, r12d
    mov     esi, r14d
    mov     edx, 2
    call    gc_input
    mov     eax, [rip+gc_out]
    mov     [rsp], eax
    mov     eax, [rip+gc_out+4]
    mov     [rsp+4], eax
    mov     eax, [rip+gc_out+8]
    mov     [rsp+8], eax
    mov     edi, [rsp]
    mov     rsi, [r15+8]
    call    gc_emit_out
    mov     edi, [rsp+4]
    mov     rsi, [r15+16]
    call    gc_emit_out
    mov     edi, [rsp+8]
    mov     rsi, [r15+24]
    call    gc_emit_out
2:  cmp     dword ptr [rip+gc_bad], 0
    jne     8f
    mov     rdi, rbx                    # the inputs it reads
    call    gn_inputs
    test    eax, eax
    jz      8f
    mov     [rip+fv_ctx+FC_N], ebp
    lea     rax, [rip+gc_prog]
    mov     [rip+fv_ctx+FC_PROG], rax
    mov     eax, [rip+gc_n]
    mov     [rip+fv_ctx+FC_NINS], eax
    call    fv_run
    mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 24
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# gn_fa(edi=bytes) -> rax = frame arena memory (16-byte aligned) or 0
gn_fa:
    mov     esi, edi
    lea     rdi, [rip+frame_arena]
    jmp     arena_alloc

# gc_emit_out(edi=register, rsi=array) - a result of the program
gc_emit_out:
    mov     eax, [rip+fv_ctx+FC_NOUT]
    cmp     eax, 8
    jae     9f
    shl     eax, 4
    lea     rcx, [rip+fv_ctx+FC_OUT]
    mov     [rcx+rax], edi
    mov     [rcx+rax+8], rsi
    inc     dword ptr [rip+fv_ctx+FC_NOUT]
9:  ret

# gn_inputs(rdi=mesh) -> eax = 1: the point arrays the program reads (SoA:
#   position, vertex normals, index)
gn_inputs:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    lea     rdi, [rip+fv_ctx+FC_IN]
    xor     eax, eax
    mov     ecx, 7
    rep     stosq
    mov     r12d, [rbx+ME_NVERTS]
    mov     edi, r12d                   # 7 arrays
    imul    edi, edi, 28
    add     edi, 128
    call    gn_fa
    test    rax, rax
    jz      8f
    mov     r13, rax
    xor     ecx, ecx
1:  cmp     ecx, 7
    jae     2f
    mov     eax, r12d
    imul    eax, ecx
    lea     rax, [r13+rax*4]
    lea     rdx, [rip+fv_ctx+FC_IN]
    mov     [rdx+rcx*8], rax
    inc     ecx
    jmp     1b
2:  mov     rsi, [rbx+ME_POS]           # positions, index
    mov     r8, [rip+fv_ctx+FC_IN]
    mov     r9, [rip+fv_ctx+FC_IN+8]
    mov     r10, [rip+fv_ctx+FC_IN+16]
    mov     r11, [rip+fv_ctx+FC_IN+48]
    xor     ecx, ecx
3:  cmp     ecx, r12d
    jae     4f
    mov     eax, [rsi]
    mov     [r8+rcx*4], eax
    mov     eax, [rsi+4]
    mov     [r9+rcx*4], eax
    mov     eax, [rsi+8]
    mov     [r10+rcx*4], eax
    cvtsi2ss xmm0, ecx
    movss   [r11+rcx*4], xmm0
    add     rsi, 12
    inc     ecx
    jmp     3b
4:  test    dword ptr [rip+gc_uses], 2  # normals: when read (points: their
    jz      7f                          #  own)
    cmp     qword ptr [rbx+ME_PNRM], 0
    jne     5f
    mov     rdi, rbx
    call    gn_vnormals
    jmp     7f
5:  mov     rsi, [rbx+ME_PNRM]
    mov     r8, [rip+fv_ctx+FC_IN+24]
    mov     r9, [rip+fv_ctx+FC_IN+32]
    mov     r10, [rip+fv_ctx+FC_IN+40]
    xor     ecx, ecx
6:  cmp     ecx, [rbx+ME_NVERTS]
    jae     7f
    mov     eax, [rsi]
    mov     [r8+rcx*4], eax
    mov     eax, [rsi+4]
    mov     [r9+rcx*4], eax
    mov     eax, [rsi+8]
    mov     [r10+rcx*4], eax
    add     rsi, 12
    inc     ecx
    jmp     6b
7:  mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# gn_vnormals(rdi=mesh) - fv_ctx's normal arrays: each point's polygons'
#   (Newell) normals summed, unit
gn_vnormals:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 24
    mov     rbx, rdi
    mov     r13, [rip+fv_ctx+FC_IN+24]  # nx ny nz (zeroed: frame arena is
    mov     r14, [rip+fv_ctx+FC_IN+32]  #  not, so clear)
    mov     r15, [rip+fv_ctx+FC_IN+40]
    mov     ecx, [rbx+ME_NVERTS]
    mov     rdi, r13
    xor     eax, eax
    rep     stosd
    mov     ecx, [rbx+ME_NVERTS]
    mov     rdi, r14
    rep     stosd
    mov     ecx, [rbx+ME_NVERTS]
    mov     rdi, r15
    rep     stosd
    xor     r12d, r12d                  # polygons
1:  cmp     r12d, [rbx+ME_NPOLYS]
    jae     5f
    mov     rax, [rbx+ME_POFF]
    mov     ecx, [rax+r12*4]
    mov     edx, [rax+r12*4+4]
    mov     [rsp], ecx
    mov     [rsp+4], edx
    xorps   xmm3, xmm3                  # Newell sums
    xorps   xmm4, xmm4
    xorps   xmm5, xmm5
    mov     rsi, [rbx+ME_LOOPS]
    mov     rdi, [rbx+ME_POS]
2:  cmp     ecx, edx
    jae     3f
    mov     eax, [rsi+rcx*4]            # this and the next corner
    lea     r8d, [rcx+1]
    cmp     r8d, edx
    jb      21f
    mov     r8d, [rsp]
21: mov     r8d, [rsi+r8*4]
    lea     rax, [rax+rax*2]
    lea     r8, [r8+r8*2]
    movss   xmm0, [rdi+rax*4+4]         # nx += (yi - yj)(zi + zj)
    subss   xmm0, [rdi+r8*4+4]
    movss   xmm1, [rdi+rax*4+8]
    addss   xmm1, [rdi+r8*4+8]
    mulss   xmm0, xmm1
    addss   xmm3, xmm0
    movss   xmm0, [rdi+rax*4+8]         # ny += (zi - zj)(xi + xj)
    subss   xmm0, [rdi+r8*4+8]
    movss   xmm1, [rdi+rax*4]
    addss   xmm1, [rdi+r8*4]
    mulss   xmm0, xmm1
    addss   xmm4, xmm0
    movss   xmm0, [rdi+rax*4]           # nz += (xi - xj)(yi + yj)
    subss   xmm0, [rdi+r8*4]
    movss   xmm1, [rdi+rax*4+4]
    addss   xmm1, [rdi+r8*4+4]
    mulss   xmm0, xmm1
    addss   xmm5, xmm0
    inc     ecx
    jmp     2b
3:  mov     ecx, [rsp]                  # onto its points
31: cmp     ecx, [rsp+4]
    jae     4f
    mov     eax, [rsi+rcx*4]
    movss   xmm0, [r13+rax*4]
    addss   xmm0, xmm3
    movss   [r13+rax*4], xmm0
    movss   xmm0, [r14+rax*4]
    addss   xmm0, xmm4
    movss   [r14+rax*4], xmm0
    movss   xmm0, [r15+rax*4]
    addss   xmm0, xmm5
    movss   [r15+rax*4], xmm0
    inc     ecx
    jmp     31b
4:  inc     r12d
    jmp     1b
5:  xor     ecx, ecx                    # unit
6:  cmp     ecx, [rbx+ME_NVERTS]
    jae     9f
    movss   xmm0, [r13+rcx*4]
    mulss   xmm0, xmm0
    movss   xmm1, [r14+rcx*4]
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    movss   xmm1, [r15+rcx*4]
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    sqrtss  xmm0, xmm0
    maxss   xmm0, [rip+gz_tiny]
    movss   xmm1, [rip+gz_one]
    divss   xmm1, xmm0
    movss   xmm0, [r13+rcx*4]
    mulss   xmm0, xmm1
    movss   [r13+rcx*4], xmm0
    movss   xmm0, [r14+rcx*4]
    mulss   xmm0, xmm1
    movss   [r14+rcx*4], xmm0
    movss   xmm0, [r15+rcx*4]
    mulss   xmm0, xmm1
    movss   [r15+rcx*4], xmm0
    inc     ecx
    jmp     6b
9:  add     rsp, 24
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# gc_reg -> eax = a new register (gc_bad when out of them)
gc_reg:
    mov     eax, [rip+gc_r]
    cmp     eax, GC_MAXR
    jb      1f
    mov     dword ptr [rip+gc_bad], 1
    xor     eax, eax
    ret
1:  inc     dword ptr [rip+gc_r]
    ret

# gc_ins(edi=op, esi=dst, edx=a, ecx=b, r8d=c, xmm0..3 = immediates)
gc_ins:
    mov     eax, [rip+gc_n]
    cmp     eax, GC_MAXI
    jb      1f
    mov     dword ptr [rip+gc_bad], 1
    ret
1:  imul    eax, eax, IN_SZ
    lea     r9, [rip+gc_prog]
    add     r9, rax
    mov     [r9], dil
    mov     [r9+1], sil
    mov     [r9+2], dl
    mov     [r9+3], cl
    mov     [r9+4], r8b
    movss   [r9+8], xmm0
    movss   [r9+12], xmm1
    movss   [r9+16], xmm2
    movss   [r9+20], xmm3
    inc     dword ptr [rip+gc_n]
    ret

# gc_op(edi=op, esi=a, edx=b) -> eax = dst (a new register)
gc_op:
    push    rbx
    push    r12
    push    r13
    mov     r12d, edi
    mov     r13d, esi
    mov     ebx, edx
    call    gc_reg
    push    rax
    push    rax
    mov     edi, r12d
    mov     esi, eax
    mov     edx, r13d
    mov     ecx, ebx
    xor     r8d, r8d
    xorps   xmm0, xmm0
    xorps   xmm1, xmm1
    xorps   xmm2, xmm2
    xorps   xmm3, xmm3
    call    gc_ins
    pop     rax
    pop     rax
    pop     r13
    pop     r12
    pop     rbx
    ret

# gc_const(xmm0) -> eax = a register holding it
gc_const:
    sub     rsp, 24
    movss   [rsp], xmm0
    call    gc_reg
    mov     [rsp+8], eax
    mov     edi, OP_CONST
    mov     esi, eax
    xor     edx, edx
    xor     ecx, ecx
    xor     r8d, r8d
    movss   xmm0, [rsp]
    xorps   xmm1, xmm1
    xorps   xmm2, xmm2
    xorps   xmm3, xmm3
    call    gc_ins
    mov     eax, [rsp+8]
    add     rsp, 24
    ret

# gc_input(edi=node 1.., esi=input 0..2, edx=kind wanted 1 value / 2
#   vector) -> gc_out = its registers (value: [0]; vector: [0..2])
gc_input:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    mov     r12d, edi
    mov     r13d, esi
    mov     r14d, edx
    mov     rbx, [rip+gn_rec]
    lea     eax, [r12-1]
    imul    eax, eax, NODE_SZ
    lea     r15, [rbx+GR_NODES+rax]
    mov     eax, r13d
    shl     eax, 4
    mov     ecx, [r15+ND_IN+rax]
    movzx   edi, cx
    test    edi, edi
    jz      .Lgi_const
    cmp     edi, [rbx+GR_N]
    ja      .Lgi_const
    cmp     dword ptr [rip+gc_depth], 64    # (a loop: never, but bounded)
    jae     .Lgi_const
    shr     ecx, 16                     # the output
    and     ecx, 0xff
    mov     esi, ecx
    inc     dword ptr [rip+gc_depth]
    call    gc_out_of                   # gc_out, eax = its kind
    dec     dword ptr [rip+gc_depth]
    cmp     eax, r14d
    je      .Lgi_out
    cmp     r14d, 2                     # value -> vector: (v, v, v)
    jne     1f
    mov     eax, [rip+gc_out]
    mov     [rip+gc_out+4], eax
    mov     [rip+gc_out+8], eax
    jmp     .Lgi_out
1:  mov     edi, OP_ADD                 # vector -> value: the mean
    mov     esi, [rip+gc_out]
    mov     edx, [rip+gc_out+4]
    call    gc_op
    mov     edi, OP_ADD
    mov     esi, eax
    mov     edx, [rip+gc_out+8]
    call    gc_op
    mov     [rsp], eax
    movss   xmm0, [rip+gz_third]
    call    gc_const
    mov     edi, OP_MUL
    mov     esi, [rsp]
    mov     edx, eax
    call    gc_op
    mov     [rip+gc_out], eax
    jmp     .Lgi_out
.Lgi_const:                             # unlinked: the constant (noise and
    cmp     dword ptr [r15+ND_TYPE], T_NOISE    #  its vector: the position)
    jne     2f
    test    r13d, r13d
    jnz     2f
    or      dword ptr [rip+gc_uses], 1
    mov     edi, OP_PX
    call    gc_load
    mov     [rip+gc_out], eax
    mov     edi, OP_PX+1
    call    gc_load
    mov     [rip+gc_out+4], eax
    mov     edi, OP_PX+2
    call    gc_load
    mov     [rip+gc_out+8], eax
    jmp     .Lgi_out
2:  mov     eax, r13d
    shl     eax, 4
    movss   xmm0, [r15+ND_IN+rax+4]
    call    gc_const
    mov     [rip+gc_out], eax
    cmp     r14d, 2
    jne     .Lgi_out
    mov     eax, r13d
    shl     eax, 4
    movss   xmm0, [r15+ND_IN+rax+8]
    call    gc_const
    mov     [rip+gc_out+4], eax
    mov     eax, r13d
    shl     eax, 4
    movss   xmm0, [r15+ND_IN+rax+12]
    call    gc_const
    mov     [rip+gc_out+8], eax
.Lgi_out:
    add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# gc_load(edi=load op) -> eax = a register with that input
gc_load:
    push    rbx
    mov     ebx, edi
    call    gc_reg
    push    rax
    mov     edi, ebx
    mov     esi, eax
    xor     edx, edx
    xor     ecx, ecx
    xor     r8d, r8d
    xorps   xmm0, xmm0
    xorps   xmm1, xmm1
    xorps   xmm2, xmm2
    xorps   xmm3, xmm3
    call    gc_ins
    pop     rax
    pop     rbx
    ret

# gc_out_of(edi=node 1.., esi=output) -> gc_out = its registers, eax = kind
#   (1 value, 2 vector); compiled once
gc_out_of:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 56
    mov     r12d, edi
    mov     r13d, esi
    cmp     r13d, 2
    jbe     1f
    xor     r13d, r13d
1:  lea     eax, [r12-1]                # compiled already? (this level's)
    imul    eax, eax, 9
    lea     ecx, [r13+r13*2]
    add     eax, ecx
    mov     ecx, [rip+gn_level]
    imul    ecx, ecx, NT_MAXN*9
    add     eax, ecx
    lea     r14, [rip+gc_regs]
    add     r14, rax                    # its three slots
    movzx   eax, byte ptr [r14]
    test    eax, eax
    jz      2f
    dec     eax
    mov     [rip+gc_out], eax
    movzx   ecx, byte ptr [r14+1]
    test    ecx, ecx
    jz      11f
    dec     ecx
    mov     [rip+gc_out+4], ecx
    movzx   ecx, byte ptr [r14+2]
    dec     ecx
    mov     [rip+gc_out+8], ecx
    mov     eax, 2
    jmp     .Lgo_ret
11: mov     eax, 1
    jmp     .Lgo_ret
2:  mov     rbx, [rip+gn_rec]
    lea     eax, [r12-1]
    imul    eax, eax, NODE_SZ
    lea     r15, [rbx+GR_NODES+rax]
    mov     eax, [r15+ND_TYPE]
    cmp     eax, T_POS
    je      .Lgo_pos
    cmp     eax, T_NORMAL
    je      .Lgo_normal
    cmp     eax, T_INDEX
    je      .Lgo_index
    cmp     eax, T_VALUE
    je      .Lgo_value
    cmp     eax, T_COMBINE
    je      .Lgo_combine
    cmp     eax, T_SEP
    je      .Lgo_sep
    cmp     eax, T_MATH
    je      .Lgo_math
    cmp     eax, T_VMATH
    je      .Lgo_vmath
    cmp     eax, T_NOISE
    je      .Lgo_noise
    cmp     eax, T_RANDOM
    je      .Lgo_random
    cmp     eax, T_GIN
    je      .Lgo_gin
    xorps   xmm0, xmm0                  # (not a field: 0)
    call    gc_const
    mov     [rip+gc_out], eax
    mov     eax, 1
    jmp     .Lgo_ret                    # (not remembered)
.Lgo_pos:
    or      dword ptr [rip+gc_uses], 1
    mov     ebp, OP_PX
    jmp     3f
.Lgo_normal:
    or      dword ptr [rip+gc_uses], 2
    mov     ebp, OP_NX
3:  mov     edi, ebp
    call    gc_load
    mov     [rsp], eax
    lea     edi, [rbp+1]
    call    gc_load
    mov     [rsp+4], eax
    lea     edi, [rbp+2]
    call    gc_load
    mov     [rsp+8], eax
    jmp     .Lgo_vec
.Lgo_index:
    mov     edi, OP_INDEX
    call    gc_load
    mov     [rsp], eax
    jmp     .Lgo_val
.Lgo_value:
    movss   xmm0, [r15+ND_P]
    call    gc_const
    mov     [rsp], eax
    jmp     .Lgo_val
.Lgo_combine:
    xor     ebp, ebp
4:  mov     edi, r12d
    mov     esi, ebp
    mov     edx, 1
    call    gc_input
    mov     eax, [rip+gc_out]
    mov     [rsp+rbp*4], eax
    inc     ebp
    cmp     ebp, 3
    jb      4b
    jmp     .Lgo_vec
.Lgo_sep:
    mov     edi, r12d
    xor     esi, esi
    mov     edx, 2
    call    gc_input
    lea     rax, [rip+gc_out]
    mov     eax, [rax+r13*4]
    mov     [rsp], eax
    jmp     .Lgo_val
.Lgo_math:
    mov     edi, r12d
    xor     esi, esi
    mov     edx, 1
    call    gc_input
    mov     eax, [rip+gc_out]
    mov     [rsp+16], eax               # a
    mov     edi, r12d
    mov     esi, 1
    mov     edx, 1
    call    gc_input
    mov     eax, [rip+gc_out]
    mov     [rsp+20], eax               # b
    cvttss2si eax, [r15+ND_P]
    cmp     eax, 14
    jbe     5f
    xor     eax, eax
5:  lea     rcx, [rip+gc_mathops]
    movzx   edi, byte ptr [rcx+rax]
    mov     esi, [rsp+16]
    mov     edx, [rsp+20]
    call    gc_op
    mov     [rsp], eax
    jmp     .Lgo_val
.Lgo_vmath:                             # a, b vectors; factor
    mov     edi, r12d
    xor     esi, esi
    mov     edx, 2
    call    gc_input
    lea     rsi, [rip+gc_out]
    mov     rax, [rsi]
    mov     [rsp+16], rax
    mov     eax, [rsi+8]
    mov     [rsp+24], eax               # a at 16..24
    mov     edi, r12d
    mov     esi, 1
    mov     edx, 2
    call    gc_input
    lea     rsi, [rip+gc_out]
    mov     rax, [rsi]
    mov     [rsp+28], rax
    mov     eax, [rsi+8]
    mov     [rsp+36], eax               # b at 28..36
    mov     edi, r12d
    mov     esi, 2
    mov     edx, 1
    call    gc_input
    mov     eax, [rip+gc_out]
    mov     [rsp+40], eax               # factor
    cvttss2si eax, [r15+ND_P]
    cmp     eax, 9
    jbe     6f
    xor     eax, eax
6:  mov     [rsp+44], eax
    call    gc_vmath                    # -> [rsp..8] vector, [rsp+12] value
    cmp     r13d, 1
    je      61f
    jmp     .Lgo_vec2
61: mov     eax, [rsp+12]
    mov     [rsp], eax
    jmp     .Lgo_val
.Lgo_noise:                             # fac: one fbm; colour: three
    mov     edi, r12d
    xor     esi, esi
    mov     edx, 2
    call    gc_input
    lea     rsi, [rip+gc_out]
    mov     rax, [rsi]
    mov     [rsp+16], rax
    mov     eax, [rsi+8]
    mov     [rsp+24], eax
    xor     ebp, ebp
7:  call    gc_reg
    mov     [rsp+rbp*4], eax
    mov     edi, OP_NOISE
    mov     esi, eax
    mov     edx, [rsp+16]
    mov     ecx, [rsp+20]
    mov     r8d, [rsp+24]
    movss   xmm0, [r15+ND_P]
    movss   xmm1, [r15+ND_P+4]
    movss   xmm2, [r15+ND_P+8]
    cvtsi2ss xmm3, ebp
    call    gc_ins
    test    r13d, r13d                  # (fac: the first only)
    jz      .Lgo_val
    inc     ebp
    cmp     ebp, 3
    jb      7b
    jmp     .Lgo_vec
.Lgo_random:
    mov     edi, OP_INDEX
    call    gc_load
    mov     ebx, eax
    call    gc_reg
    mov     [rsp], eax
    mov     edi, OP_RAND
    mov     esi, eax
    mov     edx, ebx
    xor     ecx, ecx
    xor     r8d, r8d
    movss   xmm0, [r15+ND_P+8]          # seed, min, max
    movss   xmm1, [r15+ND_P]
    movss   xmm2, [r15+ND_P+4]
    xorps   xmm3, xmm3
    call    gc_ins
    jmp     .Lgo_val
.Lgo_gin:                               # a group's value / vector: the group
    mov     ecx, [rip+gn_level]         #  node's input, in the outer tree
    test    ecx, ecx
    jz      .Lgo_zero
    test    r13d, r13d
    jz      .Lgo_zero
    dec     ecx
    lea     rax, [rip+gn_ctx_rec]
    mov     rdi, [rax+rcx*8+8]
    lea     rax, [rip+gn_ctx_node]
    mov     edi, [rax+rcx*4+4]
    mov     rax, [rip+gn_rec]
    mov     [rsp+48], rax
    lea     rax, [rip+gn_ctx_rec]
    mov     rax, [rax+rcx*8+8]
    mov     [rip+gn_rec], rax
    dec     dword ptr [rip+gn_level]
    mov     esi, r13d                   # (input 1: value, 2: vector)
    lea     edx, [r13]
    inc     dword ptr [rip+gc_depth]
    call    gc_input
    dec     dword ptr [rip+gc_depth]
    inc     dword ptr [rip+gn_level]
    mov     rax, [rsp+48]
    mov     [rip+gn_rec], rax
    mov     eax, [rip+gc_out]
    mov     [rsp], eax
    cmp     r13d, 1
    je      .Lgo_val
    mov     eax, [rip+gc_out+4]
    mov     [rsp+4], eax
    mov     eax, [rip+gc_out+8]
    mov     [rsp+8], eax
    jmp     .Lgo_vec
.Lgo_zero:
    xorps   xmm0, xmm0
    call    gc_const
    mov     [rsp], eax
    mov     [rsp+4], eax
    mov     [rsp+8], eax
    cmp     r13d, 2
    je      .Lgo_vec
.Lgo_val:
    mov     eax, [rsp]
    mov     [rip+gc_out], eax
    inc     eax
    mov     [r14], al
    mov     eax, 1
    jmp     .Lgo_ret
.Lgo_vec2:
.Lgo_vec:
    mov     eax, [rsp]
    mov     [rip+gc_out], eax
    inc     eax
    mov     [r14], al
    mov     eax, [rsp+4]
    mov     [rip+gc_out+4], eax
    inc     eax
    mov     [r14+1], al
    mov     eax, [rsp+8]
    mov     [rip+gc_out+8], eax
    inc     eax
    mov     [r14+2], al
    mov     eax, 2
.Lgo_ret:
    add     rsp, 56
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.section .rodata
gc_mathops:     .byte OP_ADD, OP_SUB, OP_MUL, OP_DIV, OP_POW, OP_MIN, OP_MAX, OP_LT, OP_GT
                .byte OP_SIN, OP_COS, OP_ABS, OP_SQRT, OP_FLOOR, OP_MOD
.text

# gc_vmath (gc_out_of's frame one level up: a at +16, b at +28, factor at
#   +40, op at +44) -> vector at +0..8, value at +12 of that frame
gc_vmath:
    push    rbx
    push    r12
    lea     rbx, [rsp+24]               # (the caller's rsp)
    mov     eax, [rbx+44]
    cmp     eax, 0
    je      .Lvm_add
    cmp     eax, 1
    je      .Lvm_sub
    cmp     eax, 2
    je      .Lvm_mul
    cmp     eax, 3
    je      .Lvm_scale
    cmp     eax, 4
    je      .Lvm_cross
    cmp     eax, 5
    je      .Lvm_dot
    cmp     eax, 6
    je      .Lvm_length
    cmp     eax, 7
    je      .Lvm_normalize
    cmp     eax, 8
    je      .Lvm_distance
    jmp     .Lvm_mix
.Lvm_add:
    mov     r12d, OP_ADD
    jmp     1f
.Lvm_sub:
    mov     r12d, OP_SUB
    jmp     1f
.Lvm_mul:
    mov     r12d, OP_MUL
1:  xor     ecx, ecx                    # component-wise
2:  push    rcx
    push    rcx
    mov     edi, r12d
    mov     esi, [rbx+16+rcx*4]
    mov     edx, [rbx+28+rcx*4]
    call    gc_op
    pop     rcx
    pop     rcx
    mov     [rbx+rcx*4], eax
    inc     ecx
    cmp     ecx, 3
    jb      2b
    jmp     .Lvm_len_of_result
.Lvm_scale:
    xor     ecx, ecx
3:  push    rcx
    push    rcx
    mov     edi, OP_MUL
    mov     esi, [rbx+16+rcx*4]
    mov     edx, [rbx+40]
    call    gc_op
    pop     rcx
    pop     rcx
    mov     [rbx+rcx*4], eax
    inc     ecx
    cmp     ecx, 3
    jb      3b
    jmp     .Lvm_len_of_result
.Lvm_cross:                             # (ay bz - az by, az bx - ax bz, ax by - ay bx)
    mov     edi, 1
    mov     esi, 2
    call    gc_cross1
    mov     [rbx], eax
    mov     edi, 2
    xor     esi, esi
    call    gc_cross1
    mov     [rbx+4], eax
    xor     edi, edi
    mov     esi, 1
    call    gc_cross1
    mov     [rbx+8], eax
    jmp     .Lvm_len_of_result
.Lvm_dot:
    lea     rdi, [rbx+16]
    lea     rsi, [rbx+28]
    call    gc_dot
    mov     [rbx+12], eax
    jmp     .Lvm_copy_a
.Lvm_length:
    lea     rdi, [rbx+16]
    lea     rsi, [rbx+16]
    call    gc_dot
    mov     edi, OP_SQRT
    mov     esi, eax
    xor     edx, edx
    call    gc_op
    mov     [rbx+12], eax
    jmp     .Lvm_copy_a
.Lvm_normalize:
    lea     rdi, [rbx+16]
    lea     rsi, [rbx+16]
    call    gc_dot
    mov     edi, OP_SQRT
    mov     esi, eax
    xor     edx, edx
    call    gc_op
    mov     [rbx+12], eax
    xor     ecx, ecx
4:  push    rcx
    push    rcx
    mov     edi, OP_DIV
    mov     esi, [rbx+16+rcx*4]
    mov     edx, [rbx+12]
    call    gc_op
    pop     rcx
    pop     rcx
    mov     [rbx+rcx*4], eax
    inc     ecx
    cmp     ecx, 3
    jb      4b
    jmp     9f
.Lvm_distance:
    xor     ecx, ecx
5:  push    rcx
    push    rcx
    mov     edi, OP_SUB
    mov     esi, [rbx+16+rcx*4]
    mov     edx, [rbx+28+rcx*4]
    call    gc_op
    pop     rcx
    pop     rcx
    mov     [rbx+rcx*4], eax
    inc     ecx
    cmp     ecx, 3
    jb      5b
    lea     rdi, [rbx]
    lea     rsi, [rbx]
    call    gc_dot
    mov     edi, OP_SQRT
    mov     esi, eax
    xor     edx, edx
    call    gc_op
    mov     [rbx+12], eax
    jmp     9f
.Lvm_mix:                               # a + (b - a) factor
    xor     ecx, ecx
6:  push    rcx
    push    rcx
    mov     edi, OP_SUB
    mov     esi, [rbx+28+rcx*4]
    mov     edx, [rbx+16+rcx*4]
    call    gc_op
    mov     edi, OP_MUL
    mov     esi, eax
    mov     edx, [rbx+40]
    call    gc_op
    pop     rcx
    pop     rcx
    push    rcx
    push    rcx
    mov     edi, OP_ADD
    mov     esi, [rbx+16+rcx*4]
    mov     edx, eax
    call    gc_op
    pop     rcx
    pop     rcx
    mov     [rbx+rcx*4], eax
    inc     ecx
    cmp     ecx, 3
    jb      6b
.Lvm_len_of_result:                     # the value: the result's length
    lea     rdi, [rbx]
    lea     rsi, [rbx]
    call    gc_dot
    mov     edi, OP_SQRT
    mov     esi, eax
    xor     edx, edx
    call    gc_op
    mov     [rbx+12], eax
    jmp     9f
.Lvm_copy_a:
    mov     rax, [rbx+16]
    mov     [rbx], rax
    mov     eax, [rbx+24]
    mov     [rbx+8], eax
9:  pop     r12
    pop     rbx
    ret

# gc_cross1(edi=i, esi=j; rbx = vmath frame) -> eax = a_i b_j - a_j b_i
gc_cross1:
    push    r12
    push    r13
    push    r14
    mov     r12d, edi
    mov     r13d, esi
    mov     edi, OP_MUL
    mov     esi, [rbx+16+r12*4]
    mov     edx, [rbx+28+r13*4]
    call    gc_op
    mov     r14d, eax
    mov     edi, OP_MUL
    mov     esi, [rbx+16+r13*4]
    mov     edx, [rbx+28+r12*4]
    call    gc_op
    mov     edi, OP_SUB
    mov     esi, r14d
    mov     edx, eax
    call    gc_op
    pop     r14
    pop     r13
    pop     r12
    ret

# gc_dot(rdi=u regs[3], rsi=v regs[3]) -> eax = register of u . v
gc_dot:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12, rsi
    mov     edi, OP_MUL
    mov     esi, [rbx]
    mov     edx, [r12]
    call    gc_op
    mov     r13d, eax
    mov     edi, OP_MUL
    mov     esi, [rbx+4]
    mov     edx, [r12+4]
    call    gc_op
    mov     edi, OP_ADD
    mov     esi, r13d
    mov     edx, eax
    call    gc_op
    mov     r13d, eax
    mov     edi, OP_MUL
    mov     esi, [rbx+8]
    mov     edx, [r12+8]
    call    gc_op
    mov     edi, OP_ADD
    mov     esi, r13d
    mov     edx, eax
    call    gc_op
    pop     r13
    pop     r12
    pop     rbx
    ret

.section .note.GNU-stack,"",@progbits
