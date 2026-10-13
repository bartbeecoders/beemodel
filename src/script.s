# =============================================================================
#  BeeModel - BeeScript: the scripting language of the console, macros and
#  agents. Source -> tokens -> bytecode (one pass, no AST) -> stack VM.
#
#    x = 2m                      numbers carry units: m cm mm km deg rad
#    for i in 0..5 { add("cube", "Box" + i, i * 3, 0, 0) }
#    fn twice(a) { return a * 2 }
#    if count() > 3 { print("busy scene") } else { print(count()) }
#
#  Values are 16 bytes: { type, payload } - nil, number (double) or text.
#  Variables and functions defined at the top level live on between runs
#  (the console is a REPL). A whole run is one undo step.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

# exports
.globl script_eval
.globl script_run_file
.globl script_out
.globl script_out_len
.globl script_src_buf
.globl macro_on
.globl macro_op
.globl macro_select
.globl macro_transform
.globl op_script_record
.globl op_script_run

.equ T_UNSET,   0
.equ T_NIL,     1
.equ T_NUM,     2
.equ T_STR,     3

.equ TK_SZ,     24      # type u32, line u32, len u32, pad, value u64
.equ TOK_MAX,   65536       # a 64 KiB source can never run out
.equ MAIN_CODE, 131072
.equ FN_CODE,   262144
.equ G_MAX,     512
.equ F_MAX,     128
.equ F_SZ,      48      # name[32], code u64 @32, params u8 @40, locals u8 @41
.equ L_MAX,     64
.equ LP_MAX,    16
.equ LP_SZ,     264     # breaks u32, continues u32, brk[16] u64, cont[16] u64
.equ VS_N,      16384
.equ FR_N,      2048
.equ SH_SIZE,   1048576
.equ SRC_MAX,   65536
.equ OUT_MAX,   65536
.equ MAC_MAX,   65536
.equ LN_MAX,    1024
.equ STEP_MAX,  500000000
.equ NEST_MAX,  200

# tokens
.equ TK_EOF, 0
.equ TK_SEP, 1
.equ TK_NUM, 2
.equ TK_STR, 3
.equ TK_NAME, 4
.equ TK_LP, 5
.equ TK_RP, 6
.equ TK_LB, 7
.equ TK_RB, 8
.equ TK_COMMA, 9
.equ TK_ASSIGN, 10
.equ TK_EQ, 11          # == != < <= > >=  (same order as OP_EQ..)
.equ TK_NE, 12
.equ TK_LT, 13
.equ TK_LE, 14
.equ TK_GT, 15
.equ TK_GE, 16
.equ TK_PLUS, 17
.equ TK_MINUS, 18
.equ TK_STAR, 19
.equ TK_SLASH, 20
.equ TK_PCT, 21
.equ TK_DOTDOT, 22
.equ TK_FN, 23
.equ TK_IF, 24
.equ TK_ELSE, 25
.equ TK_WHILE, 26
.equ TK_FOR, 27
.equ TK_IN, 28
.equ TK_RETURN, 29
.equ TK_BREAK, 30
.equ TK_CONTINUE, 31
.equ TK_AND, 32
.equ TK_OR, 33
.equ TK_NOT, 34
.equ TK_TRUE, 35
.equ TK_FALSE, 36
.equ TK_NIL, 37
.equ TK_PI, 38
.equ TK_ADDEQ, 39       # += -= *= /=
.equ TK_SUBEQ, 40
.equ TK_MULEQ, 41
.equ TK_DIVEQ, 42

# opcodes
.equ OP_HALT, 0
.equ OP_LINE, 1         # u16 source line
.equ OP_NUM, 2          # f64
.equ OP_STR, 3          # u16 length, bytes, 0
.equ OP_NIL, 4
.equ OP_GETG, 5         # u16 global
.equ OP_SETG, 6
.equ OP_GETL, 7         # u8 local
.equ OP_SETL, 8
.equ OP_ADD, 9
.equ OP_SUB, 10
.equ OP_MUL, 11
.equ OP_DIV, 12
.equ OP_MOD, 13
.equ OP_NEG, 14
.equ OP_NOT, 15
.equ OP_EQ, 16
.equ OP_NE, 17
.equ OP_LT, 18
.equ OP_LE, 19
.equ OP_GT, 20
.equ OP_GE, 21
.equ OP_JMP, 22         # rel32 (from the end of the operand)
.equ OP_JF, 23          # pop, jump if false
.equ OP_JFK, 24         # jump if false keeping the value, else pop
.equ OP_JTK, 25         # jump if true keeping the value, else pop
.equ OP_CALLB, 26       # u8 builtin, u8 argc
.equ OP_CALLF, 27       # u16 function, u8 argc
.equ OP_RET, 28
.equ OP_POP, 29
.equ OP_POPR, 30        # pop into the result register (REPL echo)
.equ OP_CLRR, 31

.section .bss
.align 16
sd_p:           .skip 32
sd_obj:         .skip OB_SZ
.align 16
toks:           .skip TOK_MAX*TK_SZ
main_code:      .skip MAIN_CODE
fn_code:        .skip FN_CODE
gnames:         .skip G_MAX*32
gvals:          .skip G_MAX*16
fntab:          .skip F_MAX*F_SZ
fntab_save:     .skip F_MAX*F_SZ
lnames:         .skip L_MAX*32
loops:          .skip LP_MAX*LP_SZ
vstack:         .skip VS_N*16
frames:         .skip FR_N*16
sh_a:           .skip SH_SIZE
sh_b:           .skip SH_SIZE
script_src_buf: .skip SRC_MAX
script_out:     .skip OUT_MAX
mac_buf:        .skip MAC_MAX
ln_buf:         .skip LN_MAX+8
op_argbuf:      .skip 520
opbuf:          .skip 64
name_tmp:       .skip 40
nbuf:           .skip 64
dig_tmp:        .skip 32
mac_path:       .skip 512
sc_result:      .skip 16
.align 8
tkp:            .skip 8
em_ptr:         .skip 8
em_end:         .skip 8
fn_pos:         .skip 8
fn_pos_save:    .skip 8
sh_base:        .skip 8
sh_pos:         .skip 8
sh_end:         .skip 8
sc_rsp:         .skip 8
script_out_len: .skip 4
gcount:         .skip 4
fcount:         .skip 4
fcount_save:    .skip 4
nlocals:        .skip 4
loop_depth:     .skip 4
fn_mode:        .skip 4
c_depth:        .skip 4
sc_line:        .skip 4
sc_running:     .skip 4
sc_phase:       .skip 4             # 0 compiling, 1 running
sc_agent:       .skip 4
macro_on:       .skip 4
mac_len:        .skip 4

.section .data
.align 8
rng_state:      .quad 0x9E3779B97F4A7C15

.section .rodata
fr_million:     .double 1000000.0
.align 16
f_sign:         .quad 0x8000000000000000, 0
f_abs:          .quad 0x7fffffffffffffff, 0
f_one:          .double 1.0
f_ten:          .double 10.0
f_half:         .double 0.5
f_pi:           .double 3.141592653589793
f_d2r:          .double 0.017453292519943295
f_r2d:          .double 57.29577951308232
f_1e6:          .double 1000000.0
f_1e15:         .double 1.0e15
f_1em4:         .double 1.0e-4
f_inf:          .double 1.0e308
f_2m53:         .double 1.1102230246251565e-16
f_sixth:        .double 0.16666666666666666
f_1000:         .double 1000.0
# number units: name (8 bytes, zero padded), factor
units:          .ascii "m\0\0\0\0\0\0\0"
                .double 1.0
                .ascii "cm\0\0\0\0\0\0"
                .double 0.01
                .ascii "mm\0\0\0\0\0\0"
                .double 0.001
                .ascii "km\0\0\0\0\0\0"
                .double 1000.0
                .ascii "deg\0\0\0\0\0"
                .double 0.017453292519943295
                .ascii "rad\0\0\0\0\0"
                .double 1.0
units_end:
keywords:       .ascii "fn\0\0\0\0\0\0"
                .quad TK_FN
                .ascii "if\0\0\0\0\0\0"
                .quad TK_IF
                .ascii "else\0\0\0\0"
                .quad TK_ELSE
                .ascii "while\0\0\0"
                .quad TK_WHILE
                .ascii "for\0\0\0\0\0"
                .quad TK_FOR
                .ascii "in\0\0\0\0\0\0"
                .quad TK_IN
                .ascii "return\0\0"
                .quad TK_RETURN
                .ascii "break\0\0\0"
                .quad TK_BREAK
                .ascii "continue"
                .quad TK_CONTINUE
                .ascii "and\0\0\0\0\0"
                .quad TK_AND
                .ascii "or\0\0\0\0\0\0"
                .quad TK_OR
                .ascii "not\0\0\0\0\0"
                .quad TK_NOT
                .ascii "true\0\0\0\0"
                .quad TK_TRUE
                .ascii "false\0\0\0"
                .quad TK_FALSE
                .ascii "nil\0\0\0\0\0"
                .quad TK_NIL
                .ascii "pi\0\0\0\0\0\0"
                .quad TK_PI
keywords_end:
# object properties for get / set
props:          .ascii "x\0\0\0\0\0\0\0"
                .quad OB_LOC
                .ascii "y\0\0\0\0\0\0\0"
                .quad OB_LOC+4
                .ascii "z\0\0\0\0\0\0\0"
                .quad OB_LOC+8
                .ascii "rx\0\0\0\0\0\0"
                .quad OB_ROT
                .ascii "ry\0\0\0\0\0\0"
                .quad OB_ROT+4
                .ascii "rz\0\0\0\0\0\0"
                .quad OB_ROT+8
                .ascii "sx\0\0\0\0\0\0"
                .quad OB_SCALE
                .ascii "sy\0\0\0\0\0\0"
                .quad OB_SCALE+4
                .ascii "sz\0\0\0\0\0\0"
                .quad OB_SCALE+8
props_end:

# builtins: name, handler, min args, max args
.align 8
builtins:
    .quad bn_print, b_print
    .long 0, 16
    .quad bn_str, b_str
    .long 1, 1
    .quad bn_num, b_num
    .long 1, 1
    .quad bn_len, b_len
    .long 1, 1
    .quad bn_sin, b_sin
    .long 1, 1
    .quad bn_cos, b_cos
    .long 1, 1
    .quad bn_tan, b_tan
    .long 1, 1
    .quad bn_sqrt, b_sqrt
    .long 1, 1
    .quad bn_abs, b_abs
    .long 1, 1
    .quad bn_floor, b_floor
    .long 1, 1
    .quad bn_round, b_round
    .long 1, 1
    .quad bn_deg, b_deg
    .long 1, 1
    .quad bn_rad, b_rad
    .long 1, 1
    .quad bn_min, b_min
    .long 1, 16
    .quad bn_max, b_max
    .long 1, 16
    .quad bn_pow, b_pow
    .long 2, 2
    .quad bn_atan2, b_atan2
    .long 2, 2
    .quad bn_rand, b_rand
    .long 0, 0
    .quad bn_seed, b_seed
    .long 1, 1
    .quad bn_add, b_add
    .long 1, 5
    .quad bn_move, b_move
    .long 4, 4
    .quad bn_rotate, b_rotate
    .long 4, 4
    .quad bn_scale, b_scale
    .long 2, 4
    .quad bn_get, b_get
    .long 2, 2
    .quad bn_set, b_set
    .long 3, 3
    .quad bn_select, b_select
    .long 0, 16
    .quad bn_delete, b_delete
    .long 1, 16
    .quad bn_rename, b_rename
    .long 2, 2
    .quad bn_exists, b_exists
    .long 1, 1
    .quad bn_count, b_count
    .long 0, 0
    .quad bn_name, b_name
    .long 1, 1
    .quad bn_active, b_active
    .long 0, 0
    .quad bn_op, b_op
    .long 1, 2
    .quad bn_edit, b_edit
    .long 0, 1
    .quad bn_verts, b_verts
    .long 1, 1
    .quad bn_edges, b_edges
    .long 1, 1
    .quad bn_faces, b_faces
    .long 1, 1
    .quad bn_selected, b_selected
    .long 1, 1
    .quad bn_vpos, b_vpos
    .long 3, 3
    .quad bn_vselect, b_vselect
    .long 1, 16
    .quad bn_vsel, b_vsel
    .long 2, 3
    .quad bn_volume, b_volume
    .long 1, 1
    .quad bn_modifier, b_modifier
    .long 2, 2
    .quad bn_modset, b_modset
    .long 4, 4
    .quad bn_modapply, b_modapply
    .long 2, 2
    .quad bn_modremove, b_modremove
    .long 2, 2
    .quad bn_modcount, b_modcount
    .long 1, 1
    .quad bn_everts, b_everts
    .long 1, 1
    .quad bn_efaces, b_efaces
    .long 1, 1
    .quad bn_clock, b_clock
    .long 0, 0
    .quad bn_vmove, b_vmove
    .long 5, 5
    .quad bn_boolean, b_boolean
    .long 3, 3
    .quad bn_manifold, b_manifold
    .long 1, 1
    .quad bn_analyze, b_analyze
    .long 2, 2
    .quad bn_material, b_material
    .long 1, 1
    .quad bn_matset, b_matset
    .long 3, 5
    .quad bn_matget, b_matget
    .long 2, 3
    .quad bn_assign, b_assign
    .long 2, 2
    .quad bn_matof, b_matof
    .long 1, 1
    .quad bn_render, b_render
    .long 1, 5
    .quad bn_image, b_image
    .long 1, 1
    .quad bn_imgsize, b_imgsize
    .long 2, 2
    .quad bn_imgpixel, b_imgpixel
    .long 4, 4
    .quad bn_node, b_node
    .long 2, 6
    .quad bn_link, b_link
    .long 4, 4
    .quad bn_nodeset, b_nodeset
    .long 4, 6
    .quad bn_socket, b_socket
    .long 3, 3
    .quad bn_param, b_param
    .long 1, 2
    .quad bn_sketch, b_sketch
    .long 2, 3
    .quad bn_point, b_point
    .long 3, 3
    .quad bn_line, b_line
    .long 3, 5
    .quad bn_circle, b_circle
    .long 4, 4
    .quad bn_arc, b_arc
    .long 6, 6
    .quad bn_rect, b_rect
    .long 5, 5
    .quad bn_pt, b_pt
    .long 3, 3
    .quad bn_con, b_con
    .long 3, 6
    .quad bn_dof, b_dof
    .long 1, 1
    .quad bn_conflicts, b_conflicts
    .long 1, 1
    .quad bn_sx, b_sx
    .long 2, 2
    .quad bn_sy, b_sy
    .long 2, 2
    .quad bn_sr, b_sr
    .long 2, 2
    .quad bn_skinfo, b_skinfo
    .long 2, 2
    .quad bn_expr, b_expr
    .long 1, 1
    .quad bn_pad, b_pad
    .long 3, 4
    .quad bn_pocket, b_pocket
    .long 3, 4
    .quad bn_revolve, b_revolve
    .long 3, 4
    .quad bn_hole, b_hole
    .long 3, 4
    .quad bn_shell, b_shell
    .long 3, 4
    .quad bn_fillet, b_fillet
    .long 2, 3
    .quad bn_chamfer, b_chamfer
    .long 2, 3
    .quad bn_pattern, b_pattern
    .long 5, 6
    .quad bn_feature, b_feature
    .long 3, 3
    .quad bn_features, b_features
    .long 0, 0
    .quad bn_fstatus, b_fstatus
    .long 1, 1
    .quad bn_area, b_area
    .long 1, 1
    .quad bn_mass, b_mass
    .long 1, 1
    .quad bn_centroid, b_centroid
    .long 2, 2
    .quad bn_fangle, b_fangle
    .long 3, 3
    .quad bn_measurement, b_measurement
    .long 0, 0
    .quad bn_ssphere, b_ssphere
    .long 1, 1
    .quad bn_sbox, b_sbox
    .long 3, 4
    .quad bn_scyl, b_scyl
    .long 2, 2
    .quad bn_storus, b_storus
    .long 2, 2
    .quad bn_sgyroid, b_sgyroid
    .long 2, 2
    .quad bn_sgrid, b_sgrid
    .long 2, 2
    .quad bn_sunion, b_sunion
    .long 2, 3
    .quad bn_ssub, b_ssub
    .long 2, 3
    .quad bn_sisect, b_sisect
    .long 2, 3
    .quad bn_sshell, b_sshell
    .long 2, 2
    .quad bn_smove, b_smove
    .long 4, 4
    .quad bn_srot, b_srot
    .long 4, 4
    .quad bn_sdist, b_sdist
    .long 4, 4
    .quad bn_smesh, b_smesh
    .long 2, 3
    .quad bn_sclear, b_sclear
    .long 0, 0
    .quad bn_infill, b_infill
    .long 5, 5
    .quad bn_thinnest, b_thinnest
    .long 1, 1
    .quad bn_sculpt, b_sculpt
    .long 10, 10
    .quad bn_frames, b_frames
    .long 0, 0
    .quad bn_unwrap, b_unwrap
    .long 1, 2
    .quad bn_uvpack, b_uvpack
    .long 1, 1
    .quad bn_seams, b_seams
    .long 2, 2
    .quad bn_uvstat, b_uvstat
    .long 2, 2
    .quad bn_imgset, b_imgset
    .long 6, 7
    .quad bn_uvmap, b_uvmap
    .long 5, 5
    .quad bn_paint, b_paint
    .long 5, 8
    .quad bn_frametime, b_frametime
    .long 1, 1
builtins_end:
.equ B_SZ, 24

optab:
    .quad vm_halt, vm_line, vm_num, vm_str, vm_nil, vm_getg, vm_setg, vm_getl
    .quad vm_setl, vm_add, vm_sub, vm_mul, vm_div, vm_mod, vm_neg, vm_not
    .quad vm_eq, vm_ne, vm_lt, vm_le, vm_gt, vm_ge, vm_jmp, vm_jf
    .quad vm_jfk, vm_jtk, vm_callb, vm_callf, vm_ret, vm_pop, vm_popr, vm_clrr

bn_print:       .asciz "print"
bn_str:         .asciz "str"
bn_num:         .asciz "num"
bn_len:         .asciz "len"
bn_sin:         .asciz "sin"
bn_cos:         .asciz "cos"
bn_tan:         .asciz "tan"
bn_sqrt:        .asciz "sqrt"
bn_abs:         .asciz "abs"
bn_floor:       .asciz "floor"
bn_round:       .asciz "round"
bn_deg:         .asciz "deg"
bn_rad:         .asciz "rad"
bn_min:         .asciz "min"
bn_max:         .asciz "max"
bn_pow:         .asciz "pow"
bn_atan2:       .asciz "atan2"
bn_rand:        .asciz "rand"
bn_seed:        .asciz "seed"
bn_add:         .asciz "add"
bn_move:        .asciz "move"
bn_rotate:      .asciz "rotate"
bn_scale:       .asciz "scale"
bn_get:         .asciz "get"
bn_set:         .asciz "set"
bn_select:      .asciz "select"
bn_delete:      .asciz "delete"
bn_rename:      .asciz "rename"
bn_exists:      .asciz "exists"
bn_count:       .asciz "count"
bn_name:        .asciz "name"
bn_active:      .asciz "active"
bn_op:          .asciz "op"
bn_edit:        .asciz "edit"
bn_verts:       .asciz "verts"
bn_edges:       .asciz "edges"
bn_faces:       .asciz "faces"
bn_selected:    .asciz "selected"
bn_vpos:        .asciz "vpos"
bn_vselect:     .asciz "vselect"
bn_vsel:        .asciz "vsel"
bn_volume:      .asciz "volume"
bn_modifier:    .asciz "modifier"
bn_modset:      .asciz "modset"
bn_modapply:    .asciz "modapply"
bn_modremove:   .asciz "modremove"
bn_modcount:    .asciz "modcount"
bn_everts:      .asciz "everts"
bn_efaces:      .asciz "efaces"
bn_clock:       .asciz "clock"
bn_vmove:       .asciz "vmove"
bn_boolean:     .asciz "boolean"
bn_manifold:    .asciz "manifold"
bn_analyze:     .asciz "analyze"
bn_material:    .asciz "material"
bn_matset:      .asciz "matset"
bn_matget:      .asciz "matget"
bn_assign:      .asciz "assign"
bn_matof:       .asciz "matof"
bn_render:      .asciz "render"
bn_image:       .asciz "image"
bn_imgsize:     .asciz "imgsize"
bn_imgpixel:    .asciz "imgpixel"
bn_node:        .asciz "node"
bn_link:        .asciz "link"
bn_nodeset:     .asciz "nodeset"
bn_socket:      .asciz "socket"
bn_param:       .asciz "param"
bn_sketch:      .asciz "sketch"
bn_point:       .asciz "point"
bn_line:        .asciz "line"
bn_circle:      .asciz "circle"
bn_arc:         .asciz "arc"
bn_rect:        .asciz "rect"
bn_pt:          .asciz "pt"
bn_con:         .asciz "con"
bn_dof:         .asciz "dof"
bn_conflicts:   .asciz "conflicts"
bn_sx:          .asciz "sx"
bn_sy:          .asciz "sy"
bn_sr:          .asciz "sr"
bn_skinfo:      .asciz "skinfo"
s_ki_points:    .asciz "points"
s_ki_ents:      .asciz "entities"
s_ki_cons:      .asciz "constraints"
s_plane_xy:     .asciz "XY"
s_plane_xz:     .asciz "XZ"
s_plane_yz:     .asciz "YZ"
e_no_sketch:    .asciz "no sketch called "
e_sk_plane:     .asciz "sketch plane: XY, XZ or YZ, not "
e_sk_full:      .asciz "the sketch is full"
e_sk_ctype:     .asciz "unknown constraint (coincident horizontal vertical parallel perpendicular equal tangent fixed distance hdistance vdistance radius diameter angle length online oncircle midpoint symmetric): "
e_sk_ref:       .asciz "no such point or entity"
bn_expr:        .asciz "expr"
bn_pad:         .asciz "pad"
bn_pocket:      .asciz "pocket"
bn_revolve:     .asciz "revolve"
bn_hole:        .asciz "hole"
bn_shell:       .asciz "shell"
bn_fillet:      .asciz "fillet"
bn_chamfer:     .asciz "chamfer"
bn_pattern:     .asciz "pattern"
bn_feature:     .asciz "feature"
bn_features:    .asciz "features"
bn_fstatus:     .asciz "fstatus"
bn_area:        .asciz "area"
bn_mass:        .asciz "mass"
bn_centroid:    .asciz "centroid"
bn_fangle:      .asciz "fangle"
bn_measurement: .asciz "measurement"
bn_ssphere:    .asciz "ssphere"
bn_sbox:       .asciz "sbox"
bn_scyl:       .asciz "scyl"
bn_storus:     .asciz "storus"
bn_sgyroid:    .asciz "sgyroid"
bn_sgrid:      .asciz "sgrid"
bn_sunion:     .asciz "sunion"
bn_ssub:       .asciz "ssub"
bn_sisect:     .asciz "sisect"
bn_sshell:     .asciz "sshell"
bn_smove:      .asciz "smove"
bn_srot:       .asciz "srot"
bn_sdist:      .asciz "sdist"
bn_smesh:      .asciz "smesh"
bn_sclear:     .asciz "sclear"
bn_infill:      .asciz "infill"
bn_thinnest:    .asciz "thinnest"
bn_sculpt:      .asciz "sculpt"
bn_frames:      .asciz "frames"
bn_unwrap:      .asciz "unwrap"
bn_uvpack:      .asciz "uvpack"
bn_seams:       .asciz "seams"
bn_uvstat:      .asciz "uvstat"
bn_imgset:      .asciz "imgset"
bn_uvmap:       .asciz "uvmap"
bn_paint:       .asciz "paint"
s_smart:        .asciz "smart"
.align 8
seam_modes:     .quad sm_mark, sm_clear, sm_sharp, sm_none, 0
sm_mark:        .asciz "mark"
sm_clear:       .asciz "clear"
sm_sharp:       .asciz "sharp"
sm_none:        .asciz "none"
.align 8
uvstat_kinds:   .quad uk_isl, uk_angle, uk_area, uk_flip, uk_over, uk_in, 0
uk_isl:         .asciz "islands"
uk_angle:       .asciz "angle"
uk_area:        .asciz "area"
uk_flip:        .asciz "flipped"
uk_over:        .asciz "overlap"
uk_in:          .asciz "inside"
e_uv_kind:      .asciz "unknown kind: "
bn_frametime:   .asciz "frametime"
e_brush:        .asciz "sculpt brushes: draw, clay strips, crease, inflate, grab, snake hook, smooth, flatten, pinch, layer, mask - not "
.align 8
fw_lat:         .quad fw_gyroid
                .long 0, 0
                .quad fw_gridw
                .long 1, 0
                .quad 0
fw_gyroid:      .asciz "gyroid"
fw_gridw:       .asciz "grid"
e_sdf:          .asciz "shape: "
e_sdf_id:       .asciz "no such shape"
s_shape:        .asciz "Shape"
.align 4
sd_one:         .float 1.0
sd_half:        .float 0.5
sd_big:         .float 1.0e29
e_no_face:      .asciz "no such face"
e_ft_long:      .asciz "a feature value is 31 characters at most: "
e_ft_word:      .asciz "not understood here: "
e_ft_full:      .asciz "the scene holds 64 features"
e_ft_ref:       .asciz "no such feature"
e_ft_body:      .asciz "the body is not a mesh: "
s_body:         .asciz "Body"
.align 8
fw_modes:       .quad fw_sym
                .long 1, 0
                .quad fw_rev
                .long 2, 0
                .quad fw_thru
                .long 4, 0
                .quad fw_bottom
                .long 2, 0
                .quad 0
fw_axes:        .quad fw_x
                .long 0, 0
                .quad fw_y
                .long 1, 0
                .quad fw_z
                .long 2, 0
                .quad fw_u
                .long 0, 0
                .quad fw_v
                .long 1, 0
                .quad 0
fw_sels:        .quad fw_all
                .long 0, 0
                .quad fw_vert
                .long 1, 0
                .quad fw_horiz
                .long 2, 0
                .quad fw_top
                .long 3, 0
                .quad fw_bottom
                .long 4, 0
                .quad 0
fw_circ:        .quad fw_circular
                .long 1, 0
                .quad fw_linear
                .long 0, 0
                .quad 0
fw_sym:         .asciz "symmetric"
fw_rev:         .asciz "reverse"
fw_thru:        .asciz "through"
fw_bottom:      .asciz "bottom"
fw_x:           .asciz "x"
fw_y:           .asciz "y"
fw_z:           .asciz "z"
fw_u:           .asciz "u"
fw_v:           .asciz "v"
fw_all:         .asciz "all"
fw_vert:        .asciz "vertical"
fw_horiz:       .asciz "horizontal"
fw_top:         .asciz "top"
fw_circular:    .asciz "circular"
fw_linear:      .asciz "linear"
e_param:        .asciz "parameter: "
e_noparam:      .asciz "no parameter named "
e_node_type:    .asciz "unknown node type (image noise checker gradient mix ramp math bump): "
e_node_full:    .asciz "a material holds 12 nodes"
e_node_bad:     .asciz "no such node, input or socket (links go from an earlier node)"
e_image:        .asciz "image: could not load "
e_no_image:     .asciz "no image called "
e_render:       .asciz "render: could not render or write "
e_no_mat:       .asciz "no material named "
e_mat_param:    .asciz "material parameters: base metallic roughness specular ior transmission emission strength clearcoat coat_roughness alpha density, not "
e_mat_full:     .asciz "the scene holds 1024 materials"
an_kind_names:  .asciz "boundary"
                .asciz "nonmanifold"
                .asciz "degenerate"
                .asciz "loose"
                .asciz "overhang"
                .byte 0
e_an_kind:      .asciz "analyze: boundary, nonmanifold, degenerate, loose or overhang, not "
s_bool_op:      .asciz "object.boolean"
e_modtype:      .asciz "modifier types: mirror array solidify subsurf bevel decimate remesh; got "
e_modidx:       .asciz "no modifier with that index / parameter"
e_not_mesh:     .asciz "not a mesh: "
e_axis:         .asciz "axis must be 0, 1 or 2 (or \"x\", \"y\", \"z\")"

s_ind:          .asciz "  "
s_error:        .asciz "error: "
s_line:         .asciz "line "
s_colon:        .asciz ": "
s_eq:           .asciz "= "
s_nil:          .asciz "nil"
s_nan:          .asciz "nan"
s_infv:         .asciz "inf"
s_script:       .asciz "Script"
s_empty:        .asciz ""
s_create_pfx:   .asciz "create."
s_del_op:       .asciz "object.delete"
s_pfx_script:   .asciz "script."
s_pfx_tm:       .asciz "transform."
s_pfx_object:   .asciz "object."
s_undo_op:      .asciz "edit.undo"
s_redo_op:      .asciz "edit.redo"
s_busy:         .asciz "  a script is already running"
s_rec_start:    .asciz "  recording a macro - run script.record again to stop"
s_rec_empty:    .asciz "  macro is empty - nothing saved"
s_rec_saved:    .asciz "  macro saved: "
s_rec_hint:     .asciz "  script.run plays it back"
s_rec_fail:     .asciz "  could not save the macro"
s_run:          .asciz "  running "
s_cant_read:    .asciz "can't read "
s_too_big:      .asciz "script too large (64 KiB max)"
s_reset:        .asciz "  script variables and functions cleared"
s_scripts_dir:  .asciz "/scripts"
s_macro_file:   .asciz "/macro.bees"
m_op:           .asciz "op("
m_select:       .asciz "select("
m_move:         .asciz "move("
m_rotate:       .asciz "rotate("
m_scale:        .asciz "scale("
m_comma:        .asciz ", "
m_close:        .asciz ")\n"
m_deg:          .asciz "deg"

e_char:         .asciz "unexpected character"
e_string:       .asciz "unterminated text (missing quote)"
e_unit:         .asciz "unknown unit (m cm mm km deg rad)"
e_toolong:      .asciz "script too long"
e_name_long:    .asciz "name too long (31 characters max)"
e_value:        .asciz "expected a value"
e_rp:           .asciz "expected )"
e_lb:           .asciz "expected {"
e_rb:           .asciz "missing }"
e_stray_rb:     .asciz "unexpected }"
e_end:          .asciz "expected a new line or ; after the statement"
e_in:           .asciz "expected 'in' after the loop variable"
e_dotdot:       .asciz "expected .. in the range (for i in 0..10)"
e_var:          .asciz "expected a variable name"
e_fn_name:      .asciz "expected a function name"
e_fn_top:       .asciz "fn can only be defined at the top level"
e_fn_builtin:   .asciz "that name belongs to a builtin: "
e_dup_param:    .asciz "duplicate parameter"
e_break:        .asciz "break / continue outside a loop"
e_jumps:        .asciz "too many break / continue in one loop"
e_nest:         .asciz "nested too deeply"
e_loops:        .asciz "loops nested too deeply"
e_vars:         .asciz "too many variables"
e_fns:          .asciz "too many functions"
e_locals:       .asciz "too many local variables"
e_code_full:    .asciz "script too large to compile"
e_args:         .asciz "wrong number of arguments for "
e_text_long:    .asciz "text too long"
e_undef:        .asciz "not defined: "
e_nofn:         .asciz "function not defined: "
e_fn_args:      .asciz "wrong number of arguments for "
e_recursion:    .asciz "too much recursion"
e_stack:        .asciz "expression stack overflow"
e_steps:        .asciz "stopped after 500 million steps (endless loop?)"
e_add:          .asciz "+ needs two numbers, or a text"
e_arith:        .asciz "arithmetic needs numbers"
e_cmp:          .asciz "only numbers can be compared with < <= > >="
e_div0:         .asciz "division by zero"
e_strmem:       .asciz "out of text memory"
e_want_num:     .asciz "expected a number"
e_want_str:     .asciz "expected a text"
e_no_obj:       .asciz "no object named "
e_bad_type:     .asciz "unknown object type (cube sphere cylinder cone torus plane grid light camera): "
e_add_args:     .asciz "add(type, [name], [x, y, z])"
e_scale_args:   .asciz "scale(name, s) or scale(name, x, y, z)"
e_prop:         .asciz "unknown property (x y z rx ry rz sx sy sz): "
e_range:        .asciz "index out of range"
e_no_op:        .asciz "unknown operator: "
e_op_script:    .asciz "scripts can't start scripts: "
e_op_modal:     .asciz "interactive operators can't run from scripts: "
e_op_undo:      .asciz "undo / redo can't run inside a script (the script is one undo step): "
e_op_agent:     .asciz "operator not allowed for agents: "
e_op_perm:      .asciz "permission denied (the user has not given agents file access): "

OPERATOR op_script_record, "script.record", "Record Macro", do_record, check=chk_record, flags=OPF_QUIET, doc="Start / stop recording your actions as a BeeScript macro"
OPERATOR op_script_run, "script.run", "Run Script...", do_run, flags=0, doc="Run a BeeScript file: script.run [path] (default: the last macro)"
OPERATOR op_script_reset, "script.reset", "Reset Script State", do_reset, flags=OPF_AI_SAFE|OPF_QUIET, doc="Forget BeeScript variables and functions"

.text

# =============================================================================
#  script_eval(rdi=source asciz, esi=1 if an agent runs it) -> eax = 0 ok, 1 error
#    Output (print, the result, errors) goes to the console and script_out.
# =============================================================================
script_eval:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    cmp     dword ptr [rip+sc_running], 0
    je      1f
    lea     rdi, [rip+s_busy]
    call    log_line
    mov     eax, 1
    jmp     .Lse_ret
1:  mov     [rip+sc_agent], esi
    lea     rsi, [rip+script_src_buf]   # own copy of the source
    cmp     rdi, rsi
    je      3f
    xor     ecx, ecx
2:  mov     al, [rdi+rcx]
    mov     [rsi+rcx], al
    test    al, al
    jz      3f
    inc     ecx
    cmp     ecx, SRC_MAX-1
    jb      2b
    mov     byte ptr [rsi+rcx], 0
3:  mov     dword ptr [rip+script_out_len], 0
    mov     byte ptr [rip+script_out], 0
    mov     dword ptr [rip+sc_running], 1
    mov     dword ptr [rip+sc_phase], 0
    mov     dword ptr [rip+sc_line], 0
    mov     qword ptr [rip+sc_result], T_NIL
    mov     [rip+sc_rsp], rsp
    call    sh_compact
    lea     rdi, [rip+fntab_save]       # compile errors roll functions back
    lea     rsi, [rip+fntab]
    mov     ecx, F_MAX*F_SZ
    rep     movsb
    mov     eax, [rip+fcount]
    mov     [rip+fcount_save], eax
    mov     rax, [rip+fn_pos]
    test    rax, rax
    jnz     4f
    lea     rax, [rip+fn_code]
    mov     [rip+fn_pos], rax
4:  mov     [rip+fn_pos_save], rax
    lea     rsi, [rip+script_src_buf]
    call    lex
    call    compile
    mov     dword ptr [rip+sc_phase], 1
    mov     dword ptr [rip+op_quiet], 1
    lea     rdi, [rip+s_script]         # the whole run is one undo step
    call    undo_group_begin
    lea     rbx, [rip+vstack]           # ---- run ----
    lea     r12, [rip+main_code]
    mov     r13, rbx
    mov     r14d, STEP_MAX
    lea     r15, [rip+frames]
    jmp     .Lvm_next

.Lvm_done:
    call    undo_group_end
    mov     eax, [rip+sc_result]        # REPL echo: "= value"
    cmp     eax, T_NIL
    jbe     5f
    lea     rbx, [rip+ln_buf]
    lea     rsi, [rip+s_eq]
    call    ln_str
    cmp     dword ptr [rip+sc_result], T_STR
    jne     6f
    mov     byte ptr [rbx], '"'
    inc     rbx
6:  lea     rdi, [rip+sc_result]
    mov     rsi, rbx
    lea     rdx, [rip+ln_buf+LN_MAX-2]
    call    val_to
    mov     rbx, rax
    cmp     dword ptr [rip+sc_result], T_STR
    jne     7f
    mov     byte ptr [rbx], '"'
    inc     rbx
7:  mov     byte ptr [rbx], 0
    lea     rdi, [rip+ln_buf]
    call    sc_print
5:  xor     ebx, ebx
    jmp     .Lse_out

.Lse_fail:                              # sc_err lands here, stack restored
    cmp     dword ptr [rip+sc_phase], 0
    jne     1f
    lea     rdi, [rip+fntab]            # compile error: forget new functions
    lea     rsi, [rip+fntab_save]
    mov     ecx, F_MAX*F_SZ
    rep     movsb
    mov     eax, [rip+fcount_save]
    mov     [rip+fcount], eax
    mov     rax, [rip+fn_pos_save]
    mov     [rip+fn_pos], rax
    jmp     2f
1:  call    undo_group_end
2:  mov     ebx, 1
.Lse_out:
    mov     dword ptr [rip+op_quiet], 0
    mov     qword ptr [rip+op_arg], 0
    mov     dword ptr [rip+sc_running], 0
    mov     dword ptr [rip+dirty], 1
    mov     eax, ebx
.Lse_ret:
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

# sc_err(rdi=message, rsi=detail or 0, edx=line or 0) - report, unwind
sc_err:
    mov     r12, rdi
    mov     r13, rsi
    mov     r14d, edx
    mov     rsp, [rip+sc_rsp]
    lea     rbx, [rip+ln_buf]
    lea     rsi, [rip+s_error]
    call    ln_str
    test    r14d, r14d
    jz      1f
    lea     rsi, [rip+s_line]
    call    ln_str
    mov     eax, r14d
    call    put_u64
    lea     rsi, [rip+s_colon]
    call    ln_str
1:  mov     rsi, r12
    call    ln_str
    test    r13, r13
    jz      2f
    mov     rsi, r13
    call    ln_str
2:  mov     byte ptr [rbx], 0
    lea     rdi, [rip+ln_buf]
    call    sc_print
    jmp     .Lse_fail

# sc_rt(rdi=message, rsi=detail) - runtime error at the current line
sc_rt:
    mov     edx, [rip+sc_line]
    jmp     sc_err

# c_error(rdi=message) - compile error at the current token
c_error:
    mov     rax, [rip+tkp]
    mov     edx, [rax+4]
    xor     esi, esi
    jmp     sc_err

# ln_str(rsi=asciz) - append to the line being built at rbx (bounded)
ln_str:
    lea     rcx, [rip+ln_buf+LN_MAX-2]
1:  mov     al, [rsi]
    test    al, al
    jz      2f
    cmp     rbx, rcx
    jae     2f
    mov     [rbx], al
    inc     rbx
    inc     rsi
    jmp     1b
2:  ret

# sc_print(rdi=asciz) - one output line: console + script_out
sc_print:
    push    rbx
    mov     rbx, rdi
    mov     rsi, rdi
    lea     rdi, [rip+s_ind]
    call    log_pair
    lea     rdi, [rip+script_out]
    mov     ecx, [rip+script_out_len]
1:  mov     al, [rbx]
    test    al, al
    jz      2f
    cmp     ecx, OUT_MAX-2
    jae     2f
    mov     [rdi+rcx], al
    inc     ecx
    inc     rbx
    jmp     1b
2:  cmp     ecx, OUT_MAX-2
    jae     3f
    mov     byte ptr [rdi+rcx], 10
    inc     ecx
3:  mov     byte ptr [rdi+rcx], 0
    mov     [rip+script_out_len], ecx
    pop     rbx
    ret

# =============================================================================
#  Lexer
# =============================================================================
.macro TOK t
    mov     dword ptr [rbx], \t
    mov     [rbx+4], r13d
    mov     dword ptr [rbx+8], 0
    add     rbx, TK_SZ
.endm

# lex(rsi=source) - fills toks; errors through sc_err
lex:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r12, rsi
    lea     rbx, [rip+toks]
    mov     r13d, 1                     # line
    xor     r14d, r14d                  # ( ) depth: newlines inside are spaces
.Llx:
    lea     rax, [rip+toks+(TOK_MAX-2)*TK_SZ]
    cmp     rbx, rax
    jae     .Llx_full
    movzx   eax, byte ptr [r12]
    test    eax, eax
    jz      .Llx_eof
    cmp     al, ' '
    je      .Llx_skip
    cmp     al, 9
    je      .Llx_skip
    cmp     al, 13
    je      .Llx_skip
    cmp     al, '#'
    je      .Llx_comment
    cmp     al, 10
    je      .Llx_nl
    cmp     al, ';'
    je      .Llx_semi
    lea     ecx, [rax-'0']
    cmp     ecx, 9
    jbe     .Llx_num
    cmp     al, '.'
    jne     1f
    movzx   ecx, byte ptr [r12+1]
    sub     ecx, '0'
    cmp     ecx, 9
    jbe     .Llx_num
    cmp     byte ptr [r12+1], '.'
    jne     .Llx_bad
    TOK     TK_DOTDOT
    add     r12, 2
    jmp     .Llx
1:  cmp     al, '_'
    je      .Llx_name
    mov     ecx, eax
    or      ecx, 0x20
    sub     ecx, 'a'
    cmp     ecx, 25
    jbe     .Llx_name
    cmp     al, '"'
    je      .Llx_str
    cmp     al, 0x27
    je      .Llx_str
    movzx   ecx, byte ptr [r12+1]       # two-character operators
    mov     edx, TK_EQ
    cmp     al, '='
    je      2f
    mov     edx, TK_NE
    cmp     al, '!'
    je      2f
    mov     edx, TK_LE
    cmp     al, '<'
    je      2f
    mov     edx, TK_GE
    cmp     al, '>'
    je      2f
    mov     edx, TK_ADDEQ
    cmp     al, '+'
    je      2f
    mov     edx, TK_SUBEQ
    cmp     al, '-'
    je      2f
    mov     edx, TK_MULEQ
    cmp     al, '*'
    je      2f
    mov     edx, TK_DIVEQ
    cmp     al, '/'
    je      2f
    jmp     3f
2:  cmp     cl, '='
    jne     3f
    TOK     edx
    add     r12, 2
    jmp     .Llx
3:  lea     rsi, [rip+punct]            # one-character tokens
4:  mov     cl, [rsi]
    test    cl, cl
    jz      .Llx_bad
    cmp     al, cl
    je      5f
    add     rsi, 2
    jmp     4b
5:  movzx   edx, byte ptr [rsi+1]
    TOK     edx
    inc     r12
    cmp     al, '('
    jne     6f
    inc     r14d
6:  cmp     al, ')'
    jne     .Llx
    test    r14d, r14d
    jz      .Llx
    dec     r14d
    jmp     .Llx
.Llx_skip:
    inc     r12
    jmp     .Llx
.Llx_comment:
    inc     r12
    cmp     byte ptr [r12], 0
    je      .Llx
    cmp     byte ptr [r12], 10
    jne     .Llx_comment
    jmp     .Llx
.Llx_nl:
    test    r14d, r14d
    jnz     1f
    TOK     TK_SEP
1:  inc     r13d
    inc     r12
    jmp     .Llx
.Llx_semi:
    TOK     TK_SEP
    inc     r12
    jmp     .Llx
.Llx_num:
    mov     rsi, r12
    call    parse_num
    test    eax, eax
    jnz     .Llx_unit
    mov     r12, rsi
    TOK     TK_NUM
    movsd   [rbx-TK_SZ+16], xmm0
    jmp     .Llx
.Llx_name:
    mov     rsi, r12
1:  inc     r12
    movzx   eax, byte ptr [r12]
    call    is_ident
    test    ecx, ecx
    jnz     1b
    mov     rcx, r12
    sub     rcx, rsi                    # length
    mov     r15d, ecx
    mov     edx, TK_NAME
    cmp     ecx, 8
    ja      3f
    call    pack8                       # keyword?
    mov     edx, TK_NAME
    lea     rdi, [rip+keywords]
2:  lea     r8, [rip+keywords_end]
    cmp     rdi, r8
    jae     3f
    cmp     rax, [rdi]
    je      4f
    add     rdi, 16
    jmp     2b
4:  mov     edx, [rdi+8]
3:  TOK     edx
    mov     [rbx-TK_SZ+8], r15d
    mov     [rbx-TK_SZ+16], rsi
    jmp     .Llx
.Llx_str:
    mov     dl, al                      # the quote
    lea     rsi, [r12+1]
    mov     rcx, rsi
1:  mov     al, [rcx]
    test    al, al
    jz      .Llx_unterm
    cmp     al, 10
    je      .Llx_unterm
    cmp     al, dl
    je      2f
    cmp     al, '\\'
    jne     3f
    cmp     byte ptr [rcx+1], 0
    je      .Llx_unterm
    inc     rcx
3:  inc     rcx
    jmp     1b
2:  TOK     TK_STR
    mov     rax, rcx
    sub     rax, rsi
    mov     [rbx-TK_SZ+8], eax
    mov     [rbx-TK_SZ+16], rsi
    lea     r12, [rcx+1]
    jmp     .Llx
.Llx_eof:
    TOK     TK_SEP
    TOK     TK_EOF
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
.Llx_bad:
    lea     rdi, [rip+e_char]
    jmp     .Llx_err
.Llx_unterm:
    lea     rdi, [rip+e_string]
    jmp     .Llx_err
.Llx_unit:
    lea     rdi, [rip+e_unit]
    jmp     .Llx_err
.Llx_full:
    lea     rdi, [rip+e_toolong]
.Llx_err:
    xor     esi, esi
    mov     edx, r13d
    jmp     sc_err

.section .rodata
punct:          .byte '(', TK_LP, ')', TK_RP, '{', TK_LB, '}', TK_RB, ',', TK_COMMA
                .byte '=', TK_ASSIGN, '<', TK_LT, '>', TK_GT, '+', TK_PLUS
                .byte '-', TK_MINUS, '*', TK_STAR, '/', TK_SLASH, '%', TK_PCT, 0
.text

# is_ident(al=char) -> ecx = 1 for [A-Za-z0-9_]
is_ident:
    mov     ecx, 1
    cmp     al, '_'
    je      1f
    lea     edx, [rax-'0']
    cmp     edx, 9
    jbe     1f
    mov     edx, eax
    or      edx, 0x20
    sub     edx, 'a'
    cmp     edx, 25
    jbe     1f
    xor     ecx, ecx
1:  ret

# pack8(rsi=text, ecx=length <= 8) -> rax = bytes as a zero-padded qword
pack8:
    xor     eax, eax
    mov     edx, ecx
1:  test    edx, edx
    jz      2f
    dec     edx
    shl     rax, 8
    mov     al, [rsi+rdx]
    jmp     1b
2:  ret

# parse_num(rsi=text) -> xmm0 (double, units applied), rsi after it,
#   eax = 0 ok, 1 unknown unit, 2 no digits
parse_num:
    xorpd   xmm0, xmm0                  # all digits as one mantissa
    movsd   xmm2, [rip+f_ten]
    xor     ecx, ecx                    # power of ten to divide by
    xor     edx, edx                    # any digits?
1:  movzx   eax, byte ptr [rsi]
    sub     eax, '0'
    cmp     eax, 9
    ja      2f
    mulsd   xmm0, xmm2
    cvtsi2sd xmm1, eax
    addsd   xmm0, xmm1
    inc     rsi
    mov     edx, 1
    jmp     1b
2:  cmp     byte ptr [rsi], '.'
    jne     4f
    movzx   eax, byte ptr [rsi+1]
    sub     eax, '0'
    cmp     eax, 9
    ja      4f
    inc     rsi
3:  movzx   eax, byte ptr [rsi]
    sub     eax, '0'
    cmp     eax, 9
    ja      4f
    mulsd   xmm0, xmm2
    cvtsi2sd xmm1, eax
    addsd   xmm0, xmm1
    inc     rsi
    inc     ecx
    mov     edx, 1
    jmp     3b
4:  test    edx, edx
    jz      .Lpn_none
    mov     al, [rsi]                   # exponent: e, E, e+12, e-3
    or      al, 0x20
    cmp     al, 'e'
    jne     6f
    lea     r8, [rsi+1]
    xor     r9d, r9d
    cmp     byte ptr [r8], '+'
    je      41f
    cmp     byte ptr [r8], '-'
    jne     42f
    mov     r9d, 1
41: inc     r8
42: movzx   eax, byte ptr [r8]
    sub     eax, '0'
    cmp     eax, 9
    ja      6f
    xor     r10d, r10d
43: movzx   eax, byte ptr [r8]
    sub     eax, '0'
    cmp     eax, 9
    ja      44f
    cmp     r10d, 400
    jae     45f
    imul    r10d, r10d, 10
    add     r10d, eax
45: inc     r8
    jmp     43b
44: mov     rsi, r8
    test    r9d, r9d
    jz      46f
    add     ecx, r10d
    jmp     6f
46: sub     ecx, r10d
6:  test    ecx, ecx                    # apply the power of ten
    jz      8f
    js      7f
    movsd   xmm1, [rip+f_one]
61: mulsd   xmm1, xmm2
    dec     ecx
    jnz     61b
    divsd   xmm0, xmm1
    jmp     8f
7:  neg     ecx
71: mulsd   xmm0, xmm2
    dec     ecx
    jnz     71b
8:  movzx   eax, byte ptr [rsi]         # unit suffix
    call    is_ident
    test    ecx, ecx
    jz      .Lpn_ok
    mov     rdi, rsi
9:  inc     rsi
    movzx   eax, byte ptr [rsi]
    call    is_ident
    test    ecx, ecx
    jnz     9b
    mov     rcx, rsi
    sub     rcx, rdi
    cmp     ecx, 7
    ja      .Lpn_unit
    push    rsi
    mov     rsi, rdi
    call    pack8
    pop     rsi
    lea     rdi, [rip+units]
10: lea     r8, [rip+units_end]
    cmp     rdi, r8
    jae     .Lpn_unit
    cmp     rax, [rdi]
    je      11f
    add     rdi, 16
    jmp     10b
11: mulsd   xmm0, [rdi+8]
.Lpn_ok:
    xor     eax, eax
    ret
.Lpn_unit:
    mov     eax, 1
    ret
.Lpn_none:
    mov     eax, 2
    ret

# =============================================================================
#  Compiler (recursive descent, emits bytecode directly)
# =============================================================================
tk_type:
    mov     rax, [rip+tkp]
    mov     eax, [rax]
    ret

tk_next:
    add     qword ptr [rip+tkp], TK_SZ
    ret

# tk_peek2 -> eax = type of the token after the current one
tk_peek2:
    mov     rax, [rip+tkp]
    mov     eax, [rax+TK_SZ]
    ret

# expect(edi=token type, rsi=message) - consume it or fail
expect:
    mov     rax, [rip+tkp]
    cmp     [rax], edi
    jne     1f
    add     qword ptr [rip+tkp], TK_SZ
    ret
1:  mov     rdi, rsi
    jmp     c_error

skip_seps:
    mov     rax, [rip+tkp]
1:  cmp     dword ptr [rax], TK_SEP
    jne     2f
    add     rax, TK_SZ
    jmp     1b
2:  mov     [rip+tkp], rax
    ret

em_byte:
    mov     rax, [rip+em_ptr]
    cmp     rax, [rip+em_end]
    jae     em_full
    mov     [rax], dil
    inc     rax
    mov     [rip+em_ptr], rax
    ret
em_u16:
    mov     rax, [rip+em_ptr]
    lea     rcx, [rax+2]
    cmp     rcx, [rip+em_end]
    ja      em_full
    mov     [rax], di
    mov     [rip+em_ptr], rcx
    ret
em_u32:
    mov     rax, [rip+em_ptr]
    lea     rcx, [rax+4]
    cmp     rcx, [rip+em_end]
    ja      em_full
    mov     [rax], edi
    mov     [rip+em_ptr], rcx
    ret
em_u64:
    mov     rax, [rip+em_ptr]
    lea     rcx, [rax+8]
    cmp     rcx, [rip+em_end]
    ja      em_full
    mov     [rax], rdi
    mov     [rip+em_ptr], rcx
    ret
em_full:
    lea     rdi, [rip+e_code_full]
    jmp     c_error

# em_num(xmm0) - push a constant
em_num:
    sub     rsp, 8
    movsd   [rsp], xmm0
    mov     edi, OP_NUM
    call    em_byte
    mov     rdi, [rsp]
    call    em_u64
    add     rsp, 8
    ret

# em_jump(edi=opcode) -> rax = address of its rel32 (patched later)
em_jump:
    call    em_byte
    xor     edi, edi
    call    em_u32
    mov     rax, [rip+em_ptr]
    sub     rax, 4
    ret

# patch_here(rdi=rel32 address) - make that jump land here
patch_here:
    mov     rax, [rip+em_ptr]
    lea     rcx, [rdi+4]
    sub     rax, rcx
    mov     [rdi], eax
    ret

# em_jump_to(edi=opcode, rsi=target)
em_jump_to:
    push    rsi
    call    em_byte
    pop     rsi
    mov     rax, [rip+em_ptr]
    add     rax, 4
    sub     rsi, rax
    mov     edi, esi
    jmp     em_u32

# tok_name - copy the current token's name into name_tmp
tok_name:
    mov     rax, [rip+tkp]
    mov     ecx, [rax+8]
    cmp     ecx, 31
    ja      1f
    mov     rsi, [rax+16]
    lea     rdi, [rip+name_tmp]
    rep     movsb
    mov     byte ptr [rdi], 0
    ret
1:  lea     rdi, [rip+e_name_long]
    jmp     c_error

# global_ref -> eax = index of the global named name_tmp (created unset)
global_ref:
    push    rbx
    xor     ebx, ebx
1:  cmp     ebx, [rip+gcount]
    jae     2f
    mov     eax, ebx
    shl     eax, 5
    lea     rdi, [rip+gnames]
    add     rdi, rax
    lea     rsi, [rip+name_tmp]
    call    str_eq
    test    eax, eax
    jnz     3f
    inc     ebx
    jmp     1b
2:  cmp     ebx, G_MAX
    jae     4f
    mov     eax, ebx
    shl     eax, 5
    lea     rdi, [rip+gnames]
    add     rdi, rax
    lea     rsi, [rip+name_tmp]
    mov     ecx, 32
    rep     movsb
    mov     eax, ebx
    shl     eax, 4
    lea     rcx, [rip+gvals]
    mov     qword ptr [rcx+rax], T_UNSET
    inc     dword ptr [rip+gcount]
3:  mov     eax, ebx
    pop     rbx
    ret
4:  lea     rdi, [rip+e_vars]
    jmp     c_error

# local_find -> eax = index of the local named name_tmp, or -1
local_find:
    push    rbx
    xor     ebx, ebx
1:  cmp     ebx, [rip+nlocals]
    jae     2f
    mov     eax, ebx
    shl     eax, 5
    lea     rdi, [rip+lnames]
    add     rdi, rax
    lea     rsi, [rip+name_tmp]
    call    str_eq
    test    eax, eax
    jnz     3f
    inc     ebx
    jmp     1b
2:  mov     ebx, -1
3:  mov     eax, ebx
    pop     rbx
    ret

# local_add -> eax = index of a new local named name_tmp
local_add:
    mov     eax, [rip+nlocals]
    cmp     eax, L_MAX
    jae     1f
    shl     eax, 5
    lea     rdi, [rip+lnames]
    add     rdi, rax
    lea     rsi, [rip+name_tmp]
    mov     ecx, 32
    rep     movsb
    mov     eax, [rip+nlocals]
    inc     dword ptr [rip+nlocals]
    ret
1:  lea     rdi, [rip+e_locals]
    jmp     c_error

# ref_read / ref_write -> eax = variable for name_tmp: index, | 0x10000 = local
ref_read:
    cmp     dword ptr [rip+fn_mode], 0
    je      global_ref
    call    local_find
    test    eax, eax
    js      global_ref
    or      eax, 0x10000
    ret
ref_write:
    cmp     dword ptr [rip+fn_mode], 0
    je      global_ref
    call    local_find
    test    eax, eax
    jns     1f
    call    local_add
1:  or      eax, 0x10000
    ret

# emit_get / emit_set(edi=variable)
emit_get:
    push    rbx
    mov     ebx, edi
    test    ebx, 0x10000
    jnz     1f
    mov     edi, OP_GETG
    call    em_byte
    movzx   edi, bx
    call    em_u16
    pop     rbx
    ret
1:  mov     edi, OP_GETL
    call    em_byte
    movzx   edi, bl
    call    em_byte
    pop     rbx
    ret
emit_set:
    push    rbx
    mov     ebx, edi
    test    ebx, 0x10000
    jnz     1f
    mov     edi, OP_SETG
    call    em_byte
    movzx   edi, bx
    call    em_u16
    pop     rbx
    ret
1:  mov     edi, OP_SETL
    call    em_byte
    movzx   edi, bl
    call    em_byte
    pop     rbx
    ret

# fn_ref -> eax = index of the function named name_tmp (created undefined)
fn_ref:
    push    rbx
    xor     ebx, ebx
1:  cmp     ebx, [rip+fcount]
    jae     2f
    imul    eax, ebx, F_SZ
    lea     rdi, [rip+fntab]
    add     rdi, rax
    lea     rsi, [rip+name_tmp]
    call    str_eq
    test    eax, eax
    jnz     3f
    inc     ebx
    jmp     1b
2:  cmp     ebx, F_MAX
    jae     4f
    imul    eax, ebx, F_SZ
    lea     rdi, [rip+fntab]
    add     rdi, rax
    push    rdi
    xor     eax, eax
    mov     ecx, F_SZ
    rep     stosb
    pop     rdi
    lea     rsi, [rip+name_tmp]
    mov     ecx, 32
    rep     movsb
    inc     dword ptr [rip+fcount]
3:  mov     eax, ebx
    pop     rbx
    ret
4:  lea     rdi, [rip+e_fns]
    jmp     c_error

# builtin_find -> eax = index of the builtin named name_tmp, or -1
builtin_find:
    push    rbx
    lea     rbx, [rip+builtins]
1:  lea     rax, [rip+builtins_end]
    cmp     rbx, rax
    jae     2f
    mov     rdi, [rbx]
    lea     rsi, [rip+name_tmp]
    call    str_eq
    test    eax, eax
    jnz     3f
    add     rbx, B_SZ
    jmp     1b
2:  mov     eax, -1
    pop     rbx
    ret
3:  mov     rax, rbx
    lea     rcx, [rip+builtins]
    sub     rax, rcx
    xor     edx, edx
    mov     ecx, B_SZ
    div     ecx
    pop     rbx
    ret

# nest_in / nest_out - guard the native stack against absurd nesting
nest_in:
    inc     dword ptr [rip+c_depth]
    cmp     dword ptr [rip+c_depth], NEST_MAX
    ja      1f
    ret
1:  lea     rdi, [rip+e_nest]
    jmp     c_error
nest_out:
    dec     dword ptr [rip+c_depth]
    ret

# compile - the token stream into main_code (+ function bodies into fn_code)
compile:
    push    rbx
    lea     rax, [rip+toks]
    mov     [rip+tkp], rax
    lea     rax, [rip+main_code]
    mov     [rip+em_ptr], rax
    lea     rax, [rip+main_code+MAIN_CODE]
    mov     [rip+em_end], rax
    mov     dword ptr [rip+fn_mode], 0
    mov     dword ptr [rip+loop_depth], 0
    mov     dword ptr [rip+c_depth], 0
1:  call    skip_seps
    call    tk_type
    cmp     eax, TK_EOF
    je      2f
    cmp     eax, TK_RB
    je      3f
    mov     edi, 1
    call    c_stmt
    jmp     1b
2:  mov     edi, OP_HALT
    call    em_byte
    pop     rbx
    ret
3:  lea     rdi, [rip+e_stray_rb]
    jmp     c_error

# c_stmt(edi=1 at the top level)
c_stmt:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r12d, edi
    cmp     dword ptr [rip+fn_mode], 0  # REPL echo only for top-level code
    je      1f
    xor     r12d, r12d
1:  mov     edi, OP_LINE
    call    em_byte
    mov     rax, [rip+tkp]
    mov     edi, [rax+4]
    cmp     edi, 0xffff
    jbe     2f
    mov     edi, 0xffff
2:  call    em_u16
    call    tk_type
    cmp     eax, TK_IF
    je      .Lst_if
    cmp     eax, TK_WHILE
    je      .Lst_while
    cmp     eax, TK_FOR
    je      .Lst_for
    cmp     eax, TK_FN
    je      .Lst_fn
    cmp     eax, TK_RETURN
    je      .Lst_return
    cmp     eax, TK_BREAK
    je      .Lst_break
    cmp     eax, TK_CONTINUE
    je      .Lst_break
    cmp     eax, TK_NAME
    jne     .Lst_expr
    call    tk_peek2
    cmp     eax, TK_ASSIGN
    je      .Lst_assign
    cmp     eax, TK_ADDEQ
    jb      .Lst_expr
    cmp     eax, TK_DIVEQ
    jbe     .Lst_assign
.Lst_expr:
    call    c_expr
    mov     edi, OP_POP
    test    r12d, r12d
    jz      1f
    mov     edi, OP_POPR
1:  call    em_byte
    jmp     .Lst_end

.Lst_assign:
    call    tok_name
    call    ref_write
    mov     r14d, eax
    call    tk_next
    call    tk_type
    mov     r13d, eax                   # = += -= *= /=
    call    tk_next
    cmp     r13d, TK_ASSIGN
    je      1f
    mov     edi, r14d
    call    emit_get
1:  call    c_expr
    cmp     r13d, TK_ASSIGN
    je      2f
    lea     edi, [r13-TK_ADDEQ+OP_ADD]
    call    em_byte
2:  mov     edi, r14d
    call    emit_set
    jmp     .Lst_clr

.Lst_if:
    call    c_if
    jmp     .Lst_clr
.Lst_while:
    call    c_while
    jmp     .Lst_clr
.Lst_for:
    call    c_for
    jmp     .Lst_clr
.Lst_fn:
    test    r12d, r12d
    jz      1f
    cmp     dword ptr [rip+c_depth], 0
    jne     1f
    call    c_fn
    jmp     .Lst_clr
1:  lea     rdi, [rip+e_fn_top]
    jmp     c_error
.Lst_return:
    call    tk_next
    call    tk_type
    cmp     eax, TK_SEP
    je      1f
    cmp     eax, TK_RB
    je      1f
    cmp     eax, TK_EOF
    je      1f
    call    c_expr
    jmp     2f
1:  mov     edi, OP_NIL
    call    em_byte
2:  mov     edi, OP_RET
    call    em_byte
    jmp     .Lst_end
.Lst_break:
    mov     ebx, eax
    mov     ecx, [rip+loop_depth]
    test    ecx, ecx
    jz      .Lst_nobreak
    dec     ecx
    imul    ecx, ecx, LP_SZ
    lea     r13, [rip+loops]
    add     r13, rcx                    # innermost loop
    mov     r14d, 0                     # list: breaks
    cmp     ebx, TK_BREAK
    je      1f
    mov     r14d, 4                     # continues
1:  mov     eax, [r13+r14]
    cmp     eax, 16
    jae     .Lst_jumps
    mov     edi, OP_JMP
    call    em_jump
    mov     ecx, [r13+r14]
    lea     rdx, [r13+8]
    test    r14d, r14d
    jz      2f
    lea     rdx, [r13+136]
2:  mov     [rdx+rcx*8], rax
    inc     dword ptr [r13+r14]
    call    tk_next
    jmp     .Lst_end
.Lst_nobreak:
    lea     rdi, [rip+e_break]
    jmp     c_error
.Lst_jumps:
    lea     rdi, [rip+e_jumps]
    jmp     c_error

.Lst_clr:
    test    r12d, r12d
    jz      .Lst_end
    mov     edi, OP_CLRR
    call    em_byte
.Lst_end:
    call    tk_type                     # a statement ends at ; / newline / }
    cmp     eax, TK_SEP
    je      1f
    cmp     eax, TK_RB
    je      1f
    cmp     eax, TK_EOF
    je      1f
    lea     rdi, [rip+e_end]
    jmp     c_error
1:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# c_block - { statements }
c_block:
    push    rbx
    call    nest_in
    mov     edi, TK_LB
    lea     rsi, [rip+e_lb]
    call    expect
1:  call    skip_seps
    call    tk_type
    cmp     eax, TK_RB
    je      2f
    cmp     eax, TK_EOF
    je      3f
    xor     edi, edi
    call    c_stmt
    jmp     1b
2:  call    tk_next
    call    nest_out
    pop     rbx
    ret
3:  lea     rdi, [rip+e_rb]
    jmp     c_error

# c_if - if cond { } [else if ... | else { }]
c_if:
    push    rbx
    push    r12
    push    r13
    call    tk_next
    call    c_expr
    mov     edi, OP_JF
    call    em_jump
    mov     r12, rax
    call    c_block
    mov     rbx, [rip+tkp]              # else may follow on the next line
    call    skip_seps
    call    tk_type
    cmp     eax, TK_ELSE
    je      1f
    mov     [rip+tkp], rbx
    mov     rdi, r12
    call    patch_here
    jmp     9f
1:  mov     edi, OP_JMP
    call    em_jump
    mov     r13, rax
    mov     rdi, r12
    call    patch_here
    call    tk_next
    call    tk_type
    cmp     eax, TK_IF
    jne     2f
    call    c_if
    jmp     3f
2:  call    c_block
3:  mov     rdi, r13
    call    patch_here
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# loop_push -> rax = loop record ; loop_end(rdi=continue target) - patch, pop
loop_push:
    mov     eax, [rip+loop_depth]
    cmp     eax, LP_MAX
    jae     1f
    imul    eax, eax, LP_SZ
    lea     rcx, [rip+loops]
    add     rax, rcx
    mov     qword ptr [rax], 0
    inc     dword ptr [rip+loop_depth]
    ret
1:  lea     rdi, [rip+e_loops]
    jmp     c_error

# loop_patch_cont(rdi=target) - continues of the innermost loop jump there
loop_patch_cont:
    push    rbx
    push    r12
    push    r13
    mov     r13, rdi
    mov     eax, [rip+loop_depth]
    dec     eax
    imul    eax, eax, LP_SZ
    lea     rbx, [rip+loops]
    add     rbx, rax
    xor     r12d, r12d
1:  cmp     r12d, [rbx+4]
    jae     2f
    mov     rdi, [rbx+136+r12*8]
    lea     rcx, [rdi+4]
    mov     rax, r13
    sub     rax, rcx
    mov     [rdi], eax
    inc     r12d
    jmp     1b
2:  pop     r13
    pop     r12
    pop     rbx
    ret

# loop_pop - breaks of the innermost loop land here
loop_pop:
    push    rbx
    push    r12
    mov     eax, [rip+loop_depth]
    dec     eax
    mov     [rip+loop_depth], eax
    imul    eax, eax, LP_SZ
    lea     rbx, [rip+loops]
    add     rbx, rax
    xor     r12d, r12d
1:  cmp     r12d, [rbx]
    jae     2f
    mov     rdi, [rbx+8+r12*8]
    call    patch_here
    inc     r12d
    jmp     1b
2:  pop     r12
    pop     rbx
    ret

# c_while - while cond { }
c_while:
    push    rbx
    push    r12
    push    r13
    mov     r12, [rip+em_ptr]           # top
    call    tk_next
    call    c_expr
    mov     edi, OP_JF
    call    em_jump
    mov     r13, rax
    call    loop_push
    call    c_block
    mov     rdi, r12
    call    loop_patch_cont
    mov     edi, OP_JMP
    mov     rsi, r12
    call    em_jump_to
    mov     rdi, r13
    call    patch_here
    call    loop_pop
    pop     r13
    pop     r12
    pop     rbx
    ret

# c_for - for v in a..b { }   (b exclusive, step 1)
c_for:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    call    tk_next
    call    tk_type
    cmp     eax, TK_NAME
    jne     .Lfor_var
    call    tok_name
    call    ref_write
    mov     r14d, eax                   # loop variable
    call    tk_next
    mov     edi, TK_IN
    lea     rsi, [rip+e_in]
    call    expect
    call    c_expr
    mov     edi, r14d
    call    emit_set
    mov     edi, TK_DOTDOT
    lea     rsi, [rip+e_dotdot]
    call    expect
    call    c_expr
    mov     byte ptr [rip+name_tmp], 1  # hidden end variable per depth
    mov     eax, [rip+loop_depth]
    add     eax, '0'
    mov     [rip+name_tmp+1], al
    mov     byte ptr [rip+name_tmp+2], 0
    call    ref_write
    mov     r15d, eax
    mov     edi, eax
    call    emit_set
    mov     r12, [rip+em_ptr]           # top: v < end ?
    mov     edi, r14d
    call    emit_get
    mov     edi, r15d
    call    emit_get
    mov     edi, OP_LT
    call    em_byte
    mov     edi, OP_JF
    call    em_jump
    mov     r13, rax
    call    loop_push
    call    c_block
    mov     rdi, [rip+em_ptr]           # continue: v = v + 1
    call    loop_patch_cont
    mov     edi, r14d
    call    emit_get
    movsd   xmm0, [rip+f_one]
    call    em_num
    mov     edi, OP_ADD
    call    em_byte
    mov     edi, r14d
    call    emit_set
    mov     edi, OP_JMP
    mov     rsi, r12
    call    em_jump_to
    mov     rdi, r13
    call    patch_here
    call    loop_pop
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
.Lfor_var:
    lea     rdi, [rip+e_var]
    jmp     c_error

# c_fn - fn name(a, b) { }   (top level; the body goes to fn_code)
c_fn:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    call    tk_next
    call    tk_type
    cmp     eax, TK_NAME
    jne     .Lfn_name
    call    tok_name
    call    builtin_find
    test    eax, eax
    jns     .Lfn_builtin
    call    fn_ref
    mov     r14d, eax
    call    tk_next
    mov     edi, TK_LP
    lea     rsi, [rip+e_value]
    call    expect
    mov     dword ptr [rip+fn_mode], 1
    mov     dword ptr [rip+nlocals], 0
    call    tk_type
    cmp     eax, TK_RP
    je      3f
1:  call    tk_type
    cmp     eax, TK_NAME
    jne     .Lfn_var
    call    tok_name
    call    local_find
    test    eax, eax
    jns     .Lfn_dup
    call    local_add
    call    tk_next
    call    tk_type
    cmp     eax, TK_COMMA
    jne     3f
    call    tk_next
    jmp     1b
3:  mov     edi, TK_RP
    lea     rsi, [rip+e_rp]
    call    expect
    mov     r15d, [rip+nlocals]         # parameters
    mov     rbx, [rip+em_ptr]           # switch to the function area
    mov     r12, [rip+em_end]
    mov     rax, [rip+fn_pos]
    mov     [rip+em_ptr], rax
    lea     rax, [rip+fn_code+FN_CODE]
    mov     [rip+em_end], rax
    mov     r13, [rip+fn_pos]           # entry
    call    c_block
    mov     edi, OP_NIL
    call    em_byte
    mov     edi, OP_RET
    call    em_byte
    mov     rax, [rip+em_ptr]
    mov     [rip+fn_pos], rax
    mov     [rip+em_ptr], rbx
    mov     [rip+em_end], r12
    imul    eax, r14d, F_SZ
    lea     rcx, [rip+fntab]
    add     rcx, rax
    mov     [rcx+32], r13
    mov     [rcx+40], r15b
    mov     eax, [rip+nlocals]
    mov     [rcx+41], al
    mov     dword ptr [rip+fn_mode], 0
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
.Lfn_name:
    lea     rdi, [rip+e_fn_name]
    jmp     c_error
.Lfn_var:
    lea     rdi, [rip+e_var]
    jmp     c_error
.Lfn_dup:
    lea     rdi, [rip+e_dup_param]
    jmp     c_error
.Lfn_builtin:
    mov     rax, [rip+tkp]
    mov     edx, [rax+4]
    lea     rdi, [rip+e_fn_builtin]
    lea     rsi, [rip+name_tmp]
    jmp     sc_err

# ---- expressions ---------------------------------------------------------
c_expr:
    push    rbx
    call    nest_in
    call    c_and
1:  call    tk_type
    cmp     eax, TK_OR
    jne     2f
    mov     edi, OP_JTK
    call    em_jump
    mov     rbx, rax
    call    tk_next
    call    c_and
    mov     rdi, rbx
    call    patch_here
    jmp     1b
2:  call    nest_out
    pop     rbx
    ret

c_and:
    push    rbx
    call    c_not
1:  call    tk_type
    cmp     eax, TK_AND
    jne     2f
    mov     edi, OP_JFK
    call    em_jump
    mov     rbx, rax
    call    tk_next
    call    c_not
    mov     rdi, rbx
    call    patch_here
    jmp     1b
2:  pop     rbx
    ret

c_not:
    call    tk_type
    cmp     eax, TK_NOT
    jne     c_cmp
    call    tk_next
    sub     rsp, 8
    call    c_not
    add     rsp, 8
    mov     edi, OP_NOT
    jmp     em_byte

c_cmp:
    push    rbx
    call    c_add
    call    tk_type
    cmp     eax, TK_EQ
    jb      1f
    cmp     eax, TK_GE
    ja      1f
    lea     ebx, [rax-TK_EQ+OP_EQ]
    call    tk_next
    call    c_add
    mov     edi, ebx
    call    em_byte
1:  pop     rbx
    ret

c_add:
    push    rbx
    call    c_mul
1:  call    tk_type
    mov     ebx, OP_ADD
    cmp     eax, TK_PLUS
    je      2f
    mov     ebx, OP_SUB
    cmp     eax, TK_MINUS
    jne     3f
2:  call    tk_next
    call    c_mul
    mov     edi, ebx
    call    em_byte
    jmp     1b
3:  pop     rbx
    ret

c_mul:
    push    rbx
    call    c_unary
1:  call    tk_type
    mov     ebx, OP_MUL
    cmp     eax, TK_STAR
    je      2f
    mov     ebx, OP_DIV
    cmp     eax, TK_SLASH
    je      2f
    mov     ebx, OP_MOD
    cmp     eax, TK_PCT
    jne     3f
2:  call    tk_next
    call    c_unary
    mov     edi, ebx
    call    em_byte
    jmp     1b
3:  pop     rbx
    ret

c_unary:
    call    tk_type
    cmp     eax, TK_MINUS
    jne     c_primary
    call    tk_next
    call    nest_in
    sub     rsp, 8
    call    c_unary
    add     rsp, 8
    call    nest_out
    mov     edi, OP_NEG
    jmp     em_byte

c_primary:
    push    rbx
    call    tk_type
    cmp     eax, TK_NUM
    je      .Lpr_num
    cmp     eax, TK_STR
    je      .Lpr_str
    cmp     eax, TK_NAME
    je      .Lpr_name
    cmp     eax, TK_LP
    je      .Lpr_paren
    cmp     eax, TK_TRUE
    je      .Lpr_true
    cmp     eax, TK_FALSE
    je      .Lpr_false
    cmp     eax, TK_NIL
    je      .Lpr_nil
    cmp     eax, TK_PI
    je      .Lpr_pi
    lea     rdi, [rip+e_value]
    jmp     c_error
.Lpr_num:
    mov     rax, [rip+tkp]
    movsd   xmm0, [rax+16]
    jmp     1f
.Lpr_true:
    movsd   xmm0, [rip+f_one]
    jmp     1f
.Lpr_false:
    xorpd   xmm0, xmm0
    jmp     1f
.Lpr_pi:
    movsd   xmm0, [rip+f_pi]
1:  call    em_num
    jmp     .Lpr_next
.Lpr_nil:
    mov     edi, OP_NIL
    call    em_byte
    jmp     .Lpr_next
.Lpr_str:
    call    c_string
    jmp     .Lpr_next
.Lpr_paren:
    call    tk_next
    call    c_expr
    mov     edi, TK_RP
    lea     rsi, [rip+e_rp]
    call    expect
    pop     rbx
    ret
.Lpr_name:
    call    tk_peek2
    cmp     eax, TK_LP
    je      .Lpr_call
    call    tok_name
    call    ref_read
    mov     edi, eax
    call    emit_get
.Lpr_next:
    call    tk_next
    pop     rbx
    ret
.Lpr_call:
    pop     rbx
    jmp     c_call

# c_call - name(args): a builtin or a script function
c_call:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    call    tok_name
    call    builtin_find
    mov     r12d, eax                   # builtin index or -1
    mov     r15, [rip+tkp]              # for error messages
    test    eax, eax
    jns     1f
    call    fn_ref
    mov     r13d, eax
1:  call    tk_next
    call    tk_next
    xor     ebx, ebx                    # argc
    call    tk_type
    cmp     eax, TK_RP
    je      3f
2:  call    c_expr
    inc     ebx
    call    tk_type
    cmp     eax, TK_COMMA
    jne     3f
    call    tk_next
    jmp     2b
3:  mov     edi, TK_RP
    lea     rsi, [rip+e_rp]
    call    expect
    test    r12d, r12d
    js      5f
    imul    eax, r12d, B_SZ
    lea     r14, [rip+builtins]
    add     r14, rax
    cmp     ebx, [r14+16]
    jb      4f
    cmp     ebx, [r14+20]
    ja      4f
    mov     edi, OP_CALLB
    call    em_byte
    mov     edi, r12d
    call    em_byte
    mov     edi, ebx
    call    em_byte
    jmp     9f
4:  lea     rdi, [rip+e_args]
    mov     rsi, [r14]
    mov     edx, [r15+4]
    jmp     sc_err
5:  cmp     ebx, 255
    ja      4b
    mov     edi, OP_CALLF
    call    em_byte
    mov     edi, r13d
    call    em_u16
    mov     edi, ebx
    call    em_byte
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# c_string - emit the current text token (escapes resolved)
c_string:
    push    rbx
    push    r12
    push    r13
    mov     edi, OP_STR
    call    em_byte
    xor     edi, edi
    call    em_u16
    mov     r13, [rip+em_ptr]           # length goes at r13-2
    mov     rax, [rip+tkp]
    mov     rbx, [rax+16]
    mov     r12d, [rax+8]
1:  test    r12d, r12d
    jz      3f
    movzx   edi, byte ptr [rbx]
    inc     rbx
    dec     r12d
    cmp     edi, '\\'
    jne     2f
    test    r12d, r12d
    jz      2f
    movzx   edi, byte ptr [rbx]
    inc     rbx
    dec     r12d
    cmp     edi, 'n'
    jne     11f
    mov     edi, 10
11: cmp     edi, 't'
    jne     2f
    mov     edi, 9
2:  call    em_byte
    jmp     1b
3:  mov     rax, [rip+em_ptr]
    sub     rax, r13
    cmp     rax, 0xffff
    ja      4f
    mov     [r13-2], ax
    xor     edi, edi
    call    em_byte
    pop     r13
    pop     r12
    pop     rbx
    ret
4:  lea     rdi, [rip+e_text_long]
    jmp     c_error

# =============================================================================
#  VM - rbx value stack top, r12 ip, r13 frame base, r14 step budget,
#       r15 call frames. Every handler ends with jmp .Lvm_next.
# =============================================================================
.macro VCHK
    lea     rax, [rip+vstack+(VS_N-2)*16]
    cmp     rbx, rax
    jae     .Lvm_stack
.endm

.Lvm_next:
    dec     r14
    jz      .Lvm_steps
    movzx   eax, byte ptr [r12]
    inc     r12
    lea     rcx, [rip+optab]
    jmp     [rcx+rax*8]

.Lvm_steps:
    lea     rdi, [rip+e_steps]
    xor     esi, esi
    jmp     sc_rt
.Lvm_stack:
    lea     rdi, [rip+e_stack]
    xor     esi, esi
    jmp     sc_rt

vm_halt:
    jmp     .Lvm_done
vm_line:
    movzx   eax, word ptr [r12]
    add     r12, 2
    mov     [rip+sc_line], eax
    jmp     .Lvm_next
vm_num:
    VCHK
    mov     qword ptr [rbx], T_NUM
    mov     rax, [r12]
    mov     [rbx+8], rax
    add     r12, 8
    add     rbx, 16
    jmp     .Lvm_next
vm_str:
    VCHK
    movzx   eax, word ptr [r12]
    lea     rcx, [r12+2]
    mov     qword ptr [rbx], T_STR
    mov     [rbx+8], rcx
    lea     r12, [r12+rax+3]
    add     rbx, 16
    jmp     .Lvm_next
vm_nil:
    VCHK
    mov     qword ptr [rbx], T_NIL
    mov     qword ptr [rbx+8], 0
    add     rbx, 16
    jmp     .Lvm_next
vm_getg:
    VCHK
    movzx   eax, word ptr [r12]
    add     r12, 2
    mov     ecx, eax
    shl     rax, 4
    lea     rdx, [rip+gvals]
    add     rdx, rax
    cmp     dword ptr [rdx], T_UNSET
    je      1f
    movdqu  xmm0, [rdx]
    movdqu  [rbx], xmm0
    add     rbx, 16
    jmp     .Lvm_next
1:  shl     ecx, 5
    lea     rsi, [rip+gnames]
    add     rsi, rcx
    lea     rdi, [rip+e_undef]
    jmp     sc_rt
vm_setg:
    movzx   eax, word ptr [r12]
    add     r12, 2
    shl     rax, 4
    lea     rdx, [rip+gvals]
    sub     rbx, 16
    movdqu  xmm0, [rbx]
    movdqu  [rdx+rax], xmm0
    jmp     .Lvm_next
vm_getl:
    VCHK
    movzx   eax, byte ptr [r12]
    inc     r12
    shl     eax, 4
    movdqu  xmm0, [r13+rax]
    movdqu  [rbx], xmm0
    add     rbx, 16
    jmp     .Lvm_next
vm_setl:
    movzx   eax, byte ptr [r12]
    inc     r12
    shl     eax, 4
    sub     rbx, 16
    movdqu  xmm0, [rbx]
    movdqu  [r13+rax], xmm0
    jmp     .Lvm_next

.macro NUM2
    sub     rbx, 16
    cmp     dword ptr [rbx], T_NUM
    jne     .Lvm_arith
    cmp     dword ptr [rbx-16], T_NUM
    jne     .Lvm_arith
    movsd   xmm0, [rbx-8]
    movsd   xmm1, [rbx+8]
.endm

vm_add:
    sub     rbx, 16
    cmp     dword ptr [rbx], T_NUM
    jne     1f
    cmp     dword ptr [rbx-16], T_NUM
    jne     1f
    movsd   xmm0, [rbx-8]
    addsd   xmm0, [rbx+8]
    movsd   [rbx-8], xmm0
    jmp     .Lvm_next
1:  cmp     dword ptr [rbx], T_STR      # a text on either side: join
    je      2f
    cmp     dword ptr [rbx-16], T_STR
    jne     3f
2:  lea     rdi, [rbx-16]
    mov     rsi, rbx
    call    val_concat
    mov     qword ptr [rbx-16], T_STR
    mov     [rbx-8], rax
    jmp     .Lvm_next
3:  lea     rdi, [rip+e_add]
    xor     esi, esi
    jmp     sc_rt
vm_sub:
    NUM2
    subsd   xmm0, xmm1
    movsd   [rbx-8], xmm0
    jmp     .Lvm_next
vm_mul:
    NUM2
    mulsd   xmm0, xmm1
    movsd   [rbx-8], xmm0
    jmp     .Lvm_next
vm_div:
    NUM2
    xorpd   xmm2, xmm2
    ucomisd xmm1, xmm2
    je      .Lvm_div0
    divsd   xmm0, xmm1
    movsd   [rbx-8], xmm0
    jmp     .Lvm_next
vm_mod:
    NUM2                                # a - floor(a / b) * b
    xorpd   xmm2, xmm2
    ucomisd xmm1, xmm2
    je      .Lvm_div0
    movapd  xmm2, xmm0
    divsd   xmm2, xmm1
    roundsd xmm2, xmm2, 1
    mulsd   xmm2, xmm1
    subsd   xmm0, xmm2
    movsd   [rbx-8], xmm0
    jmp     .Lvm_next
vm_neg:
    cmp     dword ptr [rbx-16], T_NUM
    jne     .Lvm_arith
    movsd   xmm0, [rbx-8]
    xorpd   xmm0, [rip+f_sign]
    movsd   [rbx-8], xmm0
    jmp     .Lvm_next
vm_not:
    lea     rdi, [rbx-16]
    call    truthy
    xor     eax, 1
    jmp     .Lvm_bool
vm_eq:
    sub     rbx, 16
    lea     rdi, [rbx-16]
    mov     rsi, rbx
    call    val_eq
    jmp     .Lvm_bool
vm_ne:
    sub     rbx, 16
    lea     rdi, [rbx-16]
    mov     rsi, rbx
    call    val_eq
    xor     eax, 1
    jmp     .Lvm_bool
vm_lt:
    sub     rbx, 16
    call    cmp2
    setb    al
    jmp     .Lvm_cmp
vm_le:
    sub     rbx, 16
    call    cmp2
    setbe   al
    jmp     .Lvm_cmp
vm_gt:
    sub     rbx, 16
    call    cmp2
    seta    al
    jmp     .Lvm_cmp
vm_ge:
    sub     rbx, 16
    call    cmp2
    setae   al
.Lvm_cmp:
    movzx   eax, al
.Lvm_bool:                              # replace the top with 1 / 0
    cvtsi2sd xmm0, eax
    mov     qword ptr [rbx-16], T_NUM
    movsd   [rbx-8], xmm0
    jmp     .Lvm_next
.Lvm_arith:
    lea     rdi, [rip+e_arith]
    xor     esi, esi
    jmp     sc_rt
.Lvm_div0:
    lea     rdi, [rip+e_div0]
    xor     esi, esi
    jmp     sc_rt

# cmp2 - compare the numbers at [rbx-16] and [rbx]: flags from ucomisd
cmp2:
    cmp     dword ptr [rbx], T_NUM
    jne     1f
    cmp     dword ptr [rbx-16], T_NUM
    jne     1f
    movsd   xmm0, [rbx-8]
    ucomisd xmm0, [rbx+8]
    ret
1:  lea     rdi, [rip+e_cmp]
    xor     esi, esi
    jmp     sc_rt

vm_jmp:
    movsxd  rax, dword ptr [r12]
    lea     r12, [r12+rax+4]
    jmp     .Lvm_next
vm_jf:
    sub     rbx, 16
    mov     rdi, rbx
    call    truthy
    test    eax, eax
    jnz     1f
    movsxd  rax, dword ptr [r12]
    lea     r12, [r12+rax+4]
    jmp     .Lvm_next
1:  add     r12, 4
    jmp     .Lvm_next
vm_jfk:
    lea     rdi, [rbx-16]
    call    truthy
    test    eax, eax
    jnz     1f
    movsxd  rax, dword ptr [r12]
    lea     r12, [r12+rax+4]
    jmp     .Lvm_next
1:  sub     rbx, 16
    add     r12, 4
    jmp     .Lvm_next
vm_jtk:
    lea     rdi, [rbx-16]
    call    truthy
    test    eax, eax
    jz      1f
    movsxd  rax, dword ptr [r12]
    lea     r12, [r12+rax+4]
    jmp     .Lvm_next
1:  sub     rbx, 16
    add     r12, 4
    jmp     .Lvm_next
vm_callb:
    VCHK
    movzx   eax, byte ptr [r12]
    movzx   esi, byte ptr [r12+1]
    add     r12, 2
    mov     ecx, esi
    shl     rcx, 4
    sub     rbx, rcx                    # rbx = first argument = result slot
    imul    eax, eax, B_SZ
    lea     rcx, [rip+builtins]
    mov     rdi, rbx
    call    [rcx+rax+8]
    mov     [rbx], rax
    mov     [rbx+8], rdx
    add     rbx, 16
    jmp     .Lvm_next
vm_callf:
    movzx   eax, word ptr [r12]
    movzx   ecx, byte ptr [r12+2]
    add     r12, 3
    imul    eax, eax, F_SZ
    lea     rdx, [rip+fntab]
    add     rdx, rax                    # function record
    cmp     qword ptr [rdx+32], 0
    je      .Lcf_undef
    movzx   eax, byte ptr [rdx+40]
    cmp     ecx, eax
    jne     .Lcf_args
    lea     rax, [rip+frames+(FR_N-1)*16]
    cmp     r15, rax
    jae     .Lcf_deep
    mov     [r15], r12
    mov     [r15+8], r13
    add     r15, 16
    shl     ecx, 4
    mov     r13, rbx
    sub     r13, rcx                    # locals start at the first argument
    movzx   ecx, byte ptr [rdx+41]
    movzx   eax, byte ptr [rdx+40]
    sub     ecx, eax                    # plain locals start as nil
    mov     eax, ecx
    shl     eax, 4
    lea     rsi, [rbx+rax]
    lea     rax, [rip+vstack+(VS_N-4)*16]
    cmp     rsi, rax
    jae     .Lvm_stack
1:  test    ecx, ecx
    jz      2f
    mov     qword ptr [rbx], T_NIL
    mov     qword ptr [rbx+8], 0
    add     rbx, 16
    dec     ecx
    jmp     1b
2:  mov     r12, [rdx+32]
    jmp     .Lvm_next
.Lcf_undef:
    lea     rdi, [rip+e_nofn]
    mov     rsi, rdx
    jmp     sc_rt
.Lcf_args:
    lea     rdi, [rip+e_fn_args]
    mov     rsi, rdx
    jmp     sc_rt
.Lcf_deep:
    lea     rdi, [rip+e_recursion]
    xor     esi, esi
    jmp     sc_rt
vm_ret:
    sub     rbx, 16
    mov     rax, [rbx]
    mov     rdx, [rbx+8]
    lea     rcx, [rip+frames]
    cmp     r15, rcx
    je      1f
    sub     r15, 16
    mov     rbx, r13
    mov     r12, [r15]
    mov     r13, [r15+8]
    mov     [rbx], rax
    mov     [rbx+8], rdx
    add     rbx, 16
    jmp     .Lvm_next
1:  mov     [rip+sc_result], rax        # return at the top level ends the run
    mov     [rip+sc_result+8], rdx
    jmp     .Lvm_done
vm_pop:
    sub     rbx, 16
    jmp     .Lvm_next
vm_popr:
    sub     rbx, 16
    movdqu  xmm0, [rbx]
    movdqu  [rip+sc_result], xmm0
    jmp     .Lvm_next
vm_clrr:
    mov     qword ptr [rip+sc_result], T_NIL
    jmp     .Lvm_next

# truthy(rdi=value) -> eax: nil, 0 and "" are false
truthy:
    mov     eax, [rdi]
    cmp     eax, T_NUM
    jne     1f
    movsd   xmm0, [rdi+8]
    xorpd   xmm1, xmm1
    ucomisd xmm0, xmm1
    jp      3f
    jne     3f
    xor     eax, eax
    ret
1:  cmp     eax, T_STR
    jne     2f
    mov     rax, [rdi+8]
    cmp     byte ptr [rax], 0
    setne   al
    movzx   eax, al
    ret
2:  xor     eax, eax
    ret
3:  mov     eax, 1
    ret

# val_eq(rdi=a, rsi=b) -> eax
val_eq:
    mov     eax, [rdi]
    cmp     eax, [rsi]
    jne     2f
    cmp     eax, T_NUM
    je      1f
    cmp     eax, T_STR
    jne     3f
    mov     rdi, [rdi+8]
    mov     rsi, [rsi+8]
    jmp     str_eq
1:  movsd   xmm0, [rdi+8]
    ucomisd xmm0, [rsi+8]
    jp      2f
    jne     2f
3:  mov     eax, 1
    ret
2:  xor     eax, eax
    ret

# =============================================================================
#  Text: formatting and the text heap
# =============================================================================
# numfmt(xmm0) -> rax = nbuf (asciz), edx = length
#   integers plainly, else up to 6 decimals; huge / tiny as 1.5e20
numfmt:
    push    rbx
    push    r12
    push    r13
    lea     rbx, [rip+nbuf]
    ucomisd xmm0, xmm0
    jp      .Lnf_nan
    xorpd   xmm1, xmm1
    ucomisd xmm0, xmm1
    jne     1f
    mov     byte ptr [rbx], '0'
    inc     rbx
    jmp     .Lnf_end
1:  ja      2f
    mov     byte ptr [rbx], '-'
    inc     rbx
    andpd   xmm0, [rip+f_abs]
2:  ucomisd xmm0, [rip+f_inf]
    ja      .Lnf_inf
    ucomisd xmm0, [rip+f_1e15]
    jae     .Lnf_sci
    ucomisd xmm0, [rip+f_1em4]
    jb      .Lnf_sci
    roundsd xmm1, xmm0, 3               # integer part
    subsd   xmm0, xmm1
    mulsd   xmm0, [rip+f_1e6]
    roundsd xmm0, xmm0, 0
    cvttsd2si r12, xmm0                 # 6 decimals
    cvttsd2si rax, xmm1
    cmp     r12, 1000000
    jb      3f
    inc     rax
    sub     r12, 1000000
3:  call    put_u64
    test    r12, r12
    jz      .Lnf_end
    call    put_frac6
    jmp     .Lnf_end
.Lnf_sci:
    xor     r13d, r13d                  # exponent
    movsd   xmm2, [rip+f_ten]
4:  ucomisd xmm0, xmm2
    jb      5f
    divsd   xmm0, xmm2
    inc     r13d
    jmp     4b
5:  ucomisd xmm0, [rip+f_one]
    jae     6f
    mulsd   xmm0, xmm2
    dec     r13d
    jmp     5b
6:  mulsd   xmm0, [rip+f_1e6]
    roundsd xmm0, xmm0, 0
    cvttsd2si rax, xmm0                 # 1000000 .. 10000000
    cmp     rax, 10000000
    jb      7f
    xor     edx, edx
    mov     ecx, 10
    div     rcx
    inc     r13d
7:  xor     edx, edx
    mov     ecx, 1000000
    div     rcx
    mov     r12, rdx
    call    put_u64
    test    r12, r12
    jz      8f
    call    put_frac6
8:  mov     byte ptr [rbx], 'e'
    inc     rbx
    mov     eax, r13d
    test    eax, eax
    jns     9f
    mov     byte ptr [rbx], '-'
    inc     rbx
    neg     eax
9:  call    put_u64
    jmp     .Lnf_end
.Lnf_nan:
    lea     rsi, [rip+s_nan]
    jmp     10f
.Lnf_inf:
    lea     rsi, [rip+s_infv]
10: mov     al, [rsi]
    test    al, al
    jz      .Lnf_end
    mov     [rbx], al
    inc     rbx
    inc     rsi
    jmp     10b
.Lnf_end:
    mov     byte ptr [rbx], 0
    lea     rax, [rip+nbuf]
    mov     rdx, rbx
    sub     rdx, rax
    pop     r13
    pop     r12
    pop     rbx
    ret

# put_u64(rax=value) - decimal at rbx, advancing it
put_u64:
    lea     rsi, [rip+dig_tmp+24]
    mov     ecx, 10
1:  xor     edx, edx
    div     rcx
    add     dl, '0'
    dec     rsi
    mov     [rsi], dl
    test    rax, rax
    jnz     1b
    lea     rcx, [rip+dig_tmp+24]
2:  cmp     rsi, rcx
    jae     3f
    mov     al, [rsi]
    mov     [rbx], al
    inc     rbx
    inc     rsi
    jmp     2b
3:  ret

# put_frac6(r12=1..999999) - ".dddddd" without trailing zeros at rbx
put_frac6:
    mov     byte ptr [rbx], '.'
    mov     rax, r12
    mov     ecx, 10
    mov     r8d, 6
1:  xor     edx, edx
    div     rcx
    add     dl, '0'
    mov     [rbx+r8], dl
    dec     r8d
    jnz     1b
    add     rbx, 7
2:  cmp     byte ptr [rbx-1], '0'
    jne     3f
    dec     rbx
    jmp     2b
3:  ret

# val_to(rdi=value, rsi=dest, rdx=end) -> rax = dest after the text (bounded)
val_to:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rsi
    mov     r12, rdx
    mov     eax, [rdi]
    cmp     eax, T_NUM
    jne     1f
    movsd   xmm0, [rdi+8]
    call    numfmt
    mov     rsi, rax
    jmp     3f
1:  cmp     eax, T_STR
    jne     2f
    mov     rsi, [rdi+8]
    jmp     3f
2:  lea     rsi, [rip+s_nil]
3:  mov     al, [rsi]
    test    al, al
    jz      4f
    cmp     rbx, r12
    jae     4f
    mov     [rbx], al
    inc     rbx
    inc     rsi
    jmp     3b
4:  mov     rax, rbx
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# sh_val(rdi=value) - append its text to the text heap
sh_val:
    mov     rsi, [rip+sh_pos]
    mov     rdx, [rip+sh_end]
    sub     rsp, 8
    call    val_to
    add     rsp, 8
    cmp     rax, [rip+sh_end]
    jae     sh_full
    mov     [rip+sh_pos], rax
    ret
sh_full:
    lea     rdi, [rip+e_strmem]
    xor     esi, esi
    jmp     sc_rt

# sh_nul - terminate the text being built
sh_nul:
    mov     rax, [rip+sh_pos]
    cmp     rax, [rip+sh_end]
    jae     sh_full
    mov     byte ptr [rax], 0
    inc     rax
    mov     [rip+sh_pos], rax
    ret

# val_concat(rdi=a, rsi=b) -> rax = new text "ab"
val_concat:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13, [rip+sh_pos]
    mov     rdi, rbx
    call    sh_val
    mov     rdi, r12
    call    sh_val
    call    sh_nul
    mov     rax, r13
    pop     r13
    pop     r12
    pop     rbx
    ret

# sh_dup(rsi=asciz) -> rax = copy in the text heap
sh_dup:
    mov     rax, [rip+sh_pos]
    mov     rdx, rax
    mov     rcx, [rip+sh_end]
1:  cmp     rdx, rcx
    jae     sh_full
    mov     r8b, [rsi]
    mov     [rdx], r8b
    inc     rdx
    inc     rsi
    test    r8b, r8b
    jnz     1b
    mov     [rip+sh_pos], rdx
    ret

# sh_compact - start a run with a fresh heap holding only the texts that
#   global variables still use (two halves, copy collector)
sh_compact:
    push    rbx
    push    r12
    push    r13
    lea     r12, [rip+sh_a]
    lea     rax, [rip+sh_b]
    cmp     [rip+sh_base], r12
    jne     1f
    mov     r12, rax
1:  mov     [rip+sh_base], r12
    lea     rax, [r12+SH_SIZE]
    mov     [rip+sh_end], rax
    mov     [rip+sh_pos], r12
    xor     ebx, ebx
2:  cmp     ebx, [rip+gcount]
    jae     5f
    mov     eax, ebx
    shl     eax, 4
    lea     r13, [rip+gvals]
    add     r13, rax
    cmp     dword ptr [r13], T_STR
    jne     4f
    mov     rsi, [r13+8]
    mov     rax, [rip+sh_pos]
    mov     rdx, rax
    mov     rcx, [rip+sh_end]
3:  cmp     rdx, rcx
    jae     6f
    mov     r8b, [rsi]
    mov     [rdx], r8b
    inc     rdx
    inc     rsi
    test    r8b, r8b
    jnz     3b
    mov     [rip+sh_pos], rdx
    mov     [r13+8], rax
4:  inc     ebx
    jmp     2b
6:  mov     qword ptr [r13], T_NIL      # no room: the variable becomes nil
    jmp     4b
5:  pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Builtins: handler(rdi=arguments, esi=count) -> rax = type, rdx = payload
# =============================================================================
a_num:
    cmp     dword ptr [rdi], T_NUM
    jne     1f
    movsd   xmm0, [rdi+8]
    ret
1:  lea     rdi, [rip+e_want_num]
    xor     esi, esi
    jmp     sc_rt

a_str:
    cmp     dword ptr [rdi], T_STR
    jne     1f
    mov     rax, [rdi+8]
    ret
1:  lea     rdi, [rip+e_want_str]
    xor     esi, esi
    jmp     sc_rt

# a_obj(rdi=value) -> eax = handle of the object with that name
a_obj:
    push    rbx
    call    a_str
    mov     rbx, rax
    mov     rdi, rax
    call    obj_find
    test    eax, eax
    jz      1f
    pop     rbx
    ret
1:  lea     rdi, [rip+e_no_obj]
    mov     rsi, rbx
    jmp     sc_rt

ret_num:
    movq    rdx, xmm0
    mov     eax, T_NUM
    ret
ret_nil:
    mov     eax, T_NIL
    xor     edx, edx
    ret
# ret_name(edi=handle) - its name as a text
ret_name:
    sub     rsp, 8
    call    obj_get
    mov     rsi, rax
    call    sh_dup
    mov     rdx, rax
    mov     eax, T_STR
    add     rsp, 8
    ret

b_print:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12d, esi
    lea     r13, [rip+ln_buf]
    xor     ecx, ecx
1:  cmp     ecx, r12d
    jae     3f
    test    ecx, ecx
    jz      2f
    mov     byte ptr [r13], ' '
    inc     r13
2:  push    rcx
    mov     eax, ecx
    shl     eax, 4
    lea     rdi, [rbx+rax]
    mov     rsi, r13
    lea     rdx, [rip+ln_buf+LN_MAX-2]
    sub     rsp, 8
    call    val_to
    add     rsp, 8
    mov     r13, rax
    pop     rcx
    inc     ecx
    jmp     1b
3:  mov     byte ptr [r13], 0
    lea     rdi, [rip+ln_buf]
    call    sc_print
    pop     r13
    pop     r12
    pop     rbx
    jmp     ret_nil

b_str:
    push    rbx
    mov     rbx, [rip+sh_pos]
    call    sh_val
    call    sh_nul
    mov     rdx, rbx
    mov     eax, T_STR
    pop     rbx
    ret

b_num:
    cmp     dword ptr [rdi], T_NUM
    jne     1f
    mov     eax, T_NUM
    mov     rdx, [rdi+8]
    ret
1:  sub     rsp, 8
    call    a_str
    add     rsp, 8
    mov     rsi, rax
2:  cmp     byte ptr [rsi], ' '
    jne     3f
    inc     rsi
    jmp     2b
3:  xor     r9d, r9d                    # sign
    cmp     byte ptr [rsi], '-'
    jne     4f
    inc     rsi
    mov     r9d, 1
4:  push    r9
    call    parse_num
    pop     r9
    test    eax, eax
    jnz     ret_nil
    cmp     byte ptr [rsi], 0
    jne     ret_nil
    test    r9d, r9d
    jz      ret_num
    xorpd   xmm0, [rip+f_sign]
    jmp     ret_num

b_len:
    sub     rsp, 8
    call    a_str
    mov     rdi, rax
    call    str_len
    cvtsi2sd xmm0, eax
    add     rsp, 8
    jmp     ret_num

b_sin:
    sub     rsp, 8
    call    a_num
    movsd   [rsp], xmm0
    fld     qword ptr [rsp]
    fsin
    jmp     x87_out
b_cos:
    sub     rsp, 8
    call    a_num
    movsd   [rsp], xmm0
    fld     qword ptr [rsp]
    fcos
    jmp     x87_out
b_tan:
    sub     rsp, 8
    call    a_num
    movsd   [rsp], xmm0
    fld     qword ptr [rsp]
    fptan
    fstp    st(0)
x87_out:
    fstp    qword ptr [rsp]
    movsd   xmm0, [rsp]
    add     rsp, 8
    jmp     ret_num
b_sqrt:
    sub     rsp, 8
    call    a_num
    add     rsp, 8
    sqrtsd  xmm0, xmm0
    jmp     ret_num
b_abs:
    sub     rsp, 8
    call    a_num
    add     rsp, 8
    andpd   xmm0, [rip+f_abs]
    jmp     ret_num
b_floor:
    sub     rsp, 8
    call    a_num
    add     rsp, 8
    roundsd xmm0, xmm0, 1
    jmp     ret_num
b_round:
    sub     rsp, 8
    call    a_num
    add     rsp, 8
    addsd   xmm0, [rip+f_half]
    roundsd xmm0, xmm0, 1
    jmp     ret_num
b_deg:
    sub     rsp, 8
    call    a_num
    add     rsp, 8
    mulsd   xmm0, [rip+f_r2d]
    jmp     ret_num
b_rad:
    sub     rsp, 8
    call    a_num
    add     rsp, 8
    mulsd   xmm0, [rip+f_d2r]
    jmp     ret_num

# b_min / b_max - over all arguments
b_min:
    xor     eax, eax
    jmp     minmax
b_max:
    mov     eax, 1
minmax:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 16
    mov     rbx, rdi
    mov     r12d, esi
    mov     r13d, eax
    call    a_num
    movsd   [rsp], xmm0
    mov     ecx, 1
1:  cmp     ecx, r12d
    jae     3f
    mov     [rsp+8], ecx
    mov     eax, ecx
    shl     eax, 4
    lea     rdi, [rbx+rax]
    call    a_num
    mov     ecx, [rsp+8]
    test    r13d, r13d
    jnz     2f
    minsd   xmm0, [rsp]
    movsd   [rsp], xmm0
    inc     ecx
    jmp     1b
2:  maxsd   xmm0, [rsp]
    movsd   [rsp], xmm0
    inc     ecx
    jmp     1b
3:  movsd   xmm0, [rsp]
    add     rsp, 16
    pop     r13
    pop     r12
    pop     rbx
    jmp     ret_num

# pow(x, y): exact for whole y, else 2^(y*log2 x)
b_pow:
    push    rbx
    sub     rsp, 16
    mov     rbx, rdi
    call    a_num
    movsd   [rsp], xmm0                 # x
    lea     rdi, [rbx+16]
    call    a_num
    movsd   [rsp+8], xmm0               # y
    roundsd xmm1, xmm0, 3
    ucomisd xmm1, xmm0
    jne     5f
    jp      5f
    cvttsd2si rax, xmm0
    mov     rcx, rax
    test    rcx, rcx
    jns     1f
    neg     rcx
1:  cmp     rcx, 1048576
    ja      5f
    movsd   xmm0, [rip+f_one]           # square and multiply
    movsd   xmm1, [rsp]
2:  test    rcx, rcx
    jz      4f
    test    ecx, 1
    jz      3f
    mulsd   xmm0, xmm1
3:  mulsd   xmm1, xmm1
    shr     rcx, 1
    jmp     2b
4:  test    rax, rax
    jns     9f
    movsd   xmm1, [rip+f_one]
    divsd   xmm1, xmm0
    movapd  xmm0, xmm1
    jmp     9f
5:  movsd   xmm0, [rsp]
    xorpd   xmm1, xmm1
    ucomisd xmm0, xmm1
    je      9f                          # 0^y = 0
    fld     qword ptr [rsp+8]           # y
    fld     qword ptr [rsp]             # x
    fyl2x                               # t = y * log2(x)
    fld     st(0)
    frndint                             # n
    fsub    st(1), st(0)                # st1 = t - n
    fxch    st(1)
    f2xm1
    fld1
    faddp   st(1), st(0)                # 2^(t-n)
    fscale
    fstp    st(1)
    fstp    qword ptr [rsp]
    movsd   xmm0, [rsp]
9:  add     rsp, 16
    pop     rbx
    jmp     ret_num

b_atan2:
    push    rbx
    sub     rsp, 16
    mov     rbx, rdi
    call    a_num
    movsd   [rsp], xmm0                 # y
    lea     rdi, [rbx+16]
    call    a_num
    movsd   [rsp+8], xmm0               # x
    fld     qword ptr [rsp]
    fld     qword ptr [rsp+8]
    fpatan
    fstp    qword ptr [rsp]
    movsd   xmm0, [rsp]
    add     rsp, 16
    pop     rbx
    jmp     ret_num

# rand() -> [0, 1) (xorshift64*, seed() makes runs repeatable)
b_rand:
    mov     rax, [rip+rng_state]
    mov     rcx, rax
    shr     rcx, 12
    xor     rax, rcx
    mov     rcx, rax
    shl     rcx, 25
    xor     rax, rcx
    mov     rcx, rax
    shr     rcx, 27
    xor     rax, rcx
    mov     [rip+rng_state], rax
    mov     rcx, 0x2545F4914F6CDD1D
    imul    rax, rcx
    shr     rax, 11
    cvtsi2sd xmm0, rax
    mulsd   xmm0, [rip+f_2m53]
    jmp     ret_num
b_seed:
    sub     rsp, 8
    call    a_num
    add     rsp, 8
    cvttsd2si rax, xmm0
    test    rax, rax
    jnz     1f
    mov     rax, 0x9E3779B97F4A7C15
1:  mov     [rip+rng_state], rax
    jmp     ret_nil

# add(type, [name], [x, y, z]) -> the new object's name
b_add:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    mov     rbx, rdi
    mov     r12d, esi
    cmp     r12d, 3
    je      .Ladd_usage
    mov     rdi, rbx
    call    a_str
    mov     r13, rax
    lea     rdi, [rip+opbuf]            # "create." + type
    lea     rsi, [rip+s_create_pfx]
1:  mov     al, [rsi]
    test    al, al
    jz      2f
    mov     [rdi], al
    inc     rdi
    inc     rsi
    jmp     1b
2:  mov     rsi, r13
    lea     rcx, [rip+opbuf+60]
3:  mov     al, [rsi]
    mov     [rdi], al
    test    al, al
    jz      4f
    inc     rdi
    inc     rsi
    cmp     rdi, rcx
    jb      3b
    mov     byte ptr [rdi], 0
4:  lea     rdi, [rip+opbuf]
    call    find_op_by_name
    test    rax, rax
    jz      .Ladd_type
    mov     r14, rax
    cmp     r12d, 4                     # location: the last three arguments
    jb      6f
    lea     eax, [r12-3]
    shl     eax, 4
    lea     r15, [rbx+rax]
    mov     rdi, r15
    call    a_num
    cvtsd2ss xmm0, xmm0
    movss   [rsp], xmm0
    lea     rdi, [r15+16]
    call    a_num
    cvtsd2ss xmm0, xmm0
    movss   [rsp+4], xmm0
    lea     rdi, [r15+32]
    call    a_num
    cvtsd2ss xmm0, xmm0
    movss   [rsp+8], xmm0
6:  xor     r15d, r15d                  # name (argument 2 when 2 or 5 given)
    cmp     r12d, 2
    je      7f
    cmp     r12d, 5
    jne     8f
7:  lea     rdi, [rbx+16]
    cmp     dword ptr [rdi], T_NIL
    je      8f
    call    a_str
    mov     r15, rax
8:  lea     rax, [rip+s_empty]
    mov     [rip+op_arg], rax
    mov     rdi, r14
    call    run_op
    mov     qword ptr [rip+op_arg], 0
    mov     r14d, [rip+active_obj]
    test    r15, r15
    jz      9f
    mov     edi, r14d
    mov     rsi, r15
    call    obj_rename
9:  cmp     r12d, 4
    jb      10f
    mov     edi, r14d
    call    obj_get
    test    rax, rax
    jz      10f
    mov     rcx, [rsp]
    mov     [rax+OB_LOC], rcx
    mov     ecx, [rsp+8]
    mov     [rax+OB_LOC+8], ecx
10: mov     edi, r14d
    call    ret_name
    add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
.Ladd_usage:
    lea     rdi, [rip+e_add_args]
    xor     esi, esi
    jmp     sc_rt
.Ladd_type:
    lea     rdi, [rip+e_bad_type]
    mov     rsi, r13
    jmp     sc_rt

# move / rotate / scale(name, x, y, z)  (scale(name, s) is uniform)
b_move:
    mov     edx, OB_LOC
    jmp     set3
b_rotate:
    mov     edx, OB_ROT
    jmp     set3
b_scale:
    mov     edx, OB_SCALE
set3:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 16
    mov     rbx, rdi
    mov     r12d, esi
    mov     r13d, edx
    cmp     r12d, 3
    je      .Ls3_usage
    lea     rdi, [rbx+16]
    call    a_num
    cvtsd2ss xmm0, xmm0
    movss   [rsp], xmm0
    movss   [rsp+4], xmm0
    movss   [rsp+8], xmm0
    cmp     r12d, 2
    je      1f
    lea     rdi, [rbx+32]
    call    a_num
    cvtsd2ss xmm0, xmm0
    movss   [rsp+4], xmm0
    lea     rdi, [rbx+48]
    call    a_num
    cvtsd2ss xmm0, xmm0
    movss   [rsp+8], xmm0
1:  mov     rdi, rbx
    call    a_obj
    mov     ebx, eax
    lea     rdi, [rip+s_script]
    call    undo_push
    mov     edi, ebx
    call    obj_get
    mov     rcx, [rsp]
    mov     [rax+r13], rcx
    mov     ecx, [rsp+8]
    mov     [rax+r13+8], ecx
    mov     dword ptr [rip+dirty], 1
    add     rsp, 16
    pop     r13
    pop     r12
    pop     rbx
    jmp     ret_nil
.Ls3_usage:
    lea     rdi, [rip+e_scale_args]
    xor     esi, esi
    jmp     sc_rt

# prop_off(rdi=value) -> eax = field offset of "x" / "ry" / "sz" ...
prop_off:
    push    rbx
    call    a_str
    mov     rbx, rax
    mov     rdi, rax
    call    str_len
    cmp     eax, 7
    ja      2f
    mov     ecx, eax
    mov     rsi, rbx
    call    pack8
    lea     rdi, [rip+props]
1:  lea     rcx, [rip+props_end]
    cmp     rdi, rcx
    jae     2f
    cmp     rax, [rdi]
    je      3f
    add     rdi, 16
    jmp     1b
3:  mov     eax, [rdi+8]
    pop     rbx
    ret
2:  lea     rdi, [rip+e_prop]
    mov     rsi, rbx
    jmp     sc_rt

b_get:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    lea     rdi, [rbx+16]
    call    prop_off
    mov     r12d, eax
    mov     rdi, rbx
    call    a_obj
    mov     edi, eax
    call    obj_get
    cvtss2sd xmm0, [rax+r12]
    add     rsp, 8
    pop     r12
    pop     rbx
    jmp     ret_num

b_set:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 16
    mov     rbx, rdi
    lea     rdi, [rbx+16]
    call    prop_off
    mov     r12d, eax
    lea     rdi, [rbx+32]
    call    a_num
    cvtsd2ss xmm0, xmm0
    movss   [rsp], xmm0
    mov     rdi, rbx
    call    a_obj
    mov     r13d, eax
    lea     rdi, [rip+s_script]
    call    undo_push
    mov     edi, r13d
    call    obj_get
    movss   xmm0, [rsp]
    movss   [rax+r12], xmm0
    mov     dword ptr [rip+dirty], 1
    add     rsp, 16
    pop     r13
    pop     r12
    pop     rbx
    jmp     ret_nil

# select(names...) - exactly these, the last one active; select() = none
b_select:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12d, esi
    xor     r13d, r13d                  # check every name first
1:  cmp     r13d, r12d
    jae     2f
    mov     eax, r13d
    shl     eax, 4
    lea     rdi, [rbx+rax]
    call    a_obj
    inc     r13d
    jmp     1b
2:  call    select_none
    mov     dword ptr [rip+active_obj], 0
    xor     r13d, r13d
3:  cmp     r13d, r12d
    jae     4f
    mov     eax, r13d
    shl     eax, 4
    lea     rdi, [rbx+rax]
    call    a_obj
    mov     [rip+active_obj], eax
    mov     edi, eax
    call    obj_get
    or      dword ptr [rax+OB_FLAGS], OBF_SELECTED
    inc     r13d
    jmp     3b
4:  mov     dword ptr [rip+dirty], 1
    pop     r13
    pop     r12
    pop     rbx
    jmp     ret_nil

# delete(names...)
b_delete:
    push    rbx
    sub     rsp, 16
    mov     [rsp], rdi
    mov     [rsp+8], esi
    call    b_select
    lea     rdi, [rip+s_del_op]
    call    find_op_by_name
    test    rax, rax
    jz      1f
    mov     rdi, rax
    call    run_op
1:  add     rsp, 16
    pop     rbx
    jmp     ret_nil

# rename(old, new) -> the name it got (unique, like Blender)
b_rename:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    lea     rdi, [rbx+16]
    call    a_str
    mov     r12, rax
    mov     rdi, rbx
    call    a_obj
    mov     r13d, eax
    lea     rdi, [rip+s_script]
    call    undo_push
    mov     edi, r13d
    mov     rsi, r12
    call    obj_rename
    mov     dword ptr [rip+dirty], 1
    mov     edi, r13d
    call    ret_name
    pop     r13
    pop     r12
    pop     rbx
    ret

b_exists:
    sub     rsp, 8
    call    a_str
    mov     rdi, rax
    call    obj_find
    add     rsp, 8
    xor     ecx, ecx
    test    eax, eax
    setnz   cl
    cvtsi2sd xmm0, ecx
    jmp     ret_num

b_count:
    cvtsi2sd xmm0, dword ptr [rip+obj_count]
    jmp     ret_num

# name(i) - the i-th object in the outliner (0-based)
b_name:
    sub     rsp, 8
    call    a_num
    cvttsd2si rax, xmm0
    test    rax, rax
    js      1f
    mov     ecx, [rip+obj_count]
    cmp     rax, rcx
    jae     1f
    lea     rcx, [rip+obj_list]
    mov     edi, [rcx+rax*4]
    add     rsp, 8
    jmp     ret_name
1:  lea     rdi, [rip+e_range]
    xor     esi, esi
    jmp     sc_rt

b_active:
    mov     edi, [rip+active_obj]
    test    edi, edi
    jz      ret_nil
    jmp     ret_name

# op(id, [argument]) - run an operator
b_op:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     r14, rdi
    mov     r12d, esi
    call    a_str
    mov     r13, rax
    mov     rdi, rax
    call    find_op_by_name
    test    rax, rax
    jz      .Lbop_unknown
    mov     rbx, rax
    mov     rdi, r13
    lea     rsi, [rip+s_pfx_script]
    call    has_prefix
    test    eax, eax
    jnz     .Lbop_script
    mov     rdi, r13
    lea     rsi, [rip+s_pfx_tm]
    call    has_prefix
    test    eax, eax
    jnz     .Lbop_modal
    mov     rdi, r13
    lea     rsi, [rip+s_undo_op]
    call    str_eq
    test    eax, eax
    jnz     .Lbop_undo
    mov     rdi, r13
    lea     rsi, [rip+s_redo_op]
    call    str_eq
    test    eax, eax
    jnz     .Lbop_undo
    cmp     dword ptr [rip+sc_agent], 0
    je      1f
    test    dword ptr [rbx+OP_FLAGS], OPF_AI_SAFE
    jz      .Lbop_agent
    mov     rdi, rbx                    # and the agent permission tier
    call    op_tier
    cmp     eax, [rip+agent_tier]
    ja      .Lbop_perm
1:  mov     byte ptr [rip+op_argbuf], 0
    cmp     r12d, 2
    jb      2f
    lea     rdi, [r14+16]               # the argument as text
    lea     rsi, [rip+op_argbuf]
    lea     rdx, [rip+op_argbuf+512]
    call    val_to
    mov     byte ptr [rax], 0
2:  lea     rax, [rip+op_argbuf]
    mov     [rip+op_arg], rax
    mov     rdi, rbx
    call    run_op
    mov     qword ptr [rip+op_arg], 0
    add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    jmp     ret_nil
.Lbop_unknown:
    lea     rdi, [rip+e_no_op]
    jmp     2f
.Lbop_script:
    lea     rdi, [rip+e_op_script]
    jmp     2f
.Lbop_modal:
    lea     rdi, [rip+e_op_modal]
    jmp     2f
.Lbop_undo:
    lea     rdi, [rip+e_op_undo]
    jmp     2f
.Lbop_perm:
    lea     rdi, [rip+e_op_perm]
    jmp     2f
.Lbop_agent:
    lea     rdi, [rip+e_op_agent]
2:  mov     rsi, r13
    jmp     sc_rt

# a_mesh(rdi=value) -> rax = mesh of the named mesh object, ecx = handle
a_mesh:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    call    a_obj
    mov     r12d, eax
    mov     edi, eax
    call    obj_get
    cmp     dword ptr [rax+OB_TYPE], OT_MESH
    jne     1f
    mov     rax, [rax+OB_MESH]
    mov     ecx, r12d
    add     rsp, 8
    pop     r12
    pop     rbx
    ret
1:  lea     rdi, [rip+e_not_mesh]
    mov     rsi, [rbx+8]
    jmp     sc_rt

# edit(name) - edit mode on that mesh (it becomes active); edit() leaves it
b_edit:
    sub     rsp, 8
    test    esi, esi
    jnz     1f
    call    edit_exit
    add     rsp, 8
    jmp     ret_nil
1:  call    a_mesh
    mov     [rip+active_obj], ecx
    mov     [rip+edit_obj], ecx
    mov     dword ptr [rip+dirty], 1
    add     rsp, 8
    jmp     ret_nil

b_verts:
    mov     edx, ME_NVERTS
    jmp     mesh_count
b_edges:
    mov     edx, ME_NEDGES
    jmp     mesh_count
b_faces:
    mov     edx, ME_NPOLYS
mesh_count:
    push    rdx
    call    a_mesh
    pop     rdx
    cvtsi2sd xmm0, dword ptr [rax+rdx]
    jmp     ret_num

# selected(name) - how many vertices are selected (edit mode selection)
b_selected:
    sub     rsp, 8
    call    a_mesh
    add     rsp, 8
    mov     rdx, [rax+ME_VSEL]
    mov     ecx, [rax+ME_NVERTS]
    xor     eax, eax
1:  test    ecx, ecx
    jz      2f
    dec     ecx
    movzx   r8d, byte ptr [rdx+rcx]
    add     eax, r8d
    jmp     1b
2:  cvtsi2sd xmm0, eax
    jmp     ret_num

# vidx(rdi=value, rsi=mesh) -> eax = vertex index (checked)
vidx:
    push    rsi
    call    a_num
    pop     rsi
    cvttsd2si rax, xmm0
    test    rax, rax
    js      1f
    mov     ecx, [rsi+ME_NVERTS]
    cmp     rax, rcx
    jae     1f
    ret
1:  lea     rdi, [rip+e_range]
    xor     esi, esi
    jmp     sc_rt

# vpos(name, i, axis) - a vertex coordinate (object space); axis 0-2 or "x"..
b_vpos:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    call    a_mesh
    mov     r12, rax
    lea     rdi, [rbx+16]
    mov     rsi, r12
    call    vidx
    mov     r13d, eax
    lea     rdi, [rbx+32]               # axis
    cmp     dword ptr [rdi], T_STR
    jne     1f
    mov     rax, [rdi+8]
    movzx   eax, byte ptr [rax]
    sub     eax, 'x'
    jmp     2f
1:  call    a_num
    cvttsd2si eax, xmm0
2:  cmp     eax, 2
    ja      3f
    mov     rcx, [r12+ME_POS]
    lea     rdx, [r13+r13*2]
    add     rdx, rax
    cvtss2sd xmm0, [rcx+rdx*4]
    pop     r13
    pop     r12
    pop     rbx
    jmp     ret_num
3:  lea     rdi, [rip+e_axis]
    xor     esi, esi
    jmp     sc_rt

# a_meshobj(rdi=value) -> rax = the named mesh object
a_meshobj:
    push    rbx
    mov     rbx, rdi
    call    a_mesh                      # checks it is a mesh
    mov     edi, ecx
    call    obj_get
    pop     rbx
    ret

# modifier(name, type) -> index of the new modifier
b_modifier:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    lea     rdi, [rbx+16]
    call    a_str
    mov     r12, rax
    mov     rdi, rax
    call    type_by_name
    test    eax, eax
    jz      1f
    mov     r13d, eax
    mov     rdi, rbx
    call    a_meshobj
    mov     rbx, rax
    lea     rdi, [rip+s_script]
    call    undo_push
    mov     rdi, rbx
    mov     esi, r13d
    call    mod_add
    test    eax, eax
    js      2f
    cvtsi2sd xmm0, eax
    pop     r13
    pop     r12
    pop     rbx
    jmp     ret_num
1:  lea     rdi, [rip+e_modtype]
    mov     rsi, r12
    jmp     sc_rt
2:  lea     rdi, [rip+e_modidx]
    xor     esi, esi
    jmp     sc_rt

# modset(name, index, parameter, value) - parameter by name or number
b_modset:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     rbx, rdi
    lea     rdi, [rbx+48]               # a name: an object (its handle)
    cmp     dword ptr [rdi], T_STR
    jne     3f
    call    a_obj
    movd    xmm0, eax
    jmp     4f
3:  call    a_num
    cvtsd2ss xmm0, xmm0
4:  movss   [rsp], xmm0
    lea     rdi, [rbx+16]
    call    a_num
    cvttsd2si r13d, xmm0                # index
    mov     rdi, rbx
    call    a_meshobj
    mov     r12, rax
    mov     rdi, r12
    mov     esi, r13d
    call    stack_index
    test    rax, rax
    jz      8f
    mov     r14, rax
    lea     rdi, [rbx+32]               # parameter: text or number
    cmp     dword ptr [rdi], T_STR
    jne     1f
    mov     rsi, [rdi+8]
    mov     rdi, r14
    call    mod_param_index
    jmp     2f
1:  call    a_num
    cvttsd2si eax, xmm0
2:  test    eax, eax
    js      8f
    push    rax
    lea     rdi, [rip+s_script]
    call    undo_push
    pop     rdx
    mov     rdi, r12
    mov     esi, r13d
    movss   xmm0, [rsp]
    call    mod_param_set
    test    eax, eax
    jz      8f
    add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    jmp     ret_nil
8:  lea     rdi, [rip+e_modidx]
    xor     esi, esi
    jmp     sc_rt

# modapply(name, index) / modremove(name, index)
b_modapply:
    lea     rax, [rip+mod_apply]
    jmp     mod_index_call
b_modremove:
    lea     rax, [rip+mod_remove]
mod_index_call:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r13, rax
    lea     rdi, [rbx+16]
    call    a_num
    cvttsd2si r12d, xmm0
    mov     rdi, rbx
    call    a_meshobj
    mov     rbx, rax
    lea     rdi, [rip+s_script]
    call    undo_push
    mov     rdi, rbx
    mov     esi, r12d
    call    r13
    test    eax, eax
    jz      8f
    pop     r13
    pop     r12
    pop     rbx
    jmp     ret_nil
8:  lea     rdi, [rip+e_modidx]
    xor     esi, esi
    jmp     sc_rt

b_modcount:
    sub     rsp, 8
    call    a_meshobj
    add     rsp, 8
    xor     ecx, ecx
    mov     rax, [rax+OB_MODS]
    test    rax, rax
    jz      1f
    mov     ecx, [rax+4]
1:  cvtsi2sd xmm0, ecx
    jmp     ret_num

# everts(name) / efaces(name) - after modifiers
b_everts:
    mov     edx, ME_NVERTS
    jmp     eval_count
b_efaces:
    mov     edx, ME_NPOLYS
eval_count:
    push    rdx
    call    a_meshobj
    mov     rdi, rax
    call    obj_eval
    pop     rdx
    cvtsi2sd xmm0, dword ptr [rax+rdx]
    jmp     ret_num

# vmove(name, i, x, y, z) - move a vertex (object space). The mesh is copied
#   first if an undo step or another object shares it; edits in place bump
#   its version so modifiers re-evaluate.
# boolean(a, b, kind) - a becomes a (op) b, b is deleted
b_boolean:
    push    rbx
    sub     rsp, 32
    mov     rbx, rdi
    movdqu  xmm0, [rbx+16]              # select(b, a): a is active
    movdqu  [rsp], xmm0
    movdqu  xmm0, [rbx]
    movdqu  [rsp+16], xmm0
    lea     rdi, [rsp]
    mov     esi, 2
    call    b_select
    lea     rdi, [rip+s_bool_op]
    call    find_op_by_name
    mov     [rsp], rax
    cmp     dword ptr [rip+sc_agent], 0
    je      1f
    mov     rdi, rax
    call    op_tier
    cmp     eax, [rip+agent_tier]
    ja      8f
1:  lea     rdi, [rbx+32]               # the kind as text
    lea     rsi, [rip+op_argbuf]
    lea     rdx, [rip+op_argbuf+512]
    call    val_to
    mov     byte ptr [rax], 0
    lea     rax, [rip+op_argbuf]
    mov     [rip+op_arg], rax
    mov     rdi, [rsp]
    call    run_op
    mov     qword ptr [rip+op_arg], 0
    add     rsp, 32
    pop     rbx
    jmp     ret_nil
8:  lea     rdi, [rip+e_op_perm]
    lea     rsi, [rip+s_bool_op]
    jmp     sc_rt

# material(name) -> name: the material with that name, created if missing
b_material:
    push    rbx
    push    r12
    sub     rsp, 8
    call    a_str
    mov     r12, rax
    mov     rdi, rax
    call    mat_find
    test    eax, eax
    jns     1f
    lea     rdi, [rip+s_script]
    call    undo_push
    mov     rdi, r12
    call    mat_new
    test    eax, eax
    js      8f
1:  mov     edi, eax
    call    mat_get
    mov     rsi, rax
    call    sh_dup
    mov     rdx, rax
    mov     eax, T_STR
    add     rsp, 8
    pop     r12
    pop     rbx
    ret
8:  lea     rdi, [rip+e_mat_full]
    xor     esi, esi
    jmp     sc_rt

# a_mat(rdi=value) -> eax = material index (error if there is none)
a_mat:
    push    rbx
    call    a_str
    mov     rbx, rax
    mov     rdi, rax
    call    mat_find
    test    eax, eax
    js      1f
    pop     rbx
    ret
1:  lea     rdi, [rip+e_no_mat]
    mov     rsi, rbx
    jmp     sc_rt

# a_mparam(rdi=value) -> eax = parameter index
a_mparam:
    push    rbx
    call    a_str
    mov     rbx, rax
    mov     rdi, rax
    call    mat_param_index
    test    eax, eax
    js      1f
    pop     rbx
    ret
1:  lea     rdi, [rip+e_mat_param]
    mov     rsi, rbx
    jmp     sc_rt

# matset(material, parameter, value [, value, value]) - colours take three
b_matset:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rbx, rdi
    mov     r15d, esi                   # argument count
    call    a_mat
    mov     r12d, eax
    lea     rdi, [rbx+16]
    call    a_mparam
    mov     r13d, eax
    lea     rdi, [rip+s_script]
    call    undo_push
    xor     r14d, r14d                  # components
1:  lea     eax, [r14+2]
    cmp     eax, r15d
    jae     9f
    mov     eax, r14d
    shl     eax, 4
    lea     rdi, [rbx+32+rax]
    call    a_num
    cvtsd2ss xmm0, xmm0
    mov     edi, r12d
    mov     esi, r13d
    mov     edx, r14d
    call    mat_set
    inc     r14d
    jmp     1b
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    jmp     ret_nil

# matget(material, parameter [, component]) -> number
b_matget:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    xor     r13d, r13d
    cmp     esi, 3
    jb      1f
    lea     rdi, [rbx+32]
    call    a_num
    cvttsd2si r13d, xmm0
1:  mov     rdi, rbx
    call    a_mat
    mov     r12d, eax
    lea     rdi, [rbx+16]
    call    a_mparam
    mov     edi, r12d
    mov     esi, eax
    mov     edx, r13d
    call    mat_param_get
    cvtss2sd xmm0, xmm0
    pop     r13
    pop     r12
    pop     rbx
    jmp     ret_num

# assign(object, material) - "" or nil: no material
b_assign:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    call    a_meshobj
    mov     r12, rax
    mov     esi, -1
    lea     rdi, [rbx+16]
    cmp     dword ptr [rdi], T_STR
    jne     1f
    mov     rax, [rdi+8]
    cmp     byte ptr [rax], 0
    je      1f
    call    a_mat
    mov     esi, eax
1:  push    rsi
    sub     rsp, 8
    lea     rdi, [rip+s_script]
    call    undo_push
    add     rsp, 8
    pop     rsi
    mov     rdi, r12
    call    mat_assign
    add     rsp, 8
    pop     r12
    pop     rbx
    jmp     ret_nil

# render(path [, width, height, samples, denoise]) -> milliseconds: the path tracer
#   into a PNG (the camera object, or the viewport)
b_render:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    mov     rbx, rdi
    mov     r12d, esi
    mov     r13d, 640
    mov     r14d, 360
    mov     r15d, 64
    cmp     r12d, 2
    jb      1f
    lea     rdi, [rbx+16]
    call    a_num
    cvttsd2si r13d, xmm0
1:  cmp     r12d, 3
    jb      2f
    lea     rdi, [rbx+32]
    call    a_num
    cvttsd2si r14d, xmm0
2:  cmp     r12d, 4
    jb      3f
    lea     rdi, [rbx+48]
    call    a_num
    cvttsd2si r15d, xmm0
3:  mov     dword ptr [rsp+8], 0
    cmp     r12d, 5
    jb      4f
    lea     rdi, [rbx+64]
    call    a_num
    cvttsd2si eax, xmm0
    mov     [rsp+8], eax
4:  mov     rdi, rbx
    call    a_str
    mov     [rsp], rax
    cmp     dword ptr [rip+sc_agent], 0 # agents need file access
    je      31f
    cmp     dword ptr [rip+agent_tier], 2
    jb      7f
31: mov     rdi, [rsp]
    call    path_expand
    lea     rdi, [rip+path_buf]
    mov     esi, r13d
    mov     edx, r14d
    mov     ecx, r15d
    mov     r8d, [rsp+8]
    call    hive_render_file
    test    eax, eax
    js      8f
    cvtsi2sd xmm0, eax
    add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    jmp     ret_num
7:  lea     rdi, [rip+e_op_perm]
    lea     rsi, [rip+bn_render]
    jmp     sc_rt
8:  lea     rdi, [rip+e_render]
    mov     rsi, [rsp]
    jmp     sc_rt

# image(path) -> the new image's name: loads PNG, JPEG or Radiance HDR
b_image:
    push    rbx
    push    r12
    sub     rsp, 8
    call    a_str
    mov     rbx, rax
    cmp     dword ptr [rip+sc_agent], 0 # agents need file access
    je      1f
    cmp     dword ptr [rip+agent_tier], 2
    jb      7f
1:  mov     rdi, rbx
    call    path_expand
    lea     rdi, [rip+path_buf]
    call    image_load
    test    eax, eax
    js      8f
    imul    eax, eax, 256               # its record starts with the name
    lea     rsi, [rip+img_tab]
    add     rsi, rax
    call    sh_dup
    mov     rdx, rax
    mov     eax, T_STR
    add     rsp, 8
    pop     r12
    pop     rbx
    ret
7:  lea     rdi, [rip+e_op_perm]
    lea     rsi, [rip+bn_image]
    jmp     sc_rt
8:  lea     rdi, [rip+e_image]
    mov     rsi, rbx
    jmp     sc_rt

# a_image(rdi=value) -> eax = image index (error if there is none)
a_image:
    push    rbx
    call    a_str
    mov     rbx, rax
    mov     rdi, rax
    call    image_find
    test    eax, eax
    js      1f
    pop     rbx
    ret
1:  lea     rdi, [rip+e_no_image]
    mov     rsi, rbx
    jmp     sc_rt

# imgsize(image, axis) -> width (0) or height (1)
b_imgsize:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    call    a_image
    mov     r12d, eax
    lea     rdi, [rbx+16]
    call    a_num
    cvttsd2si ebx, xmm0
    mov     edi, r12d
    call    image_ptr
    mov     ecx, [rax]
    test    ebx, ebx
    jz      2f
    mov     ecx, [rax+4]
2:  cvtsi2sd xmm0, ecx
    add     rsp, 8
    pop     r12
    pop     rbx
    jmp     ret_num

# imgpixel(image, x, y, channel) -> 0..255 (8-bit) or linear (HDR)
b_imgpixel:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rbx, rdi
    call    a_image
    mov     r12d, eax
    lea     rdi, [rbx+16]
    call    a_num
    cvttsd2si r13d, xmm0
    lea     rdi, [rbx+32]
    call    a_num
    cvttsd2si r14d, xmm0
    lea     rdi, [rbx+48]
    call    a_num
    cvttsd2si r15d, xmm0
    mov     edi, r12d
    mov     esi, r13d
    mov     edx, r14d
    mov     ecx, r15d
    call    image_pixel
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    jmp     ret_num

# imgset(image, x, y, r, g, b [, a]) - an 8-bit image's pixel (0..255;
#   the image is then saved inside .bee files)
b_imgset:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    mov     rbx, rdi
    mov     r15d, esi
    call    a_image
    mov     edi, eax
    call    image_ptr
    mov     r12, rax
    lea     rdi, [rbx+16]
    call    a_num
    cvttsd2si r13d, xmm0
    lea     rdi, [rbx+32]
    call    a_num
    cvttsd2si r14d, xmm0
    mov     dword ptr [rsp], 255        # alpha
    xor     ecx, ecx                    # r g b (a) -> a r g b
1:  lea     eax, [rcx+3]
    cmp     eax, r15d
    jae     2f
    push    rcx
    push    rcx
    lea     eax, [rcx+3]
    shl     eax, 4
    lea     rdi, [rbx+rax]
    call    a_num
    pop     rcx
    pop     rcx
    cvttsd2si eax, xmm0
    test    eax, eax
    jns     11f
    xor     eax, eax
11: cmp     eax, 255
    jbe     12f
    mov     eax, 255
12: cmp     ecx, 3
    jne     13f
    mov     [rsp], eax
    jmp     14f
13: mov     [rsp+4+rcx*4], eax
14: inc     ecx
    jmp     1b
2:  test    r12, r12
    jz      9f
    cmp     dword ptr [r12+8], 0        # (8-bit only)
    jne     9f
    cmp     r13d, [r12]
    jae     9f
    cmp     r14d, [r12+4]
    jae     9f
    mov     eax, [rsp]
    shl     eax, 8
    or      eax, [rsp+4]
    shl     eax, 8
    or      eax, [rsp+8]
    shl     eax, 8
    or      eax, [rsp+12]
    mov     ecx, r14d
    imul    ecx, [r12]
    add     ecx, r13d
    mov     [r12+64+rcx*4], eax
    mov     dword ptr [r12+24], 1       # (painted: inside the .bee)
    mov     dword ptr [rip+dirty], 1
9:  add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    jmp     ret_nil

# paint(object, x, y, z, radius [, r, g, b]) - a dab of texture paint
#   around that world point (the brush colour, or this one; 0..255) -> 1,
#   0 when the object has no image to paint
b_paint:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 32
    mov     rbx, rdi
    mov     r12d, esi
    xor     ecx, ecx                    # x y z radius
1:  push    rcx
    push    rcx
    lea     eax, [rcx+1]
    shl     eax, 4
    lea     rdi, [rbx+rax]
    call    a_num
    pop     rcx
    pop     rcx
    cvtsd2ss xmm0, xmm0
    movss   [rsp+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 4
    jb      1b
    cmp     r12d, 8                     # a colour
    jb      3f
    mov     r13d, 0xff
    mov     ecx, 5
2:  push    rcx
    push    rcx
    mov     eax, ecx
    shl     eax, 4
    lea     rdi, [rbx+rax]
    call    a_num
    pop     rcx
    pop     rcx
    cvttsd2si eax, xmm0
    test    eax, eax
    jns     21f
    xor     eax, eax
21: cmp     eax, 255
    jbe     22f
    mov     eax, 255
22: shl     r13d, 8
    or      r13d, eax
    inc     ecx
    cmp     ecx, 8
    jb      2b
    mov     [rip+pt_col], r13d
3:  mov     rdi, rbx
    call    a_meshobj
    mov     rdi, rbx
    call    a_obj
    mov     edi, eax
    lea     rsi, [rsp]
    movss   xmm0, [rsp+12]
    call    paint_dab_world
    cvtsi2sd xmm0, eax
    add     rsp, 32
    pop     r13
    pop     r12
    pop     rbx
    jmp     ret_num

# uvmap(object, su, sv, du, dv) - every UV becomes (u su + du, v sv + dv)
b_uvmap:
    push    rbx
    push    r12
    sub     rsp, 24
    mov     rbx, rdi
    xor     ecx, ecx
1:  push    rcx
    push    rcx
    lea     eax, [rcx+1]
    shl     eax, 4
    lea     rdi, [rbx+rax]
    call    a_num
    pop     rcx
    pop     rcx
    cvtsd2ss xmm0, xmm0
    movss   [rsp+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 4
    jb      1b
    mov     rdi, rbx
    call    a_meshobj
    mov     rdi, rax
    call    uv_cow
    test    rax, rax
    jz      9f
    mov     rdx, [rax+ME_UV]
    test    rdx, rdx
    jz      9f
    inc     dword ptr [rax+ME_VER]
    mov     ecx, [rax+ME_NLOOPS]
2:  test    ecx, ecx
    jz      9f
    dec     ecx
    movss   xmm0, [rdx+rcx*8]
    mulss   xmm0, [rsp]
    addss   xmm0, [rsp+8]
    movss   [rdx+rcx*8], xmm0
    movss   xmm0, [rdx+rcx*8+4]
    mulss   xmm0, [rsp+4]
    addss   xmm0, [rsp+12]
    movss   [rdx+rcx*8+4], xmm0
    jmp     2b
9:  mov     dword ptr [rip+dirty], 1
    add     rsp, 24
    pop     r12
    pop     rbx
    jmp     ret_nil

# node(material, type [, values...]) -> the node's number (1..12); an image
#   node takes an image name first, then its size
b_node:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    mov     rbx, rdi
    mov     r15d, esi
    call    a_mat
    mov     r12d, eax
    lea     rdi, [rbx+16]
    call    a_str
    mov     r14, rax
    mov     rdi, rax
    call    graph_type_index
    test    eax, eax
    js      7f
    mov     r13d, eax
    lea     rdi, [rip+s_script]
    call    undo_push
    mov     edi, r12d
    mov     esi, r13d
    call    graph_add
    test    eax, eax
    js      8f
    mov     r14d, eax                   # the node
    mov     dword ptr [rsp+8], 4        # slot of the next value
    mov     ecx, 2                      # argument
    cmp     r13d, 1                     # image: the name
    jne     2f
    cmp     r15d, 3
    jb      2f
    lea     rdi, [rbx+32]
    call    a_image
    inc     eax
    cvtsi2ss xmm0, eax
    movss   [rsp], xmm0
    mov     edi, r12d
    mov     esi, r14d
    mov     edx, 4
    lea     rcx, [rsp]
    mov     r8d, 1
    call    graph_set
    mov     dword ptr [rsp+8], 5
    mov     ecx, 3
2:  cmp     ecx, r15d
    jae     5f
    mov     [rsp+12], ecx
    shl     ecx, 4
    lea     rdi, [rbx+rcx]
    call    a_num
    cvtsd2ss xmm0, xmm0
    movss   [rsp], xmm0
    mov     edi, r12d
    mov     esi, r14d
    mov     edx, [rsp+8]
    lea     rcx, [rsp]
    mov     r8d, 1
    call    graph_set
    inc     dword ptr [rsp+8]
    mov     ecx, [rsp+12]
    inc     ecx
    jmp     2b
5:  cvtsi2sd xmm0, r14d
    add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    jmp     ret_num
7:  lea     rdi, [rip+e_node_type]
    mov     rsi, r14
    jmp     sc_rt
8:  lea     rdi, [rip+e_node_full]
    xor     esi, esi
    jmp     sc_rt

# a_int(rdi=value) -> eax
a_int:
    sub     rsp, 8
    call    a_num
    cvttsd2si eax, xmm0
    add     rsp, 8
    ret

# link(material, from, to, input 1..3)
b_link:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rbx, rdi
    call    a_mat
    mov     r12d, eax
    lea     rdi, [rbx+16]
    call    a_int
    mov     r13d, eax
    lea     rdi, [rbx+32]
    call    a_int
    mov     r14d, eax
    lea     rdi, [rbx+48]
    call    a_int
    mov     r15d, eax
    lea     rdi, [rip+s_script]
    call    undo_push
    mov     edi, r12d
    mov     esi, r13d
    mov     edx, r14d
    mov     ecx, r15d
    call    graph_link
    test    eax, eax
    jz      8f
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    jmp     ret_nil
8:  lea     rdi, [rip+e_node_bad]
    xor     esi, esi
    jmp     sc_rt

# nodeset(material, node, slot 1..7, x [, y, z])
b_nodeset:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    mov     rbx, rdi
    mov     r15d, esi
    call    a_mat
    mov     r12d, eax
    lea     rdi, [rbx+16]
    call    a_int
    mov     r13d, eax
    lea     rdi, [rbx+32]
    call    a_int
    mov     r14d, eax
    xor     ecx, ecx                    # values
1:  lea     eax, [rcx+3]
    cmp     eax, r15d
    jae     2f
    push    rcx
    shl     eax, 4
    lea     rdi, [rbx+rax]
    call    a_num
    pop     rcx
    cvtsd2ss xmm0, xmm0
    movss   [rsp+rcx*4], xmm0
    inc     ecx
    jmp     1b
2:  mov     [rsp+12], ecx
    lea     rdi, [rip+s_script]
    call    undo_push
    mov     edi, r12d
    mov     esi, r13d
    mov     edx, r14d
    lea     rcx, [rsp]
    mov     r8d, [rsp+12]
    call    graph_set
    test    eax, eax
    jz      8f
    add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    jmp     ret_nil
8:  lea     rdi, [rip+e_node_bad]
    xor     esi, esi
    jmp     sc_rt

# socket(material, base|metallic|roughness|emission|normal, node or nil)
b_socket:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     rbx, rdi
    call    a_mat
    mov     r12d, eax
    lea     rdi, [rbx+16]
    call    a_str
    mov     rdi, rax
    call    graph_socket_index
    test    eax, eax
    js      8f
    mov     r13d, eax
    xor     r14d, r14d                  # nil: unplug
    cmp     dword ptr [rbx+32], T_NIL
    je      1f
    lea     rdi, [rbx+32]
    call    a_int
    mov     r14d, eax
1:  lea     rdi, [rip+s_script]
    call    undo_push
    mov     edi, r12d
    mov     esi, r13d
    mov     edx, r14d
    call    graph_socket
    test    eax, eax
    jz      8f
    add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    jmp     ret_nil
8:  lea     rdi, [rip+e_node_bad]
    xor     esi, esi
    jmp     sc_rt

# param(name [, expression]) -> its value in scene units (set it first)
b_param:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r13d, esi
    call    a_str
    mov     r12, rax
    cmp     r13d, 2
    jb      1f
    lea     rdi, [rbx+16]               # the expression: text or a number
    cmp     dword ptr [rdi], T_NUM
    jne     2f
    movsd   xmm0, [rdi+8]               # (a number: as text)
    sub     rsp, 8
    call    fmt_reset
    cvtsd2ss xmm0, xmm0
    call    fmt_val3
    add     rsp, 8
    lea     rax, [rip+fmt_buf]
    jmp     3f
2:  call    a_str
3:  push    rax
    lea     rdi, [rip+s_script]
    call    undo_push
    pop     rsi
    mov     rdi, r12
    call    param_set
    test    eax, eax
    jz      8f
    call    cad_rebuild                 # sketches follow
1:  mov     rdi, r12
    call    param_find
    test    eax, eax
    js      7f
    mov     edi, eax
    call    param_value
    test    eax, eax
    jz      8f
    pop     r13
    pop     r12
    pop     rbx
    jmp     ret_num
7:  lea     rdi, [rip+e_noparam]
    mov     rsi, r12
    jmp     sc_rt
8:  lea     rdi, [rip+e_param]
    mov     rsi, [rip+expr_err]
    jmp     sc_rt

# expr(text) -> its value (units: scene units / radians)
b_expr:
    sub     rsp, 8
    call    a_str
    mov     rdi, rax
    call    expr_eval
    test    eax, eax
    jz      8f
    add     rsp, 8
    jmp     ret_num
8:  lea     rdi, [rip+e_param]
    mov     rsi, [rip+expr_err]
    jmp     sc_rt

# a_val(rdi=value) -> xmm0 (double): a number, or an expression text
a_val:
    cmp     dword ptr [rdi], T_STR
    jne     a_num
    push    rbx
    mov     rbx, [rdi+8]
    mov     rdi, rbx
    call    expr_eval
    test    eax, eax
    jz      1f
    pop     rbx
    ret
1:  lea     rdi, [rip+e_param]
    mov     rsi, [rip+expr_err]
    jmp     sc_rt

# a_sketch(rdi=value) -> rax = the sketch object (error if none)
a_sketch:
    push    rbx
    call    a_str
    mov     rbx, rax
    mov     rdi, rax
    call    skx_get
    test    rax, rax
    jz      1f
    pop     rbx
    ret
1:  lea     rdi, [rip+e_no_sketch]
    mov     rsi, rbx
    jmp     sc_rt

# sk_edit(rdi=value) -> rbx = object, r12 = its sketch (ours): an undo step
#   for the script, then copy-on-write (callers keep rbx / r12 callee-saved)
sk_edit:
    sub     rsp, 8
    call    a_sketch
    mov     rbx, rax
    lea     rdi, [rip+s_script]
    call    undo_push
    mov     rdi, rbx
    call    skx_begin
    mov     r12, rax
    add     rsp, 8
    ret

# sk_done(eax=index) - solve, show, return the index (or the full error)
sk_done:
    test    eax, eax
    js      8f
    push    rax
    mov     rdi, rbx
    call    skx_end
    pop     rax
    cvtsi2sd xmm0, eax
    ret
8:  lea     rdi, [rip+e_sk_full]
    xor     esi, esi
    jmp     sc_rt

# sketch(name, "XY" | "XZ" | "YZ" [, offset]) -> the new sketch's name
b_sketch:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 24
    mov     rbx, rdi
    mov     r14d, esi
    call    a_str
    mov     r12, rax
    lea     rdi, [rbx+16]
    call    a_str
    mov     r13, rax
    xor     ecx, ecx                    # the plane
    lea     rsi, [rip+s_plane_xy]
    mov     rdi, r13
    call    str_eq
    xor     ecx, ecx
    test    eax, eax
    jnz     1f
    mov     rdi, r13
    lea     rsi, [rip+s_plane_xz]
    call    str_eq
    mov     ecx, 1
    test    eax, eax
    jnz     1f
    mov     rdi, r13
    lea     rsi, [rip+s_plane_yz]
    call    str_eq
    mov     ecx, 2
    test    eax, eax
    jz      8f
1:  mov     [rsp], ecx
    xorpd   xmm0, xmm0
    movsd   [rsp+8], xmm0
    cmp     r14d, 3
    jb      2f
    lea     rdi, [rbx+32]
    call    a_val
    movsd   [rsp+8], xmm0
2:  lea     rdi, [rip+s_script]
    call    undo_push
    mov     rdi, r12
    mov     esi, [rsp]
    movsd   xmm0, [rsp+8]
    call    skx_create
    test    eax, eax
    jz      9f
    mov     edi, eax
    add     rsp, 24
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    jmp     ret_name
8:  lea     rdi, [rip+e_sk_plane]
    mov     rsi, r13
    jmp     sc_rt
9:  lea     rdi, [rip+e_sk_full]
    xor     esi, esi
    jmp     sc_rt

# point(sketch, x, y) -> its index
b_point:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 16
    mov     r13, rdi
    lea     rdi, [r13+16]
    call    a_val
    movsd   [rsp], xmm0
    lea     rdi, [r13+32]
    call    a_val
    movsd   [rsp+8], xmm0
    mov     rdi, r13
    call    sk_edit
    mov     rdi, r12
    movsd   xmm0, [rsp]
    movsd   xmm1, [rsp+8]
    call    sk_add_point
    call    sk_done
    add     rsp, 16
    pop     r13
    pop     r12
    pop     rbx
    jmp     ret_num

# line(sketch, x1, y1, x2, y2) or line(sketch, point a, point b) -> entity
b_line:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 40
    mov     r13, rdi
    mov     r14d, esi
    xor     ecx, ecx                    # the numbers
1:  lea     eax, [rcx+1]
    cmp     eax, r14d
    jae     2f
    push    rcx
    push    rcx
    shl     eax, 4
    lea     rdi, [r13+rax]
    call    a_val
    pop     rcx
    pop     rcx
    movsd   [rsp+rcx*8], xmm0
    inc     ecx
    jmp     1b
2:  mov     rdi, r13
    call    sk_edit
    cmp     r14d, 3
    jne     3f
    cvttsd2si esi, qword ptr [rsp]      # two points
    cvttsd2si edx, qword ptr [rsp+8]
    cmp     esi, [r12+12]
    jae     8f
    cmp     edx, [r12+12]
    jae     8f
    mov     rdi, r12
    call    sk_add_line
    jmp     4f
3:  cmp     r14d, 5
    jne     8f
    mov     rdi, r12
    movsd   xmm0, [rsp]
    movsd   xmm1, [rsp+8]
    movsd   xmm2, [rsp+16]
    movsd   xmm3, [rsp+24]
    call    skx_line_xy
4:  call    sk_done
    add     rsp, 40
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    jmp     ret_num
8:  lea     rdi, [rip+e_sk_ref]
    xor     esi, esi
    jmp     sc_rt

# circle(sketch, cx, cy, r) -> entity
b_circle:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 32
    mov     r13, rdi
    lea     rdi, [r13+16]
    call    a_val
    movsd   [rsp], xmm0
    lea     rdi, [r13+32]
    call    a_val
    movsd   [rsp+8], xmm0
    lea     rdi, [r13+48]
    call    a_val
    movsd   [rsp+16], xmm0
    mov     rdi, r13
    call    sk_edit
    mov     rdi, r12
    movsd   xmm0, [rsp]
    movsd   xmm1, [rsp+8]
    movsd   xmm2, [rsp+16]
    call    skx_circle_xy
    call    sk_done
    add     rsp, 32
    pop     r13
    pop     r12
    pop     rbx
    jmp     ret_num

# arc(sketch, cx, cy, r, from angle, to angle) -> entity (angles: radians,
#   or expressions like "90deg"; counter-clockwise)
b_arc:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 48
    mov     r13, rdi
    xor     ecx, ecx
1:  cmp     ecx, 5
    jae     2f
    push    rcx
    push    rcx
    lea     eax, [rcx+1]
    shl     eax, 4
    lea     rdi, [r13+rax]
    call    a_val
    pop     rcx
    pop     rcx
    movsd   [rsp+rcx*8], xmm0
    inc     ecx
    jmp     1b
2:  mov     rdi, r13
    call    sk_edit
    mov     rdi, r12
    movsd   xmm0, [rsp]
    movsd   xmm1, [rsp+8]
    movsd   xmm2, [rsp+16]
    movsd   xmm3, [rsp+24]
    movsd   xmm4, [rsp+32]
    call    skx_arc_xy
    call    sk_done
    add     rsp, 48
    pop     r13
    pop     r12
    pop     rbx
    jmp     ret_num

# rect(sketch, x, y, width, height) -> the first of its four lines
b_rect:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 32
    mov     r13, rdi
    xor     ecx, ecx
1:  cmp     ecx, 4
    jae     2f
    push    rcx
    push    rcx
    lea     eax, [rcx+1]
    shl     eax, 4
    lea     rdi, [r13+rax]
    call    a_val
    pop     rcx
    pop     rcx
    movsd   [rsp+rcx*8], xmm0
    inc     ecx
    jmp     1b
2:  mov     rdi, r13
    call    sk_edit
    mov     rdi, r12
    movsd   xmm0, [rsp]
    movsd   xmm1, [rsp+8]
    movsd   xmm2, [rsp+16]
    movsd   xmm3, [rsp+24]
    call    skx_rect
    call    sk_done
    add     rsp, 32
    pop     r13
    pop     r12
    pop     rbx
    jmp     ret_num

# pt(sketch, entity, which) -> its point: line 0 start 1 end; circle 0
#   centre; arc 0 centre 1 start 2 end
b_pt:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    call    a_sketch
    mov     r12, [rax+OB_SKETCH]
    lea     rdi, [rbx+16]
    call    a_num
    cvttsd2si r13d, xmm0
    lea     rdi, [rbx+32]
    call    a_num
    cvttsd2si edx, xmm0
    mov     rdi, r12
    mov     esi, r13d
    call    sk_ent_point
    test    eax, eax
    js      8f
    cvtsi2sd xmm0, eax
    pop     r13
    pop     r12
    pop     rbx
    jmp     ret_num
8:  lea     rdi, [rip+e_sk_ref]
    xor     esi, esi
    jmp     sc_rt

# con(sketch, type, a [, b [, c]] [, value]) -> constraint index. Point
#   constraints take point indices, the others entities; distance, hdistance,
#   vdistance, radius, diameter, length and angle end with a value (a number
#   or an expression text, kept so parameters drive it)
b_con:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 48
    mov     r13, rdi
    mov     r14d, esi
    lea     rdi, [r13+16]
    call    a_str
    mov     r15, rax
    mov     rdi, rax
    call    sk_con_type
    test    eax, eax
    js      .Lbc_type
    mov     [rsp+40], eax
    mov     dword ptr [rsp], -1         # a b c
    mov     dword ptr [rsp+4], -1
    mov     dword ptr [rsp+8], -1
    xorpd   xmm0, xmm0
    movsd   [rsp+16], xmm0              # value
    mov     qword ptr [rsp+24], 0       # expression text
    mov     eax, [rsp+40]               # does it take a value?
    xor     ecx, ecx
    cmp     eax, 9                      # distance hdistance vdistance radius
    jb      1f
    cmp     eax, 13                     #  angle (9..13)
    jbe     2f
1:  cmp     eax, 18                     # length, diameter
    jb      3f
2:  mov     ecx, 1
3:  mov     [rsp+44], ecx
    mov     eax, r14d                   # references: args 2 .. (n - value)
    sub     eax, 2
    sub     eax, ecx
    cmp     eax, 1
    jl      .Lbc_ref
    cmp     eax, 3
    jg      .Lbc_ref
    mov     [rsp+36], eax
    xor     ebx, ebx
4:  cmp     ebx, [rsp+36]
    jae     5f
    lea     eax, [rbx+2]
    shl     eax, 4
    lea     rdi, [r13+rax]
    call    a_num
    cvttsd2si eax, xmm0
    mov     [rsp+rbx*4], eax
    inc     ebx
    jmp     4b
5:  cmp     dword ptr [rsp+44], 0       # the value
    je      6f
    lea     eax, [r14-1]
    shl     eax, 4
    lea     rdi, [r13+rax]
    cmp     dword ptr [rdi], T_STR
    jne     51f
    mov     rax, [rdi+8]
    mov     [rsp+24], rax
51: call    a_val
    movsd   [rsp+16], xmm0
6:  mov     rdi, r13
    call    sk_edit
    mov     rdi, r12
    mov     esi, [rsp+40]
    mov     edx, [rsp]
    mov     ecx, [rsp+4]
    mov     r8d, [rsp+8]
    movsd   xmm0, [rsp+16]
    mov     r9, [rsp+24]
    call    sk_add_con
    call    sk_done
    add     rsp, 48
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    jmp     ret_num
.Lbc_type:
    lea     rdi, [rip+e_sk_ctype]
    mov     rsi, r15
    jmp     sc_rt
.Lbc_ref:
    lea     rdi, [rip+e_sk_ref]
    xor     esi, esi
    jmp     sc_rt

# dof(sketch) -> degrees of freedom left; conflicts(sketch) -> how many
b_dof:
    sub     rsp, 8
    call    a_sketch
    mov     rax, [rax+OB_SKETCH]
    cvtsi2sd xmm0, dword ptr [rax+24]
    add     rsp, 8
    jmp     ret_num
b_conflicts:
    sub     rsp, 8
    call    a_sketch
    mov     rax, [rax+OB_SKETCH]
    cvtsi2sd xmm0, dword ptr [rax+28]
    add     rsp, 8
    jmp     ret_num

# sx / sy(sketch, point) -> its coordinate; sr(sketch, entity) -> radius
b_sx:
    xor     eax, eax
    jmp     sk_coord
b_sy:
    mov     eax, 1
    jmp     sk_coord
b_sr:
    mov     eax, 2
sk_coord:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r13d, eax
    call    a_sketch
    mov     r12, [rax+OB_SKETCH]
    lea     rdi, [rbx+16]
    call    a_num
    cvttsd2si eax, xmm0
    test    eax, eax
    js      8f
    cmp     r13d, 2
    je      2f
    cmp     eax, [r12+12]
    jae     8f
    mov     rdi, r12
    mov     esi, eax
    call    sk_point_xy
    cmp     r13d, 1
    jne     1f
    movsd   xmm0, xmm1
1:  pop     r13
    pop     r12
    pop     rbx
    jmp     ret_num
2:  cmp     eax, [r12+16]
    jae     8f
    imul    eax, eax, 32
    movsd   xmm0, [r12+64+256*24+rax+16]
    jmp     1b
8:  lea     rdi, [rip+e_sk_ref]
    xor     esi, esi
    jmp     sc_rt

# skinfo(sketch, "points" | "entities" | "constraints") -> how many
b_skinfo:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    call    a_sketch
    mov     r12, [rax+OB_SKETCH]
    lea     rdi, [rbx+16]
    call    a_str
    mov     rbx, rax
    mov     rdi, rax
    lea     rsi, [rip+s_ki_points]
    call    str_eq
    mov     ecx, 12
    test    eax, eax
    jnz     1f
    mov     rdi, rbx
    lea     rsi, [rip+s_ki_ents]
    call    str_eq
    mov     ecx, 16
    test    eax, eax
    jnz     1f
    mov     ecx, 20
1:  cvtsi2sd xmm0, dword ptr [r12+rcx]
    add     rsp, 8
    pop     r12
    pop     rbx
    jmp     ret_num

# ---- features ---------------------------------------------------------------
# fb_new(edi=type) - a fresh record in ft_tmp
fb_new:
    push    rdi
    lea     rdi, [rip+ft_tmp]
    xor     eax, eax
    mov     ecx, 128
    rep     stosb
    pop     rax
    mov     [rip+ft_tmp], eax
    ret

# fb_slot(rdi=value, esi=slot) - a number, or an expression text that works
fb_slot:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    shl     esi, 5
    lea     r12, [rip+ft_tmp+32]
    add     r12, rsi
    cmp     dword ptr [rbx], T_STR
    je      1f
    call    a_num
    mov     byte ptr [r12], 1
    movsd   [r12+8], xmm0
    jmp     9f
1:  mov     rdi, rbx
    call    a_val                       # (errors if it does not evaluate)
    mov     rsi, [rbx+8]
    xor     ecx, ecx
2:  mov     al, [rsi+rcx]
    mov     [r12+rcx], al
    test    al, al
    jz      9f
    inc     ecx
    cmp     ecx, 32
    jb      2b
    lea     rdi, [rip+e_ft_long]
    jmp     sc_rt
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# fb_word(rdi=value, rsi=table) -> eax = the word's number (error if unknown)
fb_word:
    push    rbx
    push    r12
    push    r13
    mov     r12, rsi
    call    a_str
    mov     r13, rax
1:  mov     rsi, [r12]
    test    rsi, rsi
    jz      8f
    mov     rdi, r13
    call    str_eq
    test    eax, eax
    jnz     2f
    add     r12, 16
    jmp     1b
2:  mov     eax, [r12+8]
    pop     r13
    pop     r12
    pop     rbx
    ret
8:  lea     rdi, [rip+e_ft_word]
    mov     rsi, r13
    jmp     sc_rt

# fb_finish(rdi=body value) -> xmm0 = the new feature's index: an undo step,
#   the body (a new mesh object when there is none), the feature
fb_finish:
    push    rbx
    push    r12
    sub     rsp, 8
    call    a_str
    mov     rbx, rax
    lea     rdi, [rip+s_script]
    call    undo_push
    mov     rdi, rbx
    call    obj_find
    test    eax, eax
    jz      1f
    mov     edi, eax
    call    obj_get
    cmp     dword ptr [rax+OB_TYPE], OT_MESH
    jne     7f
    jmp     2f
1:  mov     edi, 8                      # an empty mesh until it is built
    mov     esi, 8
    mov     edx, 8
    call    mesh_new
    test    rax, rax
    jz      6f
    mov     r12, rax
    mov     rdi, rax
    call    mesh_finish
    mov     edi, OT_MESH
    mov     rsi, rbx
    mov     rdx, r12
    call    obj_new
    test    eax, eax
    jz      6f
    mov     edi, eax
    call    obj_get
2:  mov     eax, [rax+OB_UID]
    mov     [rip+ft_tmp+4], eax
    lea     rdi, [rip+ft_tmp]
    call    feat_add
    test    eax, eax
    js      6f
    cvtsi2sd xmm0, eax
    add     rsp, 8
    pop     r12
    pop     rbx
    ret
6:  lea     rdi, [rip+e_ft_full]
    xor     esi, esi
    jmp     sc_rt
7:  lea     rdi, [rip+e_ft_body]
    mov     rsi, rbx
    jmp     sc_rt

# pad / pocket(body, sketch, distance [, "symmetric" | "reverse" | "through"])
#   -> the feature's index
b_pad:
    mov     edx, 1
    jmp     fb_extrude
b_pocket:
    mov     edx, 2
    jmp     fb_extrude
# revolve(body, sketch, angle [, "u" | "v": the sketch axis])
b_revolve:
    mov     edx, 3
    jmp     fb_extrude
# hole(body, sketch, diameter [, depth]): at every loose point (no depth:
#   through)
b_hole:
    mov     edx, 4
fb_extrude:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12d, esi
    mov     r13d, edx
    mov     edi, edx
    call    fb_new
    lea     rdi, [rbx+16]
    call    a_sketch
    mov     eax, [rax+OB_UID]
    mov     [rip+ft_tmp+8], eax
    lea     rdi, [rbx+32]
    xor     esi, esi
    call    fb_slot
    cmp     r12d, 4
    jb      3f
    lea     rdi, [rbx+48]
    cmp     r13d, 3
    je      1f
    cmp     r13d, 4
    je      2f
    lea     rsi, [rip+fw_modes]
    call    fb_word
    mov     [rip+ft_tmp+16], eax
    jmp     3f
1:  lea     rsi, [rip+fw_axes]
    call    fb_word
    and     eax, 1
    mov     [rip+ft_tmp+28], eax
    jmp     3f
2:  mov     esi, 1                      # the hole's depth
    call    fb_slot
3:  mov     rdi, rbx
    call    fb_finish
    pop     r13
    pop     r12
    pop     rbx
    jmp     ret_num

# shell(body, pad feature, wall [, "bottom": open below instead of above])
b_shell:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12d, esi
    mov     edi, 5
    call    fb_new
    lea     rdi, [rbx+16]
    call    a_int
    mov     [rip+ft_tmp+12], eax
    lea     rdi, [rbx+32]
    xor     esi, esi
    call    fb_slot
    cmp     r12d, 4
    jb      1f
    lea     rdi, [rbx+48]
    lea     rsi, [rip+fw_modes]
    call    fb_word
    and     eax, 2
    mov     [rip+ft_tmp+16], eax
1:  mov     rdi, rbx
    call    fb_finish
    pop     r13
    pop     r12
    pop     rbx
    jmp     ret_num

# fillet / chamfer(body, size [, "all" | "vertical" | "horizontal" | "top" |
#   "bottom"]): the body's sharp edges
b_fillet:
    mov     edx, 6
    jmp     fb_edges
b_chamfer:
    mov     edx, 7
fb_edges:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12d, esi
    mov     edi, edx
    call    fb_new
    lea     rdi, [rbx+16]
    xor     esi, esi
    call    fb_slot
    cmp     r12d, 3
    jb      1f
    lea     rdi, [rbx+32]
    lea     rsi, [rip+fw_sels]
    call    fb_word
    mov     [rip+ft_tmp+12], eax
1:  mov     rdi, rbx
    call    fb_finish
    pop     r13
    pop     r12
    pop     rbx
    jmp     ret_num

# pattern(body, feature, count, spacing | angle, "x" | "y" | "z"
#   [, "circular": turns about that axis; angle 0 = a full turn])
b_pattern:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12d, esi
    mov     edi, 8
    call    fb_new
    lea     rdi, [rbx+16]
    call    a_int
    mov     [rip+ft_tmp+12], eax
    lea     rdi, [rbx+32]
    call    a_int
    mov     [rip+ft_tmp+20], eax
    lea     rdi, [rbx+48]
    xor     esi, esi
    call    fb_slot
    lea     rdi, [rbx+64]
    lea     rsi, [rip+fw_axes]
    call    fb_word
    mov     [rip+ft_tmp+28], eax
    cmp     r12d, 6
    jb      1f
    lea     rdi, [rbx+80]
    lea     rsi, [rip+fw_circ]
    call    fb_word
    add     [rip+ft_tmp], eax           # 8 linear, 9 circular
1:  mov     rdi, rbx
    call    fb_finish
    pop     r13
    pop     r12
    pop     rbx
    jmp     ret_num

# infill(body, shell feature, "gyroid" | "grid", cell, wall) - a lattice in
#   the shell's cavity (wall: the gyroid's thickness, the struts' diameter)
b_infill:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     edi, 10
    call    fb_new
    lea     rdi, [rbx+16]
    call    a_int
    mov     [rip+ft_tmp+12], eax
    lea     rdi, [rbx+32]
    lea     rsi, [rip+fw_lat]
    call    fb_word
    mov     [rip+ft_tmp+28], eax
    lea     rdi, [rbx+48]
    xor     esi, esi
    call    fb_slot
    lea     rdi, [rbx+64]
    mov     esi, 1
    call    fb_slot
    mov     rdi, rbx
    call    fb_finish
    pop     r13
    pop     r12
    pop     rbx
    jmp     ret_num

# sculpt(object, brush, x1, y1, z1, x2, y2, z2, radius, strength) - a stroke
#   from one world point to the other (sculpt mode on the object; negative
#   strength inverts), one undo step
b_sculpt:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 56
    mov     rbx, rdi
    call    a_meshobj                   # (in sculpt mode on it)
    mov     rdi, rbx
    call    a_obj
    mov     r12d, eax
    cmp     eax, [rip+sc_obj]
    je      1f
    mov     edi, eax
    call    sculpt_enter
    test    eax, eax
    jz      9f
1:  lea     rdi, [rbx+16]               # the brush, by name
    call    a_str
    mov     r13, rax
    xor     r14d, r14d
2:  cmp     r14d, 11
    jae     8f
    lea     rax, [rip+brush_names]
    mov     rsi, [rax+r14*8]
    mov     rdi, r13
    call    str_eq
    test    eax, eax
    jnz     3f
    inc     r14d
    jmp     2b
3:  xor     ecx, ecx                    # the points, radius, strength
4:  push    rcx
    push    rcx
    lea     eax, [rcx+2]
    shl     eax, 4
    lea     rdi, [rbx+rax]
    call    a_val
    pop     rcx
    pop     rcx
    cvtsd2ss xmm0, xmm0
    movss   [rsp+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 8
    jb      4b
    mov     edi, r14d
    lea     rsi, [rsp]
    lea     rdx, [rsp+12]
    movss   xmm0, [rsp+24]
    movss   xmm1, [rsp+28]
    call    sculpt_dab_world
    add     rsp, 56
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    jmp     ret_nil
8:  lea     rdi, [rip+e_brush]
    mov     rsi, r13
    jmp     sc_rt
9:  add     rsp, 56
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    jmp     ret_nil

# unwrap(object [, "smart"]) -> islands: LSCM along the seams (or a smart
#   projection), packed into 0..1
b_unwrap:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12d, esi
    call    a_meshobj
    mov     rdi, rax
    call    uv_cow
    mov     r13, rax
    xor     esi, esi
    cmp     r12d, 2
    jb      1f
    lea     rdi, [rbx+16]
    call    a_str
    mov     rdi, rax
    lea     rsi, [rip+s_smart]
    call    str_eq
    mov     esi, eax
1:  mov     rdi, r13
    test    rdi, rdi
    jz      2f
    call    uv_unwrap
    jmp     3f
2:  mov     eax, -1
3:  cvtsi2sd xmm0, eax
    pop     r13
    pop     r12
    pop     rbx
    jmp     ret_num

# uvpack(object) -> islands (-1: no UVs)
b_uvpack:
    sub     rsp, 8
    call    a_meshobj
    mov     rdi, rax
    call    uv_cow
    mov     rdi, rax
    mov     eax, -1
    test    rdi, rdi
    jz      1f
    call    uv_pack
1:  cvtsi2sd xmm0, eax
    add     rsp, 8
    jmp     ret_num

# uv_kind(rdi=value, rsi=names (0 ended)) -> eax = the index of the name
uv_kind:
    push    rbx
    push    r12
    push    r13
    mov     r12, rsi
    call    a_str
    mov     rbx, rax
    xor     r13d, r13d
1:  mov     rsi, [r12+r13*8]
    test    rsi, rsi
    jz      8f
    mov     rdi, rbx
    call    str_eq
    test    eax, eax
    jnz     2f
    inc     r13d
    jmp     1b
2:  mov     eax, r13d
    pop     r13
    pop     r12
    pop     rbx
    ret
8:  lea     rdi, [rip+e_uv_kind]
    mov     rsi, rbx
    jmp     sc_rt

# seams(object, "mark" | "clear" | "sharp" | "none") -> seam edges: mark /
#   clear those between selected vertices, every edge over 30 degrees, or
#   none
b_seams:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    lea     rdi, [rbx+16]
    lea     rsi, [rip+seam_modes]
    call    uv_kind
    mov     r12d, eax
    mov     rdi, rbx
    call    a_meshobj
    mov     rdi, rax
    call    uv_cow
    mov     rdi, rax
    mov     eax, -1
    test    rdi, rdi
    jz      1f
    mov     esi, r12d
    call    uv_seams
1:  cvtsi2sd xmm0, eax
    add     rsp, 8
    pop     r12
    pop     rbx
    jmp     ret_num

# uvstat(object, "islands" | "angle" | "area" | "flipped" | "overlap" |
#   "inside") -> that measure of its UVs (-1: none)
b_uvstat:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    lea     rdi, [rbx+16]
    lea     rsi, [rip+uvstat_kinds]
    call    uv_kind
    mov     r12d, eax
    mov     rdi, rbx
    call    a_mesh
    mov     rdi, rax
    mov     esi, r12d
    call    uv_stat
    cvtss2sd xmm0, xmm0
    add     rsp, 8
    pop     r12
    pop     rbx
    jmp     ret_num

# frames() -> how many frames have been drawn; frametime(k) -> how long the
#   k-th last one (0: the latest, up to 255 back) took to draw, milliseconds
b_frames:
    mov     eax, [rip+fr_count]
    cvtsi2sd xmm0, rax
    jmp     ret_num
b_frametime:
    sub     rsp, 8
    call    a_int
    add     rsp, 8
    mov     ecx, [rip+fr_count]
    sub     ecx, eax
    dec     ecx
    and     ecx, 255
    lea     rdx, [rip+fr_ns]
    cvtsi2sd xmm0, qword ptr [rdx+rcx*8]
    divsd   xmm0, [rip+fr_million]
    jmp     ret_num

# thinnest(object) -> its thinnest wall (scene units; nil when no ray meets
#   another face): from each face straight in to the next
b_thinnest:
    push    rbx
    sub     rsp, 16
    call    a_meshobj
    mov     rbx, rax
    mov     rdi, rax
    call    th_faces
    test    rax, rax
    jz      8f
    mov     rcx, [rbx+OB_MESH]
    mov     edx, [rcx+ME_NPOLYS]
    movss   xmm0, [rip+sd_big]
    xor     ecx, ecx
1:  cmp     ecx, edx
    jae     2f
    minss   xmm0, [rax+rcx*4]
    inc     ecx
    jmp     1b
2:  comiss  xmm0, [rip+sd_big]
    jae     8f
    cvtss2sd xmm0, xmm0
    add     rsp, 16
    pop     rbx
    jmp     ret_num
8:  add     rsp, 16
    pop     rbx
    jmp     ret_nil

# feature(index, slot 0..2 | 3 = suppressed, value) -> its status afterwards
#   (0 = ok)
b_feature:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 16
    mov     rbx, rdi
    call    a_int
    mov     r12d, eax
    lea     rdi, [rbx+16]
    call    a_int
    mov     r13d, eax
    xor     eax, eax
    mov     [rsp], rax
    lea     rdi, [rbx+32]
    cmp     dword ptr [rdi], T_STR
    jne     1f
    mov     rax, [rdi+8]
    mov     [rsp], rax
    call    a_val                       # (it has to work)
    jmp     2f
1:  call    a_num
    movsd   [rsp+8], xmm0
2:  lea     rdi, [rip+s_script]
    call    undo_push
    mov     edi, r12d
    mov     esi, r13d
    mov     rdx, [rsp]
    movsd   xmm0, [rsp+8]
    call    feat_slot_set
    test    eax, eax
    jz      8f
    mov     edi, r12d
    call    feat_status
    cvtsi2sd xmm0, eax
    add     rsp, 16
    pop     r13
    pop     r12
    pop     rbx
    jmp     ret_num
8:  lea     rdi, [rip+e_ft_ref]
    xor     esi, esi
    jmp     sc_rt

# features() -> how many; fstatus(index) -> 0 ok, 1 sketch missing, 2 no
#   closed profile, 3 geometry failed, 4 bad value, 5 nothing to work on,
#   6 bad reference, 7 suppressed, 8 body missing
b_features:
    sub     rsp, 8
    call    feat_count
    cvtsi2sd xmm0, eax
    add     rsp, 8
    jmp     ret_num
b_fstatus:
    sub     rsp, 8
    call    a_int
    mov     edi, eax
    call    feat_status
    cvtsi2sd xmm0, eax
    add     rsp, 8
    jmp     ret_num

# area(object) / mass(object) / centroid(object, axis): mass properties in
#   world space (scene units; mass in grams from the material's density)
b_area:
    sub     rsp, 8
    call    a_meshobj
    mov     rdi, rax
    call    mass_props
    movsd   xmm0, [rip+mp_area]
    add     rsp, 8
    jmp     ret_num
b_mass:
    sub     rsp, 8
    call    a_meshobj
    mov     rdi, rax
    call    mass_props
    movsd   xmm0, [rip+mp_mass]
    add     rsp, 8
    jmp     ret_num
b_centroid:
    push    rbx
    mov     rbx, rdi
    call    a_meshobj
    mov     rdi, rax
    call    mass_props
    lea     rdi, [rbx+16]               # axis: "x" / "y" / "z" or 0..2
    cmp     dword ptr [rdi], T_STR
    jne     1f
    mov     rax, [rdi+8]
    movzx   eax, byte ptr [rax]
    sub     eax, 'x'
    jmp     2f
1:  call    a_num
    cvttsd2si eax, xmm0
2:  cmp     eax, 2
    ja      3f
    lea     rcx, [rip+mp_cen]
    movsd   xmm0, [rcx+rax*8]
    pop     rbx
    jmp     ret_num
3:  lea     rdi, [rip+e_axis]
    xor     esi, esi
    jmp     sc_rt

# measurement() -> the measure tool's result: a distance (two points), an
#   angle in radians (three), or nil
b_measurement:
    sub     rsp, 8
    call    measure_value
    add     rsp, 8
    test    eax, eax
    jz      ret_nil
    jmp     ret_num

# fangle(object, face a, face b) -> the angle between their normals (radians)
b_fangle:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 56
    mov     rbx, rdi
    call    a_mesh
    mov     r12, rax
    lea     rdi, [rbx+16]
    call    a_int
    mov     r13d, eax
    lea     rdi, [rbx+32]
    call    a_int
    mov     r14d, eax
    cmp     r13d, [r12+ME_NPOLYS]
    jae     8f
    cmp     r14d, [r12+ME_NPOLYS]
    jae     8f
    mov     rdi, r12
    mov     esi, r13d
    call    poly_normal
    cvtss2sd xmm0, [rip+nrm]
    movsd   [rsp], xmm0
    cvtss2sd xmm0, [rip+nrm+4]
    movsd   [rsp+8], xmm0
    cvtss2sd xmm0, [rip+nrm+8]
    movsd   [rsp+16], xmm0
    mov     rdi, r12
    mov     esi, r14d
    call    poly_normal
    cvtss2sd xmm0, [rip+nrm]
    movsd   [rsp+24], xmm0
    cvtss2sd xmm0, [rip+nrm+4]
    movsd   [rsp+32], xmm0
    cvtss2sd xmm0, [rip+nrm+8]
    movsd   [rsp+40], xmm0
    lea     rdi, [rsp]
    lea     rsi, [rsp+24]
    call    vangle
    add     rsp, 56
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    jmp     ret_num
8:  lea     rdi, [rip+e_no_face]
    xor     esi, esi
    jmp     sc_rt

# ---- signed-distance shapes (sdf.s): numbers are node ids ------------------
# sd_args(rdi=values, esi=first, edx=count) -> sd_p[0..count) = their values
#   (numbers or expressions with units), as floats
sd_args:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12d, esi
    xor     r13d, r13d
1:  cmp     r13d, edx
    jae     9f
    push    rdx
    push    rdx
    lea     eax, [r12+r13]
    shl     eax, 4
    lea     rdi, [rbx+rax]
    call    a_val
    pop     rdx
    pop     rdx
    cvtsd2ss xmm0, xmm0
    lea     rax, [rip+sd_p]
    movss   [rax+r13*4], xmm0
    inc     r13d
    jmp     1b
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# sd_id(rdi=value) -> eax = a valid node id (error otherwise)
sd_id:
    sub     rsp, 8
    call    a_int
    test    eax, eax
    jle     8f
    push    rax
    push    rax
    call    sdf_count
    mov     ecx, eax
    pop     rax
    pop     rdx
    cmp     eax, ecx
    jae     8f
    add     rsp, 8
    ret
8:  lea     rdi, [rip+e_sdf_id]
    xor     esi, esi
    jmp     sc_rt

# sd_make(edi=type, esi=a, edx=b; sd_p params) -> a number (the id)
sd_make:
    sub     rsp, 8
    lea     rcx, [rip+sd_p]
    xor     r8d, r8d
    xor     r9d, r9d
    call    sdf_new
    add     rsp, 8
sd_ret:
    test    eax, eax
    jz      1f
    cvtsi2sd xmm0, eax
    jmp     ret_num
1:  lea     rdi, [rip+e_sdf]
    mov     rsi, [rip+sdf_err]
    jmp     sc_rt

sd_zero:
    lea     rdi, [rip+sd_p]
    xor     eax, eax
    mov     ecx, 6
    rep     stosd
    ret

# ssphere(r), sbox(x, y, z [, rounding]) (full sizes), scyl(r, height) (along
#   Y), storus(R, r) (about Y), sgyroid(cell, wall), sgrid(cell, strut
#   diameter): centred at the origin
b_ssphere:
    push    rdi
    call    sd_zero
    pop     rdi
    xor     esi, esi
    mov     edx, 1
    call    sd_args
    mov     edi, 1
    jmp     sd_leaf
b_sbox:
    push    rdi
    push    rsi
    call    sd_zero
    pop     rdx
    pop     rdi
    xor     esi, esi
    call    sd_args
    movss   xmm1, [rip+sd_half]
    xor     ecx, ecx
1:  lea     rax, [rip+sd_p]
    movss   xmm0, [rax+rcx*4]
    mulss   xmm0, xmm1
    movss   [rax+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      1b
    mov     edi, 2
    jmp     sd_leaf
b_scyl:
    mov     ecx, 3
    jmp     sd_two
b_storus:
    mov     ecx, 4
    jmp     sd_two
b_sgyroid:
    mov     ecx, 5
    jmp     sd_two
b_sgrid:
    mov     ecx, 6
sd_two:
    push    rcx
    push    rdi
    call    sd_zero
    pop     rdi
    xor     esi, esi
    mov     edx, 2
    call    sd_args
    pop     rdi
    cmp     edi, 6                      # grid: a diameter -> radius
    jne     sd_leaf
    movss   xmm0, [rip+sd_p+4]
    mulss   xmm0, [rip+sd_half]
    movss   [rip+sd_p+4], xmm0
sd_leaf:
    xor     esi, esi
    xor     edx, edx
    jmp     sd_make

# sunion / ssub / sisect(a, b [, smoothing radius])
b_sunion:
    mov     ecx, 10
    jmp     sd_bool
b_ssub:
    mov     ecx, 11
    jmp     sd_bool
b_sisect:
    mov     ecx, 12
sd_bool:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rbx, rdi
    mov     r12d, esi
    mov     r15d, ecx
    call    sd_zero
    mov     rdi, rbx
    call    sd_id
    mov     r13d, eax
    lea     rdi, [rbx+16]
    call    sd_id
    mov     r14d, eax
    cmp     r12d, 3
    jb      1f
    mov     rdi, rbx
    mov     esi, 2
    mov     edx, 1
    call    sd_args
1:  mov     edi, r15d
    mov     esi, r13d
    mov     edx, r14d
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    jmp     sd_make

# sshell(a, thickness): a wall centred on the surface
b_sshell:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    call    sd_zero
    mov     rdi, rbx
    call    sd_id
    mov     r12d, eax
    mov     rdi, rbx
    mov     esi, 1
    mov     edx, 1
    call    sd_args
    mov     edi, 13
    mov     esi, r12d
    xor     edx, edx
    add     rsp, 8
    pop     r12
    pop     rbx
    jmp     sd_make

# smove(a, x, y, z) / srot(a, rx, ry, rz) (radians, Euler XYZ like objects)
b_smove:
    xor     ecx, ecx
    jmp     sd_xf
b_srot:
    mov     ecx, 1
sd_xf:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 128
    mov     rbx, rdi
    mov     r13d, ecx
    call    sd_zero
    mov     rdi, rbx
    call    sd_id
    mov     r12d, eax
    mov     rdi, rbx
    mov     esi, 1
    mov     edx, 3
    call    sd_args
    lea     rdi, [rip+sd_obj]           # a stand-in object: location or
    xor     eax, eax                    #  rotation, scale 1
    mov     ecx, OB_SZ
    rep     stosb
    movss   xmm0, [rip+sd_one]
    movss   [rip+sd_obj+OB_SCALE], xmm0
    movss   [rip+sd_obj+OB_SCALE+4], xmm0
    movss   [rip+sd_obj+OB_SCALE+8], xmm0
    lea     rax, [rip+sd_obj+OB_LOC]
    test    r13d, r13d
    jz      1f
    lea     rax, [rip+sd_obj+OB_ROT]
1:  mov     rcx, [rip+sd_p]
    mov     [rax], rcx
    mov     ecx, [rip+sd_p+8]
    mov     [rax+8], ecx
    lea     rdi, [rip+sd_obj]
    lea     rsi, [rsp]                  # forward
    call    obj_matrix
    xor     ecx, ecx                    # inverse: R^T, -R^T t
2:  xor     edx, edx
3:  mov     eax, edx                    # inv[c][d] = fwd[d][c]
    shl     eax, 4
    lea     r8, [rsp+rax]
    movss   xmm0, [r8+rcx*4]
    mov     eax, ecx
    shl     eax, 4
    lea     r8, [rsp+64+rax]
    movss   [r8+rdx*4], xmm0
    inc     edx
    cmp     edx, 3
    jb      3b
    inc     ecx
    cmp     ecx, 3
    jb      2b
    xor     ecx, ecx
4:  mov     eax, ecx                    # -(row c . t)
    shl     eax, 4
    lea     r8, [rsp+64+rax]
    movss   xmm0, [r8]
    mulss   xmm0, [rsp+12]
    movss   xmm1, [r8+4]
    mulss   xmm1, [rsp+28]
    addss   xmm0, xmm1
    movss   xmm1, [r8+8]
    mulss   xmm1, [rsp+44]
    addss   xmm0, xmm1
    xorps   xmm1, xmm1
    subss   xmm1, xmm0
    movss   [r8+12], xmm1
    inc     ecx
    cmp     ecx, 3
    jb      4b
    call    sd_zero
    mov     edi, 14
    mov     esi, r12d
    xor     edx, edx
    lea     rcx, [rip+sd_p]
    lea     r8, [rsp+64]
    lea     r9, [rsp]
    call    sdf_new
    add     rsp, 128
    pop     r13
    pop     r12
    pop     rbx
    jmp     sd_ret

# sdist(a, x, y, z) -> the signed distance there
b_sdist:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    call    sd_id
    mov     r12d, eax
    mov     rdi, rbx
    mov     esi, 1
    mov     edx, 3
    call    sd_args
    mov     edi, r12d
    movss   xmm0, [rip+sd_p]
    movss   xmm1, [rip+sd_p+4]
    movss   xmm2, [rip+sd_p+8]
    call    sdf_eval
    cvtss2sd xmm0, xmm0
    add     rsp, 8
    pop     r12
    pop     rbx
    jmp     ret_num

# smesh(name, a [, cells along the largest side, default 64]) -> the new mesh
#   object's name (a closed mesh, dual contouring)
b_smesh:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     rbx, rdi
    mov     r14d, esi
    call    a_str
    mov     r12, rax
    lea     rdi, [rbx+16]
    call    sd_id
    mov     r13d, eax
    mov     esi, 64
    cmp     r14d, 3
    jb      1f
    lea     rdi, [rbx+32]
    call    a_int
    mov     esi, eax
    cmp     esi, 512
    jbe     1f
    mov     esi, 512
1:  mov     edi, r13d
    call    sdf_mesh
    test    rax, rax
    jz      8f
    mov     r13, rax
    lea     rdi, [rip+s_script]
    call    undo_push
    mov     edi, OT_MESH
    mov     rsi, r12
    mov     rdx, r13
    call    obj_new
    test    eax, eax
    jz      7f
    mov     edi, eax
    add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    jmp     ret_name
7:  lea     rdi, [rip+e_ft_full]
    xor     esi, esi
    jmp     sc_rt
8:  lea     rdi, [rip+e_sdf]
    mov     rsi, [rip+sdf_err]
    jmp     sc_rt

# sclear() - forget every shape node
b_sclear:
    sub     rsp, 8
    call    sdf_clear
    add     rsp, 8
    jmp     ret_nil

# matof(object) -> its material's name, or nil
b_matof:
    sub     rsp, 8
    call    a_meshobj
    mov     rdi, rax
    call    mat_of
    add     rsp, 8
    test    eax, eax
    js      ret_nil
    mov     edi, eax
    call    mat_get
    mov     rsi, rax
    call    sh_dup
    mov     rdx, rax
    mov     eax, T_STR
    ret

# analyze(name, what) -> how many boundary edges / non-manifold edges /
#   degenerate faces / loose vertices / overhanging faces
b_analyze:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     r13, rdi
    lea     rdi, [r13+16]
    call    a_str
    mov     r12, rax
    lea     rbx, [rip+an_kind_names]
    xor     r14d, r14d
1:  cmp     byte ptr [rbx], 0
    je      8f
    mov     rdi, r12
    mov     rsi, rbx
    call    str_eq
    test    eax, eax
    jnz     2f
3:  inc     rbx                         # the next name
    cmp     byte ptr [rbx-1], 0
    jne     3b
    inc     r14d
    jmp     1b
2:  mov     rdi, r13
    call    a_meshobj
    mov     rdi, rax
    mov     esi, r14d
    call    an_count
    cvtsi2sd xmm0, eax
    add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    jmp     ret_num
8:  lea     rdi, [rip+e_an_kind]
    mov     rsi, r12
    jmp     sc_rt

# manifold(name) -> 1 if the mesh is closed and consistently oriented
b_manifold:
    sub     rsp, 8
    call    a_mesh
    mov     rdi, rax
    call    mesh_manifold
    add     rsp, 8
    cvtsi2sd xmm0, eax
    jmp     ret_num

b_vmove:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 24
    mov     rbx, rdi
    lea     rdi, [rbx+32]
    call    a_num
    cvtsd2ss xmm0, xmm0
    movss   [rsp], xmm0
    lea     rdi, [rbx+48]
    call    a_num
    cvtsd2ss xmm0, xmm0
    movss   [rsp+4], xmm0
    lea     rdi, [rbx+64]
    call    a_num
    cvtsd2ss xmm0, xmm0
    movss   [rsp+8], xmm0
    mov     rdi, rbx
    call    a_meshobj
    mov     r12, rax                    # object
    lea     rdi, [rbx+16]
    mov     rsi, [r12+OB_MESH]
    call    vidx
    mov     r13d, eax
    lea     rdi, [rip+s_script]
    call    undo_push
    mov     rdi, [r12+OB_MESH]          # unshare
    cmp     dword ptr [rdi+ME_REFS], 1
    jbe     1f
    call    mesh_copy
    test    rax, rax
    jz      1f
    mov     rdi, [r12+OB_MESH]
    mov     [r12+OB_MESH], rax
    call    mesh_unref
1:  mov     r14, [r12+OB_MESH]
    mov     rax, [r14+ME_POS]
    lea     rcx, [r13+r13*2]
    mov     rdx, [rsp]
    mov     [rax+rcx*4], rdx
    mov     edx, [rsp+8]
    mov     [rax+rcx*4+8], edx
    inc     dword ptr [r14+108]         # ME_VER
    mov     rdi, r14
    call    mesh_bbox
    mov     dword ptr [rip+dirty], 1
    add     rsp, 24
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    jmp     ret_nil

# clock() - milliseconds (monotonic), to time scripts
b_clock:
    sub     rsp, 24
    mov     edi, 1                      # CLOCK_MONOTONIC
    lea     rsi, [rsp]
    mov     eax, 228                    # clock_gettime
    syscall
    cvtsi2sd xmm0, qword ptr [rsp]
    mulsd   xmm0, [rip+f_1000]
    cvtsi2sd xmm1, qword ptr [rsp+8]
    divsd   xmm1, [rip+f_1e6]
    addsd   xmm0, xmm1
    add     rsp, 24
    jmp     ret_num

# volume(name) - signed volume in object space (negative = inside out)
b_volume:
    sub     rsp, 8
    call    a_mesh
    add     rsp, 8
    mov     r8, [rax+ME_TRIS]
    mov     r9, [rax+ME_POS]
    mov     ecx, [rax+ME_NTRIS]
    xorpd   xmm7, xmm7
1:  test    ecx, ecx
    jz      2f
    dec     ecx
    lea     rdx, [rcx+rcx*2]
    mov     eax, [r8+rdx*4]
    lea     rax, [rax+rax*2]
    lea     r10, [r9+rax*4]             # v0
    mov     eax, [r8+rdx*4+4]
    lea     rax, [rax+rax*2]
    lea     r11, [r9+rax*4]             # v1
    mov     eax, [r8+rdx*4+8]
    lea     rax, [rax+rax*2]
    lea     rdx, [r9+rax*4]             # v2
    cvtss2sd xmm0, [r11+4]              # v0 . (v1 x v2) in doubles
    cvtss2sd xmm1, [rdx+8]
    mulsd   xmm0, xmm1
    cvtss2sd xmm1, [r11+8]
    cvtss2sd xmm2, [rdx+4]
    mulsd   xmm1, xmm2
    subsd   xmm0, xmm1
    cvtss2sd xmm1, [r10]
    mulsd   xmm0, xmm1
    cvtss2sd xmm3, [r11+8]
    cvtss2sd xmm1, [rdx]
    mulsd   xmm3, xmm1
    cvtss2sd xmm1, [r11]
    cvtss2sd xmm2, [rdx+8]
    mulsd   xmm1, xmm2
    subsd   xmm3, xmm1
    cvtss2sd xmm1, [r10+4]
    mulsd   xmm3, xmm1
    addsd   xmm0, xmm3
    cvtss2sd xmm3, [r11]
    cvtss2sd xmm1, [rdx+4]
    mulsd   xmm3, xmm1
    cvtss2sd xmm1, [r11+4]
    cvtss2sd xmm2, [rdx]
    mulsd   xmm1, xmm2
    subsd   xmm3, xmm1
    cvtss2sd xmm1, [r10+8]
    mulsd   xmm3, xmm1
    addsd   xmm0, xmm3
    addsd   xmm7, xmm0
    jmp     1b
2:  movsd   xmm0, xmm7
    mulsd   xmm0, [rip+f_sixth]
    jmp     ret_num

# vsel(name, i) - 1 if that vertex is selected; vsel(name, i, flag) sets it
b_vsel:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r13d, esi
    call    a_mesh
    mov     r12, rax
    lea     rdi, [rbx+16]
    mov     rsi, r12
    call    vidx
    cmp     r13d, 3
    jb      1f
    push    rax
    lea     rdi, [rbx+32]
    call    truthy
    mov     ecx, eax
    pop     rax
    mov     rdx, [r12+ME_VSEL]
    mov     [rdx+rax], cl
    mov     dword ptr [rip+dirty], 1
1:  mov     rcx, [r12+ME_VSEL]
    movzx   eax, byte ptr [rcx+rax]
    cvtsi2sd xmm0, eax
    pop     r13
    pop     r12
    pop     rbx
    jmp     ret_num

# vselect(name, i...) - exactly these vertices selected; vselect(name) = none
b_vselect:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     rbx, rdi
    mov     r12d, esi
    call    a_mesh
    mov     r13, rax
    mov     r14d, 1                     # check the indices first
1:  cmp     r14d, r12d
    jae     2f
    mov     eax, r14d
    shl     eax, 4
    lea     rdi, [rbx+rax]
    mov     rsi, r13
    call    vidx
    inc     r14d
    jmp     1b
2:  mov     rdi, [r13+ME_VSEL]
    mov     ecx, [r13+ME_NVERTS]
    xor     eax, eax
    rep     stosb
    mov     r14d, 1
3:  cmp     r14d, r12d
    jae     4f
    mov     eax, r14d
    shl     eax, 4
    lea     rdi, [rbx+rax]
    mov     rsi, r13
    call    vidx
    mov     rcx, [r13+ME_VSEL]
    mov     byte ptr [rcx+rax], 1
    inc     r14d
    jmp     3b
4:  mov     dword ptr [rip+dirty], 1
    add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    jmp     ret_nil

# has_prefix(rdi=text, rsi=prefix) -> eax
has_prefix:
1:  mov     al, [rsi]
    test    al, al
    jz      2f
    cmp     al, [rdi]
    jne     3f
    inc     rdi
    inc     rsi
    jmp     1b
2:  mov     eax, 1
    ret
3:  xor     eax, eax
    ret

# =============================================================================
#  Macro recording: the UI reports what the user does as BeeScript lines
# =============================================================================
# m_str(rsi=asciz) / m_quoted(rsi=asciz) / m_num(xmm0) - append to the macro
m_str:
    mov     ecx, [rip+mac_len]
    lea     rdi, [rip+mac_buf]
1:  mov     al, [rsi]
    test    al, al
    jz      2f
    cmp     ecx, MAC_MAX-2
    jae     2f
    mov     [rdi+rcx], al
    inc     ecx
    inc     rsi
    jmp     1b
2:  mov     [rip+mac_len], ecx
    ret
m_quoted:
    mov     ecx, [rip+mac_len]
    lea     rdi, [rip+mac_buf]
    cmp     ecx, MAC_MAX-4
    jae     3f
    mov     byte ptr [rdi+rcx], '"'
    inc     ecx
1:  mov     al, [rsi]
    test    al, al
    jz      2f
    cmp     ecx, MAC_MAX-4
    jae     2f
    cmp     al, '"'
    je      11f
    cmp     al, '\\'
    jne     12f
11: mov     byte ptr [rdi+rcx], '\\'
    inc     ecx
12: mov     [rdi+rcx], al
    inc     ecx
    inc     rsi
    jmp     1b
2:  mov     byte ptr [rdi+rcx], '"'
    inc     ecx
3:  mov     [rip+mac_len], ecx
    ret
m_num:
    sub     rsp, 8
    call    numfmt
    mov     rsi, rax
    add     rsp, 8
    jmp     m_str

# macro_op(rdi=operator) - after run_op: scene changes become op("id", "arg")
macro_op:
    cmp     dword ptr [rip+macro_on], 0
    je      9f
    cmp     dword ptr [rip+sc_running], 0
    jne     9f
    push    rbx
    mov     rbx, rdi
    mov     rdi, [rbx+OP_NAME]
    lea     rsi, [rip+s_pfx_tm]
    call    has_prefix
    test    eax, eax
    jnz     8f
    mov     rdi, [rbx+OP_NAME]
    lea     rsi, [rip+s_pfx_script]
    call    has_prefix
    test    eax, eax
    jnz     8f
    test    dword ptr [rbx+OP_FLAGS], OPF_UNDO
    jnz     1f
    mov     rdi, [rbx+OP_NAME]
    lea     rsi, [rip+s_pfx_object]
    call    has_prefix
    test    eax, eax
    jz      8f
1:  lea     rsi, [rip+m_op]
    call    m_str
    mov     rsi, [rbx+OP_NAME]
    call    m_quoted
    mov     rsi, [rip+op_arg]
    test    rsi, rsi
    jz      2f
    cmp     byte ptr [rsi], 0
    je      2f
    lea     rsi, [rip+m_comma]
    call    m_str
    mov     rsi, [rip+op_arg]
    call    m_quoted
2:  lea     rsi, [rip+m_close]
    call    m_str
8:  pop     rbx
9:  ret

# macro_select - after a click selection: select("A", "B") (active last)
macro_select:
    cmp     dword ptr [rip+macro_on], 0
    je      9f
    cmp     dword ptr [rip+sc_running], 0
    jne     9f
    push    rbx
    push    r12
    push    r13
    lea     rsi, [rip+m_select]
    call    m_str
    xor     r13d, r13d                  # names written so far
    xor     ebx, ebx
1:  cmp     ebx, [rip+obj_count]
    jae     3f
    lea     rax, [rip+obj_list]
    mov     r12d, [rax+rbx*4]
    cmp     r12d, [rip+active_obj]
    je      2f
    mov     edi, r12d
    call    obj_get
    test    dword ptr [rax+OB_FLAGS], OBF_SELECTED
    jz      2f
    mov     r12, rax
    call    m_sep
    mov     rsi, r12
    call    m_quoted
2:  inc     ebx
    jmp     1b
3:  mov     edi, [rip+active_obj]
    test    edi, edi
    jz      4f
    call    obj_get
    test    rax, rax
    jz      4f
    test    dword ptr [rax+OB_FLAGS], OBF_SELECTED
    jz      4f
    mov     r12, rax
    call    m_sep
    mov     rsi, r12
    call    m_quoted
4:  lea     rsi, [rip+m_close]
    call    m_str
    pop     r13
    pop     r12
    pop     rbx
9:  ret
# m_sep - ", " before every name but the first (count in r13d)
m_sep:
    test    r13d, r13d
    jz      1f
    lea     rsi, [rip+m_comma]
    call    m_str
1:  inc     r13d
    ret

# macro_transform(edi=1 move, 2 rotate, 3 scale) - after G / R / S:
#   the selected objects' final values, e.g. rotate("Cube", 0deg, 45deg, 0deg)
macro_transform:
    cmp     dword ptr [rip+macro_on], 0
    je      9f
    cmp     dword ptr [rip+sc_running], 0
    jne     9f
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r14d, edi
    lea     r15, [rip+m_move]
    mov     r13d, OB_LOC
    cmp     r14d, 2
    jb      1f
    lea     r15, [rip+m_rotate]
    mov     r13d, OB_ROT
    je      1f
    lea     r15, [rip+m_scale]
    mov     r13d, OB_SCALE
1:  xor     ebx, ebx
2:  cmp     ebx, [rip+obj_count]
    jae     8f
    mov     edi, ebx
    call    obj_at
    test    dword ptr [rax+OB_FLAGS], OBF_SELECTED
    jz      7f
    mov     r12, rax
    mov     rsi, r15
    call    m_str
    mov     rsi, r12
    call    m_quoted
    push    rbx
    xor     ebx, ebx
3:  lea     rsi, [rip+m_comma]
    call    m_str
    lea     rax, [r12+r13]
    cvtss2sd xmm0, [rax+rbx*4]
    cmp     r14d, 2
    jne     4f
    mulsd   xmm0, [rip+f_r2d]
    call    m_num
    lea     rsi, [rip+m_deg]
    call    m_str
    jmp     5f
4:  call    m_num
5:  inc     ebx
    cmp     ebx, 3
    jb      3b
    pop     rbx
    lea     rsi, [rip+m_close]
    call    m_str
7:  inc     ebx
    jmp     2b
8:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
9:  ret

# ---- operators ---------------------------------------------------------------
chk_record:
    mov     eax, [rip+macro_on]
    ret

# mac_default - mac_path = ~/BeeModel/scripts/macro.bees (directory created)
mac_default:
    push    rbx
    call    default_dir
    lea     rdi, [rip+mac_path]
    mov     rsi, rax
    call    cpy
    lea     rsi, [rip+s_scripts_dir]
    call    cpy
    push    rdi
    lea     rdi, [rip+mac_path]
    call    ensure_dir
    pop     rdi
    lea     rsi, [rip+s_macro_file]
    call    cpy
    pop     rbx
    ret
# cpy(rdi=dest, rsi=asciz) -> rdi at the terminating 0
cpy:
1:  mov     al, [rsi]
    mov     [rdi], al
    test    al, al
    jz      2f
    inc     rdi
    inc     rsi
    jmp     1b
2:  ret

do_record:
    push    rbx
    cmp     dword ptr [rip+macro_on], 0
    jne     1f
    mov     dword ptr [rip+mac_len], 0
    mov     dword ptr [rip+macro_on], 1
    lea     rdi, [rip+s_rec_start]
    call    log_line
    jmp     9f
1:  mov     dword ptr [rip+macro_on], 0
    cmp     dword ptr [rip+mac_len], 0
    jne     2f
    lea     rdi, [rip+s_rec_empty]
    call    log_line
    jmp     9f
2:  call    mac_default
    lea     rdi, [rip+mac_path]
    lea     rsi, [rip+mac_buf]
    mov     edx, [rip+mac_len]
    call    file_write_atomic
    test    eax, eax
    jnz     3f
    lea     rdi, [rip+s_rec_saved]
    lea     rsi, [rip+mac_path]
    call    log_pair
    lea     rdi, [rip+s_rec_hint]
    call    log_line
    jmp     9f
3:  lea     rdi, [rip+s_rec_fail]
    call    log_line
9:  mov     dword ptr [rip+dirty], 1
    pop     rbx
    ret

# script.run [path] - a .bees file (default: the macro)
do_run:
    sub     rsp, 8
    mov     rdi, [rip+op_arg]
    test    rdi, rdi
    jz      1f
    cmp     byte ptr [rdi], 0
    je      1f
    call    path_expand
    mov     rdi, rax
    jmp     2f
1:  call    mac_default
    lea     rdi, [rip+mac_path]
2:  call    script_run_file
    add     rsp, 8
    ret

# script_run_file(rdi=path) -> eax = 0 ok, 1 script error, 2 unreadable
script_run_file:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     dword ptr [rip+script_out_len], 0
    mov     rdi, rbx
    call    file_read
    test    rax, rax
    jz      .Lrun_cant
    mov     r12, rax
    mov     r13, rdx
    cmp     r13, SRC_MAX-1
    jae     .Lrun_big
    lea     rdi, [rip+script_src_buf]
    mov     rsi, r12
    mov     rcx, r13
    rep     movsb
    mov     byte ptr [rdi], 0
    mov     rdi, r12
    mov     rsi, r13
    call    file_unmap
    lea     rdi, [rip+s_run]
    mov     rsi, rbx
    call    log_pair
    mov     qword ptr [rip+op_arg], 0
    lea     rdi, [rip+script_src_buf]
    xor     esi, esi
    call    script_eval
    jmp     9f
.Lrun_big:
    mov     rdi, r12
    mov     rsi, r13
    call    file_unmap
    lea     rdi, [rip+s_too_big]
    call    sc_print
    mov     eax, 2
    jmp     9f
.Lrun_cant:
    push    rbx
    lea     rbx, [rip+ln_buf]
    lea     rsi, [rip+s_cant_read]
    call    ln_str
    mov     rsi, [rsp]
    call    ln_str
    mov     byte ptr [rbx], 0
    pop     rbx
    lea     rdi, [rip+ln_buf]
    call    sc_print
    mov     eax, 2
9:  pop     r13
    pop     r12
    pop     rbx
    ret

do_reset:
    sub     rsp, 8
    mov     dword ptr [rip+gcount], 0
    mov     dword ptr [rip+fcount], 0
    lea     rax, [rip+fn_code]
    mov     [rip+fn_pos], rax
    lea     rdi, [rip+s_reset]
    call    log_line
    add     rsp, 8
    ret

.section .note.GNU-stack,"",@progbits
