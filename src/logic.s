# =============================================================================
#  BeeModel - logic graphs: event nodes that run in play mode.
#
#  A logic graph is a node tree (ntree.s) marked as logic (TR_KIND), so it is
#  saved, undone and edited like the geometry trees: the node editor shows
#  it for an object with a Logic modifier (mods.s: the modifier names the
#  tree; it changes no geometry). The record's spare tail holds 30 names
#  (16 bytes each) that nodes refer to by number: messages, objects,
#  properties, actions.
#
#  Nodes: events start chains (begin play, tick, key, overlap, hit, timer,
#  message); actions run when the node feeding their Run input fires (move,
#  rotate, set property, spawn, destroy, play action, impulse, shatter, visibility,
#  send message, set variable; branch picks one of two ways on); data nodes
#  (variable, math, info, get property) are pulled for the inputs that need
#  them. Links point from an input to the output that feeds it, so a chain
#  is found by looking for the nodes whose Run input takes the output that
#  fired; links never loop (ntree.s), so every chain ends.
#
#  The VM: play mode's fixed steps (1/120 s) run every object's graph, in
#  the order the objects were found, events in node order, then the
#  messages sent meanwhile (each to every graph listening, or to one
#  object). Deterministic: no clocks, no threads; "random" is a hash of the
#  step, the node and the object. Sandboxed: a graph only touches objects
#  of the scene by name, a step runs at most LG_BUDGET nodes (past it the
#  rest of that step's nodes are skipped), 256 messages a step and 256
#  spawned objects; no files, no operators. Everything it changes is undone
#  with play mode.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

.globl lg_begin
.globl lg_end
.globl lg_step
.globl lg_key
.globl lg_touch
.globl lg_stat
.globl lg_var
.globl lg_ntypes
.globl lg_titles
.globl lg_meta
.globl lg_type_names
.globl lg_is_logic
.globl lg_name_of
.globl op_logic_node

.equ GR_N,      128
.equ GR_NODES,  160
.equ NODE_SZ,   72
.equ ND_TYPE,   0
.equ ND_IN,     4
.equ ND_P,      52
.equ NT_MAXN,   48
.equ TR_KIND,   124                     # 1: a logic graph
.equ TR_STR,    GR_NODES + NT_MAXN*NODE_SZ   # names: 30 x 16 bytes
.equ STR_N,     30
.equ STR_SZ,    16
.equ MT_LOGIC,  12

# node types
.equ LT_BEGIN,  1
.equ LT_TICK,   2
.equ LT_KEY,    3
.equ LT_OVER,   4
.equ LT_HIT,    5
.equ LT_TIMER,  6
.equ LT_MSG,    7
.equ LT_MOVE,   8
.equ LT_ROT,    9
.equ LT_SETP,   10
.equ LT_SPAWN,  11
.equ LT_DESTROY,12
.equ LT_ACTION, 13
.equ LT_IMPULSE,14
.equ LT_VIS,    15
.equ LT_SEND,   16
.equ LT_SETVAR, 17
.equ LT_BRANCH, 18
.equ LT_VAR,    19
.equ LT_MATH,   20
.equ LT_INFO,   21
.equ LT_GETP,   22
.equ LT_SHATTER, 23
.equ LT_SETSTR, 24                      # a force field's strength (fields.s)
.equ LT_FIELD,  25                      # the pull at a point (data)
.equ LG_NTYPES, 25

# an instance: an object running a graph
.equ LI_OBJ,    0                       # object handle
.equ LI_TREE,   4
.equ LI_FLAGS,  8                       # 1 begun, 2 gone, 4 touched last step
.equ LI_INSIDE, 16                      # overlap nodes inside (bit per node)
.equ LI_TDONE,  24                      # one-shot timers done (bit per node)
.equ LI_START,  32                      # where it was when play began
.equ LI_VARS,   48                      # 8 variables (x y z)
.equ LI_TIMER,  176                     # per node: time to the timer
.equ LI_SZ,     384
.equ LG_MAXI,   512
.equ LG_BUDGET, 4096                    # nodes run a step
.equ LG_MAXQ,   256                     # messages a step
.equ LG_MAXSPAWN, 256
.equ MQ_SZ,     32                      # name (16), target handle, value

.section .rodata
.align 16
lf_xyz:         .long -1, -1, -1, 0
lf_abs:         .long 0x7fffffff, 0x7fffffff, 0x7fffffff, 0
lf_ones:        .float 1, 1, 1, 0
lf_halfs:       .float 0.5, 0.5, 0.5, 0.5
lf_eps4:        .float 1.0e-4, 1.0e-4, 1.0e-4, 1.0e-4
lf_big:         .float 1.0e30, 1.0e30, 1.0e30, 0
lf_nbig:        .float -1.0e30, -1.0e30, -1.0e30, 0
lf_deg:         .float 0.017453292              # degrees -> radians
lf_rad:         .float 57.29578
lf_half:        .float 0.5
lf_one:         .float 1.0
lf_tiny:        .float 1.0e-12
lf_inv24:       .float 5.9604645e-8             # 1 / 2^24
s_lg_base:      .asciz "Logic"
s_lg_made:      .asciz "  logic graph: "
s_lg_none:      .asciz "  no such node tree: "
s_lg_notlogic:  .asciz "  not a logic graph (logic.new makes one): "
s_lg_need:      .asciz "  logic.node <graph> <type> [values]; types: begin tick key overlap hit timer message move rotate set_property spawn destroy play_action impulse visibility send set_variable branch variable math info get_property shatter"
s_lg_nameneed:  .asciz "  logic.name <graph> <node> <value 4-7> [text] (15 characters at most)"
s_lg_attneed:   .asciz "  logic.attach <graph> [object] (a mesh object)"
s_lg_full:      .asciz "  logic: the graph holds 30 names"
s_lg_attached:  .asciz "  logic graph attached: "
s_lg_node:      .asciz "  node "
s_lg_over:      .asciz "  logic: a step reached 4096 nodes - the rest of it was skipped"

# ---- types: names, titles, metadata for the node editor ---------------------
.align 8
lg_ntypes:      .long LG_NTYPES
.align 8
lg_type_names:  .quad k_begin, k_tick, k_key, k_over, k_hit, k_timer, k_msg
                .quad k_move, k_rot, k_setp, k_spawn, k_destroy, k_action, k_impulse
                .quad k_vis, k_send, k_setvar, k_branch, k_var, k_math, k_info, k_getp
                .quad k_shatter, k_setstr, k_field, 0
k_begin:        .asciz "begin"
k_tick:         .asciz "tick"
k_key:          .asciz "key"
k_over:         .asciz "overlap"
k_hit:          .asciz "hit"
k_timer:        .asciz "timer"
k_msg:          .asciz "message"
k_move:         .asciz "move"
k_rot:          .asciz "rotate"
k_setp:         .asciz "set_property"
k_spawn:        .asciz "spawn"
k_destroy:      .asciz "destroy"
k_action:       .asciz "play_action"
k_impulse:      .asciz "impulse"
k_vis:          .asciz "visibility"
k_send:         .asciz "send"
k_setvar:       .asciz "set_variable"
k_branch:       .asciz "branch"
k_var:          .asciz "variable"
k_math:         .asciz "math"
k_info:         .asciz "info"
k_getp:         .asciz "get_property"
k_shatter:      .asciz "shatter"
k_setstr:       .asciz "set_strength"
k_field:        .asciz "field"
lg_titles:      .quad 0, t_begin, t_tick, t_key, t_over, t_hit, t_timer, t_msg
                .quad t_move, t_rot, t_setp, t_spawn, t_destroy, t_action, t_impulse
                .quad t_vis, t_send, t_setvar, t_branch, t_var, t_math, t_info, t_getp
                .quad t_shatter, t_setstr, t_field
t_begin:        .asciz "Begin Play"
t_tick:         .asciz "On Tick"
t_key:          .asciz "On Key"
t_over:         .asciz "On Overlap"
t_hit:          .asciz "On Hit"
t_timer:        .asciz "On Timer"
t_msg:          .asciz "On Message"
t_move:         .asciz "Move"
t_rot:          .asciz "Rotate"
t_setp:         .asciz "Set Property"
t_spawn:        .asciz "Spawn"
t_destroy:      .asciz "Destroy"
t_action:       .asciz "Play Action"
t_impulse:      .asciz "Apply Impulse"
t_vis:          .asciz "Set Visibility"
t_send:         .asciz "Send Message"
t_setvar:       .asciz "Set Variable"
t_branch:       .asciz "Branch"
t_var:          .asciz "Variable"
t_math:         .asciz "Math"
t_info:         .asciz "Info"
t_getp:         .asciz "Get Property"
t_shatter:      .asciz "Shatter"
t_setstr:       .asciz "Set Strength"
t_field:        .asciz "Field"
# per type (as nodeed.s reads it): input names, input kinds (1 value, 2
#   vector, 4 run), value names, value kinds (0 number, 1 choice, 3 whole,
#   5 name), the choices, output names, output kinds
lg_meta:        .quad 0, 0, 0, 0, 0, 0, 0
                .quad nil3, lk_z, nil4, lk_z, 0, o_then, lk_4                  # begin
                .quad nil3, lk_z, nil4, lk_z, 0, o_tick, lk_411                # tick
                .quad nil3, lk_z, v_key, lk_31, ch_key, o_then, lk_4           # key
                .quad nil3, lk_z, v_over, lk_510, ch_over, o_then, lk_4        # overlap
                .quad nil3, lk_z, nil4, lk_z, 0, o_then, lk_4                  # hit
                .quad nil3, lk_z, v_timer, lk_01, ch_repeat, o_then, lk_4      # timer
                .quad nil3, lk_z, v_name, lk_5, 0, o_msg, lk_41                # message
                .quad i_offset, lk_42, v_mode, lk_1, ch_byto, o_then, lk_4     # move
                .quad i_degrees, lk_42, v_mode, lk_1, ch_byto, o_then, lk_4    # rotate
                .quad i_value, lk_41, v_setp, lk_55, 0, o_then, lk_4           # set property
                .quad i_offset, lk_42, v_object, lk_5, 0, o_then, lk_4         # spawn
                .quad i_run, lk_4, v_object, lk_5, 0, o_then, lk_4             # destroy
                .quad i_run, lk_4, v_action, lk_50, 0, o_then, lk_4            # play action
                .quad i_impulse, lk_42, v_object, lk_5, 0, o_then, lk_4        # impulse
                .quad i_visible, lk_41, v_object, lk_5, 0, o_then, lk_4        # visibility
                .quad i_value, lk_41, v_send, lk_55, 0, o_then, lk_4           # send
                .quad i_value, lk_42, v_setvar, lk_31, ch_setadd, o_then, lk_4 # set variable
                .quad i_cond, lk_41, nil4, lk_z, 0, o_branch, lk_44            # branch
                .quad nil3, lk_z, v_var, lk_3, 0, o_value, lk_2                # variable
                .quad i_ab, lk_22, v_op, lk_1, ch_math, o_result, lk_2         # math
                .quad nil3, lk_z, v_what, lk_1, ch_info, o_value, lk_2         # info
                .quad nil3, lk_z, v_setp, lk_55, 0, o_value, lk_1              # get property
                .quad i_run, lk_4, v_object, lk_5, 0, o_then, lk_4             # shatter
                .quad i_value, lk_41, v_object, lk_5, 0, o_then, lk_4          # set strength
                .quad i_point, lk_2, nil4, lk_z, 0, o_force, lk_21             # field
lk_z:             .byte 0, 0, 0, 0
lk_4:             .byte 4, 0, 0, 0
lk_411:           .byte 4, 1, 1, 0
lk_41:            .byte 4, 1, 0, 0
lk_42:            .byte 4, 2, 0, 0
lk_44:            .byte 4, 4, 0, 0
lk_22:            .byte 2, 2, 0, 0
lk_21:            .byte 2, 1, 0, 0
lk_2:             .byte 2, 0, 0, 0
lk_1:             .byte 1, 0, 0, 0
lk_3:             .byte 3, 0, 0, 0
lk_5:             .byte 5, 0, 0, 0
lk_31:            .byte 3, 1, 0, 0
lk_01:            .byte 0, 1, 0, 0
lk_50:            .byte 5, 0, 0, 0
lk_55:            .byte 5, 5, 0, 0
lk_510:           .byte 5, 1, 0, 0
.align 8
nil3:           .quad 0, 0, 0
nil4:           .quad 0, 0, 0, 0
o_then:         .quad s_then, 0, 0
o_tick:         .quad s_then, s_delta, s_time
o_msg:          .quad s_then, s_value, 0
o_branch:       .quad s_true, s_false, 0
o_value:        .quad s_value, 0, 0
o_result:       .quad s_result, 0, 0
i_run:          .quad s_run, 0, 0
i_offset:       .quad s_run, s_offset, 0
i_degrees:      .quad s_run, s_degrees, 0
i_value:        .quad s_run, s_value, 0
i_impulse:      .quad s_run, s_impulse, 0
i_visible:      .quad s_run, s_visible, 0
i_cond:         .quad s_run, s_condition, 0
i_ab:           .quad s_a, s_b, 0
i_point:        .quad s_point, 0, 0
o_force:        .quad s_force, s_size, 0
v_key:          .quad s_keyv, s_when, 0, 0
v_over:         .quad s_with, s_when, s_margin, 0
v_timer:        .quad s_seconds, s_repeat, 0, 0
v_name:         .quad s_namev, 0, 0, 0
v_mode:         .quad s_mode, 0, 0, 0
v_setp:         .quad s_property, s_object, 0, 0
v_object:       .quad s_object, 0, 0, 0
v_action:       .quad s_actionv, s_repeat, 0, 0
v_send:         .quad s_namev, s_to, 0, 0
v_setvar:       .quad s_variable, s_mode, 0, 0
v_var:          .quad s_variable, 0, 0, 0
v_op:           .quad s_operation, 0, 0, 0
v_what:         .quad s_what, 0, 0, 0
ch_key:         .quad 3, c_pressed, c_released, c_held
ch_over:        .quad 3, c_enter, c_leave, c_inside
ch_repeat:      .quad 2, c_once, c_repeat
ch_byto:        .quad 2, c_by, c_to
ch_setadd:      .quad 2, c_set, c_add
ch_math:        .quad 18, c_add, c_sub, c_mul, c_div, c_min, c_max, c_sin, c_cos, c_gt
                .quad c_lt, c_eq, c_and, c_or, c_not, c_abs, c_len, c_dist, c_scale
ch_info:        .quad 9, c_time, c_delta, c_loc, c_rotation, c_start, c_player, c_distance
                .quad c_frame, c_random
s_then:         .asciz "Then"
s_delta:        .asciz "Delta"
s_time:         .asciz "Time"
s_value:        .asciz "Value"
s_result:       .asciz "Result"
s_true:         .asciz "True"
s_false:        .asciz "False"
s_run:          .asciz "Run"
s_offset:       .asciz "Offset"
s_degrees:      .asciz "Degrees"
s_impulse:      .asciz "Impulse"
s_visible:      .asciz "Visible"
s_condition:    .asciz "Condition"
s_a:            .asciz "A"
s_b:            .asciz "B"
s_keyv:         .asciz "Key"
s_when:         .asciz "When"
s_with:         .asciz "With"
s_margin:       .asciz "Margin"
s_seconds:      .asciz "Seconds"
s_repeat:       .asciz "Repeat"
s_namev:        .asciz "Name"
s_mode:         .asciz "Mode"
s_property:     .asciz "Property"
s_object:       .asciz "Object"
s_actionv:      .asciz "Action"
s_to:           .asciz "To"
s_variable:     .asciz "Variable"
s_operation:    .asciz "Operation"
s_what:         .asciz "What"
s_point:        .asciz "Point"
s_force:        .asciz "Force"
s_size:         .asciz "Size"
c_pressed:      .asciz "Pressed"
c_released:     .asciz "Released"
c_held:         .asciz "Held"
c_enter:        .asciz "Enter"
c_leave:        .asciz "Leave"
c_inside:       .asciz "Inside"
c_once:         .asciz "Once"
c_repeat:       .asciz "Repeat"
c_by:           .asciz "By"
c_to:           .asciz "To"
c_set:          .asciz "Set"
c_add:          .asciz "Add"
c_sub:          .asciz "Subtract"
c_mul:          .asciz "Multiply"
c_div:          .asciz "Divide"
c_min:          .asciz "Minimum"
c_max:          .asciz "Maximum"
c_sin:          .asciz "Sine"
c_cos:          .asciz "Cosine"
c_gt:           .asciz "Greater Than"
c_lt:           .asciz "Less Than"
c_eq:           .asciz "Equal"
c_and:          .asciz "And"
c_or:           .asciz "Or"
c_not:          .asciz "Not"
c_abs:          .asciz "Absolute"
c_len:          .asciz "Length"
c_dist:         .asciz "Distance"
c_scale:        .asciz "Scale"
c_time:         .asciz "Time"
c_delta:        .asciz "Delta"
c_loc:          .asciz "Location"
c_rotation:     .asciz "Rotation"
c_start:        .asciz "Start"
c_player:       .asciz "Player"
c_distance:     .asciz "Distance"
c_frame:        .asciz "Frame"
c_random:       .asciz "Random"
# defaults per type: 4 values, then the 3 inputs' x y z
.align 4
lg_defaults:    .float 0,0,0,0, 0,0,0, 0,0,0, 0,0,0      # begin
                .float 0,0,0,0, 0,0,0, 0,0,0, 0,0,0      # tick
                .float 18,0,0,0, 0,0,0, 0,0,0, 0,0,0     # key (E, pressed)
                .float 0,0,0,0, 0,0,0, 0,0,0, 0,0,0      # overlap
                .float 0,0,0,0, 0,0,0, 0,0,0, 0,0,0      # hit
                .float 1,0,0,0, 0,0,0, 0,0,0, 0,0,0      # timer
                .float 0,0,0,0, 0,0,0, 0,0,0, 0,0,0      # message
                .float 0,0,0,0, 0,0,0, 0,0,0, 0,0,0      # move
                .float 0,0,0,0, 0,0,0, 0,0,0, 0,0,0      # rotate
                .float 0,0,0,0, 0,0,0, 0,0,0, 0,0,0      # set property
                .float 0,0,0,0, 0,0,0, 0,0,0, 0,0,0      # spawn
                .float 0,0,0,0, 0,0,0, 0,0,0, 0,0,0      # destroy
                .float 0,1,0,0, 0,0,0, 0,0,0, 0,0,0      # play action
                .float 0,0,0,0, 0,0,0, 0,0,0, 0,0,0      # impulse
                .float 0,0,0,0, 0,0,0, 1,1,1, 0,0,0      # visibility
                .float 0,0,0,0, 0,0,0, 1,1,1, 0,0,0      # send (value 1)
                .float 0,0,0,0, 0,0,0, 0,0,0, 0,0,0      # set variable
                .float 0,0,0,0, 0,0,0, 0,0,0, 0,0,0      # branch
                .float 0,0,0,0, 0,0,0, 0,0,0, 0,0,0      # variable
                .float 0,0,0,0, 0,0,0, 0,0,0, 0,0,0      # math
                .float 0,0,0,0, 0,0,0, 0,0,0, 0,0,0      # info
                .float 0,0,0,0, 0,0,0, 0,0,0, 0,0,0      # get property
                .float 0,0,0,0, 0,0,0, 0,0,0, 0,0,0      # shatter
# properties: name, offset (-1: visible)
.align 8
lg_props:       .ascii "x\0\0\0\0\0\0\0"
                .long OB_LOC, 0
                .ascii "y\0\0\0\0\0\0\0"
                .long OB_LOC+4, 0
                .ascii "z\0\0\0\0\0\0\0"
                .long OB_LOC+8, 0
                .ascii "rx\0\0\0\0\0\0"
                .long OB_ROT, 0
                .ascii "ry\0\0\0\0\0\0"
                .long OB_ROT+4, 0
                .ascii "rz\0\0\0\0\0\0"
                .long OB_ROT+8, 0
                .ascii "sx\0\0\0\0\0\0"
                .long OB_SCALE, 0
                .ascii "sy\0\0\0\0\0\0"
                .long OB_SCALE+4, 0
                .ascii "sz\0\0\0\0\0\0"
                .long OB_SCALE+8, 0
                .ascii "visible\0"
                .long -1, 0
lg_props_end:

.section .bss
.align 16
lg_tab:         .skip LG_MAXI*LI_SZ
lg_mq:          .skip LG_MAXQ*MQ_SZ     # messages waiting
lg_mat:         .skip 48                # a matrix (aligned)
lg_box:         .skip 64                # boxes: this, the other
lg_ctx_v1:      .skip 4                 # the firing event's outputs 1, 2
lg_ctx_v2:      .skip 4
lg_ctx_node:    .skip 4
lg_on:          .skip 4
lg_n:           .skip 4                 # instances
lg_cur:         .skip 4                 # the instance running
lg_rec:         .skip 8                 # its graph
lg_mqn:         .skip 4
lg_budget:      .skip 4
lg_depth:       .skip 4
lg_time:        .skip 4
lg_dt:          .skip 4
lg_steps:       .skip 4
lg_runs:        .skip 4                 # stats: nodes run
lg_runs_step:   .skip 4
lg_events:      .skip 4
lg_msgs:        .skip 4
lg_spawned:     .skip 4
lg_overs:       .skip 4
lg_said:        .skip 4
lg_kdown:       .skip 32                # keys held, pressed, released
lg_kpress:      .skip 32
lg_krel:        .skip 32
lg_tnow:        .skip 512               # objects the player touched (handles)

.text
OPERATOR op_logic_new,    "logic.new",    "New Logic Graph", do_logic_new, flags=OPF_AI_SAFE|OPF_UNDO, doc="A new, empty logic graph (a node tree that runs in play mode): logic.new [name]"
OPERATOR op_logic_attach, "logic.attach", "Attach Logic", do_logic_attach, flags=OPF_AI_SAFE|OPF_UNDO, doc="Run a logic graph on an object in play mode (a Logic modifier): logic.attach <graph> [object]"
OPERATOR op_logic_node,   "logic.node",   "Add Logic Node", do_logic_node, flags=OPF_AI_SAFE|OPF_UNDO, doc="Add a node to a logic graph: logic.node <graph> <type> [values] (types: begin tick key overlap hit timer message move rotate set_property spawn destroy play_action impulse visibility send set_variable branch variable math info get_property shatter set_strength field); link and set with tree.link / tree.node_set"
OPERATOR op_logic_name,   "logic.name",   "Set Logic Name", do_logic_name, flags=OPF_AI_SAFE|OPF_UNDO, doc="Set a node's name value (a message, an object, a property, an action): logic.name <graph> <node> <value 4-7> [text]"

# =============================================================================
#  Graphs
# =============================================================================
# lg_is_logic(edi=tree) -> eax = 1 when it is a logic graph
lg_is_logic:
    sub     rsp, 8
    call    nt_get
    add     rsp, 8
    test    rax, rax
    jz      1f
    mov     eax, [rax+TR_KIND]
    cmp     eax, 1
    sete    al
    movzx   eax, al
    ret
1:  xor     eax, eax
    ret

# lg_name_of(rdi=record, esi=slot 1..30) -> rax = the name (0: none)
lg_name_of:
    xor     eax, eax
    dec     esi
    cmp     esi, STR_N
    jae     9f
    imul    esi, esi, STR_SZ
    lea     rax, [rdi+TR_STR+rsi]
    cmp     byte ptr [rax], 0
    jne     9f
    xor     eax, eax
9:  ret

# lg_arg_graph(rsi=text) -> eax = a logic graph (or -1, said), rsi after
lg_arg_graph:
    push    rbx
    push    r12
    sub     rsp, 8
    call    im_next_word
    mov     rbx, rsi
    test    eax, eax
    jz      8f
    lea     rdi, [rip+im_word]
    call    nt_find
    test    eax, eax
    js      8f
    mov     r12d, eax
    mov     edi, eax
    call    lg_is_logic
    test    eax, eax
    jz      7f
    mov     eax, r12d
    jmp     9f
7:  lea     rdi, [rip+s_lg_notlogic]
    lea     rsi, [rip+im_word]
    call    log_pair
    mov     eax, -1
    jmp     9f
8:  lea     rdi, [rip+s_lg_none]
    lea     rsi, [rip+im_word]
    call    log_pair
    mov     eax, -1
9:  mov     rsi, rbx
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# lg_arg_num(rsi=text) -> xmm0, eax = 1 if a number, rsi after
lg_arg_num:
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

# logic.new [name]
do_logic_new:
    push    rbx
    mov     rsi, [rip+op_arg]
    call    im_next_word
    lea     rdi, [rip+im_word]
    test    eax, eax
    jnz     1f
    lea     rdi, [rip+s_lg_base]
1:  call    nt_new
    test    eax, eax
    js      8f
    mov     ebx, eax
    mov     edi, eax
    call    nt_own
    mov     dword ptr [rax+TR_KIND], 1
    mov     edi, ebx
    call    nt_get
    lea     rdi, [rip+s_lg_made]
    mov     rsi, rax
    call    log_pair
    pop     rbx
    ret
8:  call    undo_drop_last
    pop     rbx
    ret

# logic.attach <graph> [object]
do_logic_attach:
    push    rbx
    push    r12
    push    r13
    mov     rsi, [rip+op_arg]
    call    lg_arg_graph
    test    eax, eax
    js      8f
    mov     r12d, eax
    call    im_next_word
    test    eax, eax
    jz      1f
    lea     rdi, [rip+im_word]
    call    obj_find
    test    eax, eax
    jz      7f
    mov     edi, eax
    call    obj_get
    jmp     2f
1:  call    active_mesh_obj
2:  test    rax, rax
    jz      7f
    cmp     dword ptr [rax+OB_TYPE], OT_MESH
    jne     7f
    mov     rbx, rax
    mov     rdi, rbx
    mov     esi, MT_LOGIC
    call    mod_add
    test    eax, eax
    js      7f
    mov     r13d, eax
    lea     eax, [r12+1]
    cvtsi2ss xmm0, eax
    mov     rdi, rbx
    mov     esi, r13d
    xor     edx, edx
    call    mod_param_set
    lea     rdi, [rip+s_lg_attached]
    mov     rsi, rbx
    call    log_pair
    jmp     9f
7:  lea     rdi, [rip+s_lg_attneed]
    call    log_line
8:  call    undo_drop_last
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# lg_type_index(rdi=word) -> eax = type (1..) or -1
lg_type_index:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     r12, rdi
    xor     ebx, ebx
1:  lea     rax, [rip+lg_type_names]
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

# logic.node <graph> <type> [values]
do_logic_node:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 24
    mov     rsi, [rip+op_arg]
    call    lg_arg_graph
    test    eax, eax
    js      .Lln_drop
    mov     r12d, eax
    call    im_next_word
    mov     r14, rsi
    test    eax, eax
    jz      .Lln_need
    lea     rdi, [rip+im_word]
    call    lg_type_index
    test    eax, eax
    js      .Lln_need
    lea     ecx, [rax-1]
    imul    ecx, ecx, 52
    lea     rdx, [rip+lg_defaults]
    add     rdx, rcx
    mov     edi, r12d
    mov     esi, eax
    call    nt_add
    test    eax, eax
    js      .Lln_need
    mov     r13d, eax
    mov     ebx, 4                      # values: slots 4..7
1:  cmp     ebx, 8
    jae     2f
    mov     rsi, r14
    call    lg_arg_num
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
2:  call    fmt_reset
    lea     rdi, [rip+s_lg_node]
    call    fmt_str
    mov     edi, r13d
    call    fmt_int
    lea     rdi, [rip+fmt_buf]
    call    log_line
    jmp     .Lln_out
.Lln_need:
    lea     rdi, [rip+s_lg_need]
    call    log_line
.Lln_drop:
    call    undo_drop_last
.Lln_out:
    add     rsp, 24
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# logic.name <graph> <node> <value 4-7> [text]
do_logic_name:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 32
    mov     rsi, [rip+op_arg]
    call    lg_arg_graph
    test    eax, eax
    js      .Llm_drop
    mov     r12d, eax
    call    lg_arg_num
    test    eax, eax
    jz      .Llm_need
    cvttss2si r13d, xmm0
    call    lg_arg_num
    test    eax, eax
    jz      .Llm_need
    cvttss2si r14d, xmm0
    lea     eax, [r14-4]
    cmp     eax, 4
    jae     .Llm_need
    call    im_next_word                # the text (up to 15 characters)
    cmp     eax, STR_SZ-1
    ja      .Llm_need
    mov     r15d, eax
    mov     edi, r12d
    call    nt_own
    test    rax, rax
    jz      .Llm_drop
    mov     rbx, rax
    test    r13d, r13d
    jle     .Llm_need
    cmp     r13d, [rbx+GR_N]
    ja      .Llm_need
    xor     eax, eax                    # no text: none
    test    r15d, r15d
    jz      5f
    mov     rdi, rbx                    # the names in use
    call    lg_names_used
    mov     r8, rax
    xor     ecx, ecx                    # the same name already there?
1:  cmp     ecx, STR_N
    jae     2f
    bt      r8, rcx
    jnc     11f
    imul    eax, ecx, STR_SZ
    lea     rdi, [rbx+TR_STR+rax]
    lea     rsi, [rip+im_word]
    push    rcx
    push    r8
    call    str_eq
    pop     r8
    pop     rcx
    test    eax, eax
    jnz     4f
11: inc     ecx
    jmp     1b
2:  xor     ecx, ecx                    # a free slot
3:  cmp     ecx, STR_N
    jae     .Llm_full
    bt      r8, rcx
    jnc     31f
    inc     ecx
    jmp     3b
31: imul    eax, ecx, STR_SZ
    lea     rdi, [rbx+TR_STR+rax]
    push    rcx
    push    rcx
    mov     ecx, STR_SZ                 # cleared, then the text
    push    rdi
    xor     eax, eax
    rep     stosb
    pop     rdi
    lea     rsi, [rip+im_word]
    mov     ecx, r15d
    rep     movsb
    pop     rcx
    pop     rcx
4:  lea     eax, [rcx+1]
5:  cvtsi2ss xmm0, eax
    movss   [rsp], xmm0
    mov     edi, r12d
    mov     esi, r13d
    mov     edx, r14d
    lea     rcx, [rsp]
    mov     r8d, 1
    call    nt_set
    jmp     .Llm_out
.Llm_full:
    lea     rdi, [rip+s_lg_full]
    call    log_line
    jmp     .Llm_drop
.Llm_need:
    lea     rdi, [rip+s_lg_nameneed]
    call    log_line
.Llm_drop:
    call    undo_drop_last
.Llm_out:
    add     rsp, 32
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# lg_names_used(rdi=record) -> rax = bit per name slot some node's name
#   value points at
lg_names_used:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     rbx, rdi
    xor     r12d, r12d                  # the bits
    xor     r13d, r13d                  # node
1:  cmp     r13d, [rbx+GR_N]
    jae     9f
    imul    eax, r13d, NODE_SZ
    lea     r14, [rbx+GR_NODES+rax]
    mov     eax, [r14+ND_TYPE]
    dec     eax
    cmp     eax, LG_NTYPES
    jae     4f
    inc     eax
    imul    eax, eax, 56
    lea     rcx, [rip+lg_meta]
    mov     rcx, [rcx+rax+24]           # value kinds
    xor     edx, edx
2:  cmp     edx, 4
    jae     4f
    cmp     byte ptr [rcx+rdx], 5
    jne     3f
    cvttss2si eax, [r14+ND_P+rdx*4]
    dec     eax
    cmp     eax, STR_N
    jae     3f
    bts     r12, rax
3:  inc     edx
    jmp     2b
4:  inc     r13d
    jmp     1b
9:  mov     rax, r12
    add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Play mode
# =============================================================================
# lg_begin - (play.start) every object with a Logic modifier gets its graph
#   running
lg_begin:
    push    rbx
    sub     rsp, 16
    xor     eax, eax                    # counters, keys, touches
    mov     dword ptr [rip+lg_n], 0
    mov     dword ptr [rip+lg_mqn], 0
    mov     dword ptr [rip+lg_time], 0
    mov     dword ptr [rip+lg_steps], 0
    mov     dword ptr [rip+lg_runs], 0
    mov     dword ptr [rip+lg_runs_step], 0
    mov     dword ptr [rip+lg_events], 0
    mov     dword ptr [rip+lg_msgs], 0
    mov     dword ptr [rip+lg_spawned], 0
    mov     dword ptr [rip+lg_overs], 0
    mov     dword ptr [rip+lg_said], 0
    lea     rdi, [rip+lg_kdown]
    mov     ecx, 96+512
    rep     stosb
    xor     ebx, ebx
1:  cmp     ebx, [rip+obj_count]
    jae     2f
    lea     rax, [rip+obj_list]
    mov     edi, [rax+rbx*4]
    call    lg_add_obj
    inc     ebx
    jmp     1b
2:  mov     dword ptr [rip+lg_on], 1
    add     rsp, 16
    pop     rbx
    ret

# lg_end - (play.stop) nothing runs
lg_end:
    mov     dword ptr [rip+lg_on], 0
    mov     dword ptr [rip+lg_n], 0
    ret

# lg_add_obj(edi=handle) - an instance per enabled Logic modifier naming a
#   logic graph
lg_add_obj:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     r12d, edi
    call    obj_get
    test    rax, rax
    jz      9f
    cmp     dword ptr [rax+OB_TYPE], OT_MESH
    jne     9f
    mov     rbx, [rax+OB_MODS]
    test    rbx, rbx
    jz      9f
    xor     r13d, r13d
1:  cmp     r13d, [rbx+4]               # (the stack: count, records from 16)
    jae     9f
    imul    eax, r13d, 48
    lea     r14, [rbx+16+rax]
    cmp     dword ptr [r14], MT_LOGIC
    jne     3f
    test    dword ptr [r14+4], 1
    jz      3f
    cvttss2si edi, [r14+8]
    dec     edi
    js      3f
    push    rdi
    push    rdi
    call    lg_is_logic
    pop     rdi
    pop     rdi
    test    eax, eax
    jz      3f
    mov     ecx, [rip+lg_n]
    cmp     ecx, LG_MAXI
    jae     9f
    imul    rax, rcx, LI_SZ
    lea     rdx, [rip+lg_tab]
    add     rdx, rax
    push    rdi
    push    rdx
    mov     rdi, rdx
    mov     ecx, LI_SZ
    xor     eax, eax
    rep     stosb
    pop     rdx
    pop     rdi
    mov     [rdx+LI_OBJ], r12d
    mov     [rdx+LI_TREE], edi
    inc     dword ptr [rip+lg_n]
3:  inc     r13d
    jmp     1b
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# lg_key(edi=evdev code, esi=1 down / 0 up) - (play_key) what the keys did
lg_key:
    cmp     edi, 256
    jae     9f
    test    esi, esi
    jz      1f
    bts     [rip+lg_kdown], edi
    jc      9f                          # (repeats: held already)
    bts     [rip+lg_kpress], edi
    ret
1:  btr     [rip+lg_kdown], edi
    jnc     9f
    bts     [rip+lg_krel], edi
9:  ret

# lg_touch(edi=object handle) - (play.s) the player touched it this step
lg_touch:
    and     edi, 4095
    bts     [rip+lg_tnow], edi
    ret

# lg_stat(edi=k) -> xmm0: 0 running, 1 graphs running (objects), 2 nodes run,
#   3 events fired, 4 messages sent, 5 objects spawned, 6 steps past the
#   budget, 7 nodes the last step ran, 8 steps
lg_stat:
    lea     rax, [rip+lg_stat_tab]
    xorps   xmm0, xmm0
    cmp     edi, 8
    ja      9f
    mov     rax, [rax+rdi*8]
    cvtsi2ss xmm0, dword ptr [rax]
9:  ret
.section .rodata
.align 8
lg_stat_tab:    .quad lg_on, lg_n, lg_runs, lg_events, lg_msgs, lg_spawned, lg_overs
                .quad lg_runs_step, lg_steps
.text

# lg_var(edi=object handle, esi=variable 0..7, edx=component 0..2) -> xmm0
#   (its first graph's), eax = 1 found
lg_var:
    xorps   xmm0, xmm0
    xor     eax, eax
    cmp     esi, 8
    jae     9f
    cmp     edx, 3
    jae     9f
    xor     ecx, ecx
    lea     r8, [rip+lg_tab]
1:  cmp     ecx, [rip+lg_n]
    jae     9f
    cmp     [r8+LI_OBJ], edi
    je      2f
    add     r8, LI_SZ
    inc     ecx
    jmp     1b
2:  shl     esi, 4
    lea     rax, [r8+LI_VARS+rsi]
    movss   xmm0, [rax+rdx*4]
    mov     eax, 1
9:  ret

# =============================================================================
#  The step
# =============================================================================
# lg_step(xmm0=seconds) - (play mode's fixed step) every graph: its events,
#   then the messages sent
lg_step:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    cmp     dword ptr [rip+lg_on], 0
    je      .Lls_out
    movss   [rip+lg_dt], xmm0
    addss   xmm0, [rip+lg_time]
    movss   [rip+lg_time], xmm0
    inc     dword ptr [rip+lg_steps]
    mov     dword ptr [rip+lg_budget], LG_BUDGET
    mov     eax, [rip+lg_runs]
    mov     [rsp], eax
    mov     r15d, [rip+lg_n]            # (spawned ones: from the next step)
    xor     r14d, r14d
.Lls_inst:
    cmp     r14d, r15d
    jae     .Lls_msgs
    mov     edi, r14d
    call    lg_enter
    test    rax, rax
    jz      .Lls_next
    mov     r12, rax                    # the instance
    mov     rbx, [rip+lg_rec]
    test    dword ptr [r12+LI_FLAGS], 1
    jnz     1f
    or      dword ptr [r12+LI_FLAGS], 1 # begun: where it starts, the timers
    call    lg_self
    movups  xmm0, [rax+OB_LOC]
    andps   xmm0, [rip+lf_xyz]
    movaps  [r12+LI_START], xmm0
    mov     r13d, 1
11: cmp     r13d, [rbx+GR_N]
    ja      12f
    mov     edi, r13d
    call    lg_node
    cmp     dword ptr [rax+ND_TYPE], LT_TIMER
    jne     111f
    movss   xmm0, [rax+ND_P]
    movss   [r12+LI_TIMER+r13*4-4], xmm0
111:inc     r13d
    jmp     11b
12: mov     edi, LT_BEGIN
    call    lg_fire_all
1:  mov     eax, [rip+lg_dt]            # every tick
    mov     [rip+lg_ctx_v1], eax
    mov     eax, [rip+lg_time]
    mov     [rip+lg_ctx_v2], eax
    mov     edi, LT_TICK
    call    lg_fire_all
    mov     r13d, 1                     # keys, overlaps, hits, timers
.Lls_node:
    test    dword ptr [r12+LI_FLAGS], 2 # (gone meanwhile)
    jnz     .Lls_hitdone
    cmp     r13d, [rbx+GR_N]
    ja      .Lls_hitdone
    mov     edi, r13d
    call    lg_node
    mov     rcx, rax
    mov     eax, [rcx+ND_TYPE]
    cmp     eax, LT_KEY
    je      .Lls_key
    cmp     eax, LT_OVER
    je      .Lls_over
    cmp     eax, LT_HIT
    je      .Lls_hit
    cmp     eax, LT_TIMER
    je      .Lls_timer
    jmp     .Lls_nnext
.Lls_key:
    cvttss2si edx, [rcx+ND_P]
    cmp     edx, 256
    jae     .Lls_nnext
    cvttss2si eax, [rcx+ND_P+4]
    lea     r8, [rip+lg_kpress]
    cmp     eax, 1
    jne     21f
    lea     r8, [rip+lg_krel]
21: cmp     eax, 2
    jne     22f
    lea     r8, [rip+lg_kdown]
22: bt      [r8], edx
    jnc     .Lls_nnext
    mov     edi, r13d
    call    lg_fire
    jmp     .Lls_nnext
.Lls_over:
    mov     edi, r13d
    call    lg_overlap                  # eax = inside now
    mov     rdx, [r12+LI_INSIDE]
    bt      rdx, r13
    setc    cl                          # and before
    movzx   ecx, cl
    mov     [rsp+12], ecx
    mov     [rsp+8], eax
    btr     rdx, r13
    test    eax, eax
    jz      31f
    bts     rdx, r13
31: mov     [r12+LI_INSIDE], rdx
    mov     edi, r13d
    call    lg_node
    cvttss2si ecx, [rax+ND_P+4]         # when: enter, leave, inside
    mov     eax, [rsp+8]
    mov     edx, [rsp+12]
    cmp     ecx, 1
    je      33f
    cmp     ecx, 2
    je      34f
    test    eax, eax                    # enter: now, not before
    jz      .Lls_nnext
    test    edx, edx
    jnz     .Lls_nnext
    jmp     35f
33: test    eax, eax                    # leave: before, not now
    jnz     .Lls_nnext
    test    edx, edx
    jz      .Lls_nnext
    jmp     35f
34: test    eax, eax                    # inside
    jz      .Lls_nnext
35: mov     edi, r13d
    call    lg_fire
    jmp     .Lls_nnext
.Lls_hit:
    mov     eax, [r12+LI_OBJ]
    and     eax, 4095
    bt      [rip+lg_tnow], eax
    jnc     .Lls_nnext
    test    dword ptr [r12+LI_FLAGS], 4 # (touching last step too: no)
    jnz     .Lls_nnext
    mov     edi, r13d
    call    lg_fire
    jmp     .Lls_nnext
.Lls_timer:
    mov     rdx, [r12+LI_TDONE]
    bt      rdx, r13
    jc      .Lls_nnext
    movss   xmm0, [r12+LI_TIMER+r13*4-4]
    subss   xmm0, [rip+lg_dt]
    movss   [r12+LI_TIMER+r13*4-4], xmm0
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    ja      .Lls_nnext
    cvttss2si eax, [rcx+ND_P+4]         # repeat: again after the seconds
    test    eax, eax
    jz      41f
    movss   xmm1, [rcx+ND_P]
    maxss   xmm1, [rip+lg_dt]
    addss   xmm0, xmm1
    movss   [r12+LI_TIMER+r13*4-4], xmm0
    jmp     42f
41: bts     rdx, r13
    mov     [r12+LI_TDONE], rdx
42: mov     edi, r13d
    call    lg_fire
.Lls_nnext:
    inc     r13d
    jmp     .Lls_node
.Lls_hitdone:
    mov     eax, [r12+LI_OBJ]           # touched this step: remembered
    and     eax, 4095
    and     dword ptr [r12+LI_FLAGS], ~4
    bt      [rip+lg_tnow], eax
    jnc     .Lls_next
    or      dword ptr [r12+LI_FLAGS], 4
.Lls_next:
    inc     r14d
    jmp     .Lls_inst
.Lls_msgs:
    call    lg_deliver
    lea     rdi, [rip+lg_kpress]        # the step's edges and touches go
    xor     eax, eax
    mov     ecx, 64
    rep     stosb
    lea     rdi, [rip+lg_tnow]
    mov     ecx, 512
    rep     stosb
    mov     eax, [rip+lg_runs]
    sub     eax, [rsp]
    mov     [rip+lg_runs_step], eax
.Lls_out:
    add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# lg_enter(edi=instance) -> rax = the instance (lg_cur, lg_rec set), or 0
#   (gone: its object or graph)
lg_enter:
    push    rbx
    push    r12
    sub     rsp, 8
    imul    rbx, rdi, LI_SZ
    lea     rax, [rip+lg_tab]
    add     rbx, rax
    mov     [rip+lg_cur], edi
    test    dword ptr [rbx+LI_FLAGS], 2
    jnz     8f
    mov     edi, [rbx+LI_OBJ]
    call    obj_get
    test    rax, rax
    jz      7f
    mov     edi, [rbx+LI_TREE]
    call    nt_get
    test    rax, rax
    jz      7f
    cmp     dword ptr [rax+TR_KIND], 1
    jne     7f
    mov     [rip+lg_rec], rax
    mov     rax, rbx
    jmp     9f
7:  or      dword ptr [rbx+LI_FLAGS], 2
8:  xor     eax, eax
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# lg_inst -> rax = the instance running
lg_inst:
    mov     eax, [rip+lg_cur]
    imul    rax, rax, LI_SZ
    lea     rcx, [rip+lg_tab]
    add     rax, rcx
    ret

# lg_self -> rax = its object (or 0)
lg_self:
    sub     rsp, 8
    call    lg_inst
    mov     edi, [rax+LI_OBJ]
    call    obj_get
    add     rsp, 8
    ret

# lg_node(edi=node 1..) -> rax = it in the running graph
lg_node:
    lea     eax, [rdi-1]
    imul    eax, eax, NODE_SZ
    add     rax, [rip+lg_rec]
    add     rax, GR_NODES
    ret

# lg_vname(edi=node, esi=value 0..3) -> rax = the name it holds, or 0
lg_vname:
    push    rbx
    mov     ebx, esi
    call    lg_node
    cvttss2si esi, [rax+ND_P+rbx*4]
    mov     rdi, [rip+lg_rec]
    call    lg_name_of
    pop     rbx
    ret

# lg_target(edi=node, esi=value) -> rax = the object named there (none
#   named: its own object; a name not found: 0)
lg_target:
    sub     rsp, 8
    call    lg_vname
    test    rax, rax
    jz      1f
    mov     rdi, rax
    call    obj_find
    test    eax, eax
    jz      8f
    mov     edi, eax
    call    obj_get
    add     rsp, 8
    ret
1:  call    lg_self
    add     rsp, 8
    ret
8:  xor     eax, eax
    add     rsp, 8
    ret

# lg_fire_all(edi=type) - every event node of that type fires
lg_fire_all:
    push    rbx
    push    r12
    push    r13
    mov     r12d, edi
    mov     ebx, 1
1:  mov     rax, [rip+lg_rec]
    cmp     ebx, [rax+GR_N]
    ja      9f
    mov     edi, ebx
    call    lg_node
    cmp     [rax+ND_TYPE], r12d
    jne     2f
    mov     edi, ebx
    call    lg_fire
2:  inc     ebx
    jmp     1b
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# lg_fire(edi=event node) - its chain runs (lg_ctx_v1 / v2: its outputs)
lg_fire:
    sub     rsp, 8
    inc     dword ptr [rip+lg_events]
    mov     [rip+lg_ctx_node], edi
    xor     esi, esi
    call    lg_run_from
    add     rsp, 8
    ret

# lg_run_from(edi=node, esi=output) - the nodes whose Run input takes it
lg_run_from:
    push    rbx
    push    r12
    push    r13
    shl     esi, 16
    or      esi, edi
    mov     r12d, esi                   # the link to look for
    mov     ebx, 1
1:  mov     rax, [rip+lg_rec]
    cmp     ebx, [rax+GR_N]
    ja      9f
    mov     edi, ebx
    call    lg_node
    mov     ecx, [rax+ND_TYPE]
    cmp     ecx, LT_SHATTER             # (actions: move .. branch, shatter,
    je      21f                         #  set strength)
    cmp     ecx, LT_SETSTR
    je      21f
    cmp     ecx, LT_MOVE
    jb      2f
    cmp     ecx, LT_BRANCH
    ja      2f
21:
    mov     ecx, [rax+ND_IN]
    and     ecx, 0xffffff
    cmp     ecx, r12d
    jne     2f
    mov     edi, ebx
    call    lg_exec
2:  inc     ebx
    jmp     1b
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# lg_exec(edi=node) - an action (or branch) runs, then what follows it
lg_exec:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 48
    mov     ebx, edi
    cmp     dword ptr [rip+lg_budget], 0
    jg      1f
    inc     dword ptr [rip+lg_overs]    # past the budget: dropped
    cmp     dword ptr [rip+lg_said], 0
    jne     .Lle_out
    mov     dword ptr [rip+lg_said], 1
    lea     rdi, [rip+s_lg_over]
    call    log_line
    jmp     .Lle_out
1:  dec     dword ptr [rip+lg_budget]
    inc     dword ptr [rip+lg_runs]
    call    lg_node
    mov     r12, rax
    mov     eax, [r12+ND_TYPE]
    xor     r15d, r15d                  # the output that goes on
    cmp     eax, LT_MOVE
    je      .Lle_move
    cmp     eax, LT_ROT
    je      .Lle_rot
    cmp     eax, LT_SETP
    je      .Lle_setp
    cmp     eax, LT_SPAWN
    je      .Lle_spawn
    cmp     eax, LT_DESTROY
    je      .Lle_destroy
    cmp     eax, LT_ACTION
    je      .Lle_action
    cmp     eax, LT_IMPULSE
    je      .Lle_impulse
    cmp     eax, LT_VIS
    je      .Lle_vis
    cmp     eax, LT_SEND
    je      .Lle_send
    cmp     eax, LT_SETVAR
    je      .Lle_setvar
    cmp     eax, LT_BRANCH
    je      .Lle_branch
    cmp     eax, LT_SHATTER
    je      .Lle_shatter
    cmp     eax, LT_SETSTR
    je      .Lle_setstr
    jmp     .Lle_then

.Lle_setstr:                            # a force field's strength: Value's x
    mov     edi, ebx
    xor     esi, esi
    call    lg_target
    test    rax, rax
    jz      .Lle_then
    cmp     dword ptr [rax+OB_TYPE], OT_FIELD
    jne     .Lle_then
    mov     r13d, [rax+OB_UID]
    mov     edi, ebx
    mov     esi, 1
    call    lg_input
    movss   [rsp+32], xmm0
    mov     edi, r13d
    xor     esi, esi
    call    fl_rec_own
    test    rax, rax
    jz      .Lle_then
    movss   xmm0, [rsp+32]
    movss   [rax+FF_STR], xmm0
    mov     dword ptr [rip+dirty], 1
    jmp     .Lle_then

.Lle_move:
    mov     r13d, OB_LOC
    movss   xmm2, [rip+lf_one]
    jmp     .Lle_xform
.Lle_rot:
    mov     r13d, OB_ROT
    movss   xmm2, [rip+lf_deg]
.Lle_xform:
    movss   [rsp+32], xmm2
    mov     edi, ebx
    mov     esi, 1
    call    lg_input
    movss   xmm2, [rsp+32]
    shufps  xmm2, xmm2, 0
    mulps   xmm0, xmm2
    movaps  [rsp], xmm0
    call    lg_self
    test    rax, rax
    jz      .Lle_then
    movaps  xmm0, [rsp]
    cvttss2si ecx, [r12+ND_P]           # by / to
    test    ecx, ecx
    jnz     2f
    movups  xmm1, [rax+r13]
    addps   xmm0, xmm1
2:  movsd   [rax+r13], xmm0
    extractps [rax+r13+8], xmm0, 2
    mov     dword ptr [rip+dirty], 1
    jmp     .Lle_then

.Lle_setp:
    mov     edi, ebx
    mov     esi, 1
    call    lg_input
    movss   [rsp], xmm0
    mov     edi, ebx
    mov     esi, 1
    call    lg_target
    test    rax, rax
    jz      .Lle_then
    mov     r13, rax
    mov     edi, ebx
    xor     esi, esi
    call    lg_vname
    test    rax, rax
    jz      .Lle_then
    mov     rdi, rax
    call    lg_prop
    cmp     eax, -2
    je      .Lle_then
    movss   xmm0, [rsp]
    cmp     eax, -1
    je      3f
    movss   [r13+rax], xmm0
    mov     dword ptr [rip+dirty], 1
    jmp     .Lle_then
3:  mov     rdi, r13                    # visible
    call    lg_show
    jmp     .Lle_then

.Lle_spawn:
    cmp     dword ptr [rip+lg_spawned], LG_MAXSPAWN
    jae     .Lle_then
    mov     edi, ebx
    xor     esi, esi
    call    lg_vname
    test    rax, rax
    jz      .Lle_then
    mov     rdi, rax
    call    obj_find
    test    eax, eax
    jz      .Lle_then
    mov     r13d, eax                   # the template
    mov     edi, ebx
    mov     esi, 1
    call    lg_input
    movaps  [rsp], xmm0
    call    lg_self
    test    rax, rax
    jz      .Lle_then
    movups  xmm1, [rax+OB_LOC]
    andps   xmm1, [rip+lf_xyz]
    addps   xmm1, [rsp]
    movaps  [rsp], xmm1
    mov     edi, r13d
    call    obj_copy
    test    eax, eax
    jz      .Lle_then
    mov     r14d, eax
    mov     edi, eax
    call    obj_get
    movaps  xmm0, [rsp]
    movsd   [rax+OB_LOC], xmm0
    extractps [rax+OB_LOC+8], xmm0, 2
    and     dword ptr [rax+OB_FLAGS], ~(OBF_HIDDEN|OBF_SELECTED)
    inc     dword ptr [rip+lg_spawned]
    mov     edi, r14d
    call    lg_add_obj
    call    lg_reenter
    mov     dword ptr [rip+dirty], 1
    jmp     .Lle_then

.Lle_shatter:                           # its prepared pieces take its place
    mov     edi, ebx                    #  (object.shatter ... impact)
    xor     esi, esi
    call    lg_target
    test    rax, rax
    jz      .Lle_then
    mov     rdi, rax
    call    rb_shatter_obj
    jmp     .Lle_then

.Lle_destroy:
    mov     edi, ebx
    xor     esi, esi
    call    lg_target
    test    rax, rax
    jz      .Lle_then
    or      dword ptr [rax+OB_FLAGS], OBF_HIDDEN
    and     dword ptr [rax+OB_FLAGS], ~OBF_SELECTED
    mov     rdi, rax
    call    lg_kill
    mov     dword ptr [rip+dirty], 1
    jmp     .Lle_then

.Lle_action:
    mov     edi, ebx
    xor     esi, esi
    call    lg_vname
    test    rax, rax
    jz      .Lle_then
    mov     rdi, rax
    call    an_action_find
    test    eax, eax
    jz      .Lle_then
    mov     r13d, eax
    call    lg_self
    test    rax, rax
    jz      .Lle_then
    mov     esi, [rax+OB_UID]
    mov     edi, r13d
    movss   xmm0, [rip+an_frame]
    movss   xmm1, [r12+ND_P+4]
    call    an_layer_play
    jmp     .Lle_then

.Lle_impulse:
    mov     edi, ebx
    mov     esi, 1
    call    lg_input
    movaps  [rsp], xmm0
    mov     edi, ebx
    xor     esi, esi
    call    lg_target
    test    rax, rax
    jz      .Lle_then
    mov     rdi, rax
    movaps  xmm0, [rsp]
    call    rb_impulse
    jmp     .Lle_then

.Lle_vis:
    mov     edi, ebx
    mov     esi, 1
    call    lg_input
    movss   [rsp], xmm0
    mov     edi, ebx
    xor     esi, esi
    call    lg_target
    test    rax, rax
    jz      .Lle_then
    mov     rdi, rax
    movss   xmm0, [rsp]
    call    lg_show
    jmp     .Lle_then

.Lle_send:
    mov     edi, ebx
    xor     esi, esi
    call    lg_vname
    test    rax, rax
    jz      .Lle_then
    mov     r13, rax                    # the name
    xor     r14d, r14d                  # to: everyone
    mov     edi, ebx
    mov     esi, 1
    call    lg_vname
    test    rax, rax
    jz      5f
    mov     rdi, rax
    call    obj_find
    test    eax, eax
    jz      .Lle_then
    mov     r14d, eax
5:  mov     edi, ebx
    mov     esi, 1
    call    lg_input
    mov     ecx, [rip+lg_mqn]
    cmp     ecx, LG_MAXQ
    jae     .Lle_then
    inc     dword ptr [rip+lg_mqn]
    inc     dword ptr [rip+lg_msgs]
    shl     ecx, 5
    lea     rdi, [rip+lg_mq]
    add     rdi, rcx
    movups  xmm1, [r13]
    movups  [rdi], xmm1
    mov     [rdi+16], r14d
    movss   [rdi+20], xmm0
    jmp     .Lle_then

.Lle_setvar:
    mov     edi, ebx
    mov     esi, 1
    call    lg_input
    cvttss2si ecx, [r12+ND_P]
    cmp     ecx, 8
    jae     .Lle_then
    shl     ecx, 4
    movaps  [rsp], xmm0
    mov     [rsp+16], ecx
    call    lg_inst
    mov     ecx, [rsp+16]
    lea     rax, [rax+LI_VARS+rcx]
    movaps  xmm0, [rsp]
    cvttss2si ecx, [r12+ND_P+4]         # set / add
    test    ecx, ecx
    jz      6f
    addps   xmm0, [rax]
6:  movaps  [rax], xmm0
    jmp     .Lle_then

.Lle_branch:
    mov     edi, ebx
    mov     esi, 1
    call    lg_input
    comiss  xmm0, [rip+lf_half]
    ja      .Lle_then
    mov     r15d, 1

.Lle_then:
    mov     edi, ebx
    mov     esi, r15d
    call    lg_run_from
.Lle_out:
    add     rsp, 48
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# lg_reenter - the running graph again (a spawn may have moved nothing, but
#   the record pointer is fetched anew to be safe)
lg_reenter:
    push    rbx
    call    lg_inst
    mov     edi, [rax+LI_TREE]
    call    nt_get
    test    rax, rax
    jz      9f
    mov     [rip+lg_rec], rax
9:  pop     rbx
    ret

# lg_show(rdi=object, xmm0=visible when > 0.5)
lg_show:
    comiss  xmm0, [rip+lf_half]
    ja      1f
    or      dword ptr [rdi+OB_FLAGS], OBF_HIDDEN
    and     dword ptr [rdi+OB_FLAGS], ~OBF_SELECTED
    jmp     9f
1:  and     dword ptr [rdi+OB_FLAGS], ~OBF_HIDDEN
9:  mov     dword ptr [rip+dirty], 1
    ret

# lg_kill(rdi=object) - its graphs stop (destroyed)
lg_kill:
    push    rbx
    mov     rbx, rdi
    mov     rdi, rbx                    # its handle
    call    obj_handle
    xor     ecx, ecx
    lea     rdx, [rip+lg_tab]
1:  cmp     ecx, [rip+lg_n]
    jae     9f
    cmp     [rdx+LI_OBJ], eax
    jne     2f
    or      dword ptr [rdx+LI_FLAGS], 2
2:  add     rdx, LI_SZ
    inc     ecx
    jmp     1b
9:  pop     rbx
    ret

# obj_handle(rdi=object) -> eax = its handle (0: not in the scene)
obj_handle:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     r12, rdi
    xor     ebx, ebx
1:  cmp     ebx, [rip+obj_count]
    jae     8f
    mov     edi, ebx
    call    obj_at
    cmp     rax, r12
    je      2f
    inc     ebx
    jmp     1b
2:  lea     rax, [rip+obj_list]
    mov     eax, [rax+rbx*4]
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# lg_prop(rdi=name) -> eax = its offset in the object, -1 visible, -2 none
lg_prop:
    push    rbx
    mov     rbx, rdi
    call    str_len
    cmp     eax, 8
    jae     8f
    mov     ecx, eax
    xor     eax, eax                    # packed, little-endian
1:  test    ecx, ecx
    jz      2f
    dec     ecx
    shl     rax, 8
    mov     al, [rbx+rcx]
    jmp     1b
2:  lea     rdx, [rip+lg_props]
3:  lea     rcx, [rip+lg_props_end]
    cmp     rdx, rcx
    jae     8f
    cmp     rax, [rdx]
    je      4f
    add     rdx, 16
    jmp     3b
4:  mov     eax, [rdx+8]
    pop     rbx
    ret
8:  mov     eax, -2
    pop     rbx
    ret

# lg_deliver - the messages sent this step, to every graph listening (or
#   the one object); messages sent meanwhile too, up to LG_MAXQ
lg_deliver:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    xor     r15d, r15d                  # the message
1:  cmp     r15d, [rip+lg_mqn]
    jae     9f
    mov     r14d, [rip+lg_n]
    xor     r13d, r13d                  # the instance
2:  cmp     r13d, r14d
    jae     8f
    mov     edi, r13d
    call    lg_enter
    test    rax, rax
    jz      7f
    mov     r12, rax
    mov     eax, r15d
    shl     eax, 5
    lea     rcx, [rip+lg_mq]
    add     rcx, rax
    mov     eax, [rcx+16]               # to one object?
    test    eax, eax
    jz      3f
    cmp     eax, [r12+LI_OBJ]
    jne     7f
3:  mov     eax, [rcx+20]
    mov     [rip+lg_ctx_v1], eax
    mov     ebx, 1
4:  test    dword ptr [r12+LI_FLAGS], 2
    jnz     7f
    mov     rax, [rip+lg_rec]
    cmp     ebx, [rax+GR_N]
    ja      7f
    mov     edi, ebx
    call    lg_node
    cmp     dword ptr [rax+ND_TYPE], LT_MSG
    jne     5f
    mov     edi, ebx
    xor     esi, esi
    call    lg_vname
    test    rax, rax
    jz      5f
    mov     rdi, rax
    mov     eax, r15d
    shl     eax, 5
    lea     rsi, [rip+lg_mq]
    add     rsi, rax
    call    str_eq
    test    eax, eax
    jz      5f
    mov     eax, r15d                   # (the value again: a chain may
    shl     eax, 5                      #  have sent others)
    lea     rcx, [rip+lg_mq]
    mov     eax, [rcx+rax+20]
    mov     [rip+lg_ctx_v1], eax
    mov     edi, ebx
    call    lg_fire
5:  inc     ebx
    jmp     4b
7:  inc     r13d
    jmp     2b
8:  inc     r15d
    jmp     1b
9:  mov     dword ptr [rip+lg_mqn], 0
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Data
# =============================================================================
# lg_input(edi=node, esi=input 0..2) -> xmm0 = its value (x y z): the
#   constant, or what the linked output gives
lg_input:
    push    rbx
    push    r12
    push    r13
    mov     r12d, edi
    mov     r13d, esi
    call    lg_node
    mov     ecx, r13d
    shl     ecx, 4
    lea     rbx, [rax+ND_IN+rcx]
    mov     eax, [rbx]
    test    eax, eax
    jnz     1f
    movsd   xmm0, [rbx+4]               # the constant
    insertps xmm0, [rbx+12], 0x28
    jmp     9f
1:  movzx   ecx, ax                     # from: node, output
    shr     eax, 16
    and     eax, 0xff
    mov     r13d, eax
    test    ecx, ecx
    jz      8f
    mov     rdx, [rip+lg_rec]
    cmp     ecx, [rdx+GR_N]
    ja      8f
    mov     r12d, ecx
    mov     edi, ecx
    call    lg_node
    mov     eax, [rax+ND_TYPE]
    cmp     eax, LT_MSG                 # an event: the one firing gives
    ja      3f                          #  its outputs
    cmp     r12d, [rip+lg_ctx_node]
    jne     8f
    movss   xmm0, [rip+lg_ctx_v1]
    cmp     r13d, 1
    je      2f
    movss   xmm0, [rip+lg_ctx_v2]
    cmp     r13d, 2
    jne     8f
2:  shufps  xmm0, xmm0, 0
    andps   xmm0, [rip+lf_xyz]
    jmp     9f
3:  cmp     eax, LT_FIELD               # data nodes: pulled
    je      31f
    cmp     eax, LT_VAR
    jb      8f
    cmp     eax, LT_GETP
    ja      8f
31: mov     edi, r12d
    mov     esi, r13d
    call    lg_data
    jmp     9f
8:  xorps   xmm0, xmm0
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# lg_data(edi=data node, esi=output) -> xmm0
lg_data:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 64
    xorps   xmm0, xmm0
    cmp     dword ptr [rip+lg_depth], 64
    jae     .Lld_ret
    inc     dword ptr [rip+lg_depth]
    mov     ebx, edi
    mov     [rsp+56], esi               # (the output: a field's Force, Size)
    call    lg_node
    mov     r12, rax
    mov     eax, [r12+ND_TYPE]
    cmp     eax, LT_VAR
    je      .Lld_var
    cmp     eax, LT_MATH
    je      .Lld_math
    cmp     eax, LT_INFO
    je      .Lld_info
    cmp     eax, LT_GETP
    je      .Lld_getp
    cmp     eax, LT_FIELD
    je      .Lld_field
    xorps   xmm0, xmm0
    jmp     .Lld_out

.Lld_field:                             # the pull at Point: Force, its Size
    mov     r13d, [rsp+56]
    mov     edi, ebx
    xor     esi, esi
    call    lg_input
    movups  [rsp], xmm0
    lea     rdi, [rsp]
    lea     rsi, [rsp+16]
    call    fl_sample
    movups  xmm0, [rsp+16]
    andps   xmm0, [rip+lf_xyz]
    test    r13d, r13d
    jz      .Lld_vec
    dpps    xmm0, xmm0, 0x71
    sqrtss  xmm0, xmm0
    jmp     .Lld_bcast

.Lld_var:
    cvttss2si ecx, [r12+ND_P]
    xorps   xmm0, xmm0
    cmp     ecx, 8
    jae     .Lld_out
    shl     ecx, 4
    mov     [rsp], ecx
    call    lg_inst
    mov     ecx, [rsp]
    movaps  xmm0, [rax+LI_VARS+rcx]
    jmp     .Lld_out

.Lld_getp:
    mov     edi, ebx
    mov     esi, 1
    call    lg_target
    test    rax, rax
    jz      .Lld_zero
    mov     r13, rax
    mov     edi, ebx
    xor     esi, esi
    call    lg_vname
    test    rax, rax
    jz      .Lld_zero
    mov     rdi, rax
    call    lg_prop
    cmp     eax, -2
    je      .Lld_zero
    cmp     eax, -1
    je      1f
    movss   xmm0, [r13+rax]
    jmp     .Lld_bcast
1:  xorps   xmm0, xmm0                  # visible: 1 / 0
    test    dword ptr [r13+OB_FLAGS], OBF_HIDDEN
    jnz     .Lld_bcast
    movss   xmm0, [rip+lf_one]
    jmp     .Lld_bcast

.Lld_info:
    cvttss2si eax, [r12+ND_P]
    cmp     eax, 0
    je      .Lli_time
    cmp     eax, 1
    je      .Lli_delta
    cmp     eax, 2
    je      .Lli_loc
    cmp     eax, 3
    je      .Lli_rot
    cmp     eax, 4
    je      .Lli_start
    cmp     eax, 5
    je      .Lli_player
    cmp     eax, 6
    je      .Lli_dist
    cmp     eax, 7
    je      .Lli_frame
    cmp     eax, 8
    je      .Lli_random
    jmp     .Lld_zero
.Lli_time:
    movss   xmm0, [rip+lg_time]
    jmp     .Lld_bcast
.Lli_delta:
    movss   xmm0, [rip+lg_dt]
    jmp     .Lld_bcast
.Lli_frame:
    movss   xmm0, [rip+an_frame]
    jmp     .Lld_bcast
.Lli_loc:
    call    lg_self
    test    rax, rax
    jz      .Lld_zero
    movups  xmm0, [rax+OB_LOC]
    jmp     .Lld_vec
.Lli_rot:
    call    lg_self
    test    rax, rax
    jz      .Lld_zero
    movups  xmm0, [rax+OB_ROT]
    movss   xmm1, [rip+lf_rad]
    shufps  xmm1, xmm1, 0
    mulps   xmm0, xmm1
    jmp     .Lld_vec
.Lli_start:
    call    lg_inst
    movaps  xmm0, [rax+LI_START]
    jmp     .Lld_vec
.Lli_player:
    movaps  xmm0, [rip+pl_pos]
    jmp     .Lld_vec
.Lli_dist:
    call    lg_self
    test    rax, rax
    jz      .Lld_zero
    movups  xmm0, [rax+OB_LOC]
    andps   xmm0, [rip+lf_xyz]
    subps   xmm0, [rip+pl_pos]
    andps   xmm0, [rip+lf_xyz]
    dpps    xmm0, xmm0, 0x7f
    sqrtps  xmm0, xmm0
    jmp     .Lld_vec
.Lli_random:                            # a hash of the step, node, object
    xor     r13d, r13d
2:  mov     eax, [rip+lg_steps]
    imul    eax, eax, 73856093
    mov     ecx, ebx
    imul    ecx, ecx, 19349663
    xor     eax, ecx
    mov     ecx, [rip+lg_cur]
    imul    ecx, ecx, 83492791
    xor     eax, ecx
    lea     ecx, [r13*8+r13+1]
    imul    ecx, ecx, 0x27d4eb2d
    xor     eax, ecx
    mov     ecx, eax
    shr     ecx, 15
    xor     eax, ecx
    imul    eax, eax, 0x2c1b3c6d
    mov     ecx, eax
    shr     ecx, 12
    xor     eax, ecx
    imul    eax, eax, 0x297a2d39
    mov     ecx, eax
    shr     ecx, 15
    xor     eax, ecx
    shr     eax, 8
    cvtsi2ss xmm0, eax
    mulss   xmm0, [rip+lf_inv24]
    movss   [rsp+r13*4], xmm0
    inc     r13d
    cmp     r13d, 3
    jb      2b
    movaps  xmm0, [rsp]
    jmp     .Lld_vec

.Lld_math:
    mov     edi, ebx
    xor     esi, esi
    call    lg_input
    movaps  [rsp], xmm0                 # a
    mov     edi, ebx
    mov     esi, 1
    call    lg_input
    movaps  [rsp+16], xmm0              # b
    movaps  xmm1, xmm0
    movaps  xmm0, [rsp]
    cvttss2si eax, [r12+ND_P]
    cmp     eax, 17
    ja      .Lld_zero
    lea     rcx, [rip+lg_math_tab]
    jmp     [rcx+rax*8]
.Lm_add:
    addps   xmm0, xmm1
    jmp     .Lld_vec
.Lm_sub:
    subps   xmm0, xmm1
    jmp     .Lld_vec
.Lm_mul:
    mulps   xmm0, xmm1
    jmp     .Lld_vec
.Lm_div:                                # (by 0: 0)
    movaps  xmm2, xmm1
    andps   xmm2, [rip+lf_abs]
    cmpnltps xmm2, [rip+lf_eps4]
    divps   xmm0, xmm1
    andps   xmm0, xmm2
    jmp     .Lld_clean
.Lm_min:
    minps   xmm0, xmm1
    jmp     .Lld_vec
.Lm_max:
    maxps   xmm0, xmm1
    jmp     .Lld_vec
.Lm_sin:
    xor     ecx, ecx
1:  fld     dword ptr [rsp+rcx*4]
    fsin
    fstp    dword ptr [rsp+32+rcx*4]
    inc     ecx
    cmp     ecx, 3
    jb      1b
    movups  xmm0, [rsp+32]
    jmp     .Lld_vec
.Lm_cos:
    xor     ecx, ecx
1:  fld     dword ptr [rsp+rcx*4]
    fcos
    fstp    dword ptr [rsp+32+rcx*4]
    inc     ecx
    cmp     ecx, 3
    jb      1b
    movups  xmm0, [rsp+32]
    jmp     .Lld_vec
.Lm_gt:
    cmpltps xmm1, xmm0
    andps   xmm1, [rip+lf_ones]
    movaps  xmm0, xmm1
    jmp     .Lld_vec
.Lm_lt:
    cmpltps xmm0, xmm1
    andps   xmm0, [rip+lf_ones]
    jmp     .Lld_vec
.Lm_eq:
    subps   xmm0, xmm1
    andps   xmm0, [rip+lf_abs]
    cmpltps xmm0, [rip+lf_eps4]
    andps   xmm0, [rip+lf_ones]
    jmp     .Lld_vec
.Lm_and:
    cmpltps xmm0, [rip+lf_halfs]        # (a <= 0.5 or b <= 0.5: 0)
    cmpltps xmm1, [rip+lf_halfs]
    orps    xmm0, xmm1
    andnps  xmm0, [rip+lf_ones]
    jmp     .Lld_vec
.Lm_or:
    movaps  xmm2, [rip+lf_halfs]
    movaps  xmm3, xmm2
    cmpltps xmm2, xmm0
    cmpltps xmm3, xmm1
    orps    xmm2, xmm3
    andps   xmm2, [rip+lf_ones]
    movaps  xmm0, xmm2
    jmp     .Lld_vec
.Lm_not:
    cmpltps xmm0, [rip+lf_halfs]
    andps   xmm0, [rip+lf_ones]
    jmp     .Lld_vec
.Lm_abs:
    andps   xmm0, [rip+lf_abs]
    jmp     .Lld_vec
.Lm_len:
    andps   xmm0, [rip+lf_xyz]
    dpps    xmm0, xmm0, 0x7f
    sqrtps  xmm0, xmm0
    jmp     .Lld_vec
.Lm_dist:
    subps   xmm0, xmm1
    andps   xmm0, [rip+lf_xyz]
    dpps    xmm0, xmm0, 0x7f
    sqrtps  xmm0, xmm0
    jmp     .Lld_vec
.Lm_scale:
    shufps  xmm1, xmm1, 0
    mulps   xmm0, xmm1
    jmp     .Lld_vec

.Lld_clean:                             # (NaN / infinity: 0)
    movaps  xmm1, xmm0
    cmpordps xmm1, xmm0
    andps   xmm0, xmm1
    jmp     .Lld_vec
.Lld_zero:
    xorps   xmm0, xmm0
    jmp     .Lld_out
.Lld_bcast:
    shufps  xmm0, xmm0, 0
.Lld_vec:
    andps   xmm0, [rip+lf_xyz]
.Lld_out:
    dec     dword ptr [rip+lg_depth]
.Lld_ret:
    add     rsp, 64
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.section .rodata
.align 8
lg_math_tab:    .quad .Lm_add, .Lm_sub, .Lm_mul, .Lm_div, .Lm_min, .Lm_max, .Lm_sin
                .quad .Lm_cos, .Lm_gt, .Lm_lt, .Lm_eq, .Lm_and, .Lm_or, .Lm_not
                .quad .Lm_abs, .Lm_len, .Lm_dist, .Lm_scale
.text

# =============================================================================
#  Overlaps
# =============================================================================
# lg_overlap(edi=overlap node) -> eax = 1 when the running object's box
#   (grown by the margin) meets the player's (no name) or the named object's
lg_overlap:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 32
    mov     ebx, edi
    call    lg_self
    test    rax, rax
    jz      8f
    test    dword ptr [rax+OB_FLAGS], OBF_HIDDEN
    jnz     8f
    mov     rdi, rax
    lea     rsi, [rip+lg_box]
    call    lg_obj_box
    mov     edi, ebx
    call    lg_node
    movss   xmm2, [rax+ND_P+8]          # the margin
    shufps  xmm2, xmm2, 0
    andps   xmm2, [rip+lf_xyz]
    movaps  xmm0, [rip+lg_box]
    subps   xmm0, xmm2
    movaps  [rip+lg_box], xmm0
    movaps  xmm0, [rip+lg_box+16]
    addps   xmm0, xmm2
    movaps  [rip+lg_box+16], xmm0
    mov     edi, ebx
    xor     esi, esi
    call    lg_vname
    test    rax, rax
    jnz     2f
    cmp     dword ptr [rip+pl_on], 1    # the player: the capsule's box
    jne     8f
    movss   xmm1, [rip+pl_radius]
    shufps  xmm1, xmm1, 0
    andps   xmm1, [rip+lf_xyz]
    movaps  xmm0, [rip+pl_pos]
    subps   xmm0, xmm1
    insertps xmm0, [rip+pl_pos+4], 0x10
    movaps  [rip+lg_box+32], xmm0
    movaps  xmm0, [rip+pl_pos]
    addps   xmm0, xmm1
    movss   xmm2, [rip+pl_pos+4]
    addss   xmm2, [rip+pl_height]
    insertps xmm0, xmm2, 0x10
    movaps  [rip+lg_box+48], xmm0
    jmp     3f
2:  mov     rdi, rax                    # an object
    call    obj_find
    test    eax, eax
    jz      8f
    mov     edi, eax
    call    obj_get
    test    rax, rax
    jz      8f
    test    dword ptr [rax+OB_FLAGS], OBF_HIDDEN
    jnz     8f
    mov     rdi, rax
    lea     rsi, [rip+lg_box+32]
    call    lg_obj_box
3:  movaps  xmm0, [rip+lg_box+16]       # max a < min b, or max b < min a
    cmpltps xmm0, [rip+lg_box+32]
    movaps  xmm1, [rip+lg_box+48]
    cmpltps xmm1, [rip+lg_box]
    orps    xmm0, xmm1
    andps   xmm0, [rip+lf_xyz]
    movmskps eax, xmm0
    test    eax, eax
    jnz     8f
    mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 32
    pop     r13
    pop     r12
    pop     rbx
    ret

# lg_obj_box(rdi=object, rsi=out: min, max (aligned)) - its mesh's box in
#   the world (a point at its place without a mesh)
lg_obj_box:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 64
    mov     rbx, rdi
    mov     r12, rsi
    mov     rdi, rbx
    call    obj_eval
    test    rax, rax
    jz      7f
    cmp     dword ptr [rax+ME_NTRIS], 0
    je      7f
    movups  xmm0, [rax+ME_BMIN]
    andps   xmm0, [rip+lf_xyz]
    movaps  [rsp], xmm0
    movups  xmm0, [rax+ME_BMAX]
    andps   xmm0, [rip+lf_xyz]
    movaps  [rsp+16], xmm0
    mov     rdi, rbx
    lea     rsi, [rip+lg_mat]
    call    obj_matrix
    movaps  xmm0, [rip+lf_big]
    movaps  [r12], xmm0
    movaps  xmm0, [rip+lf_nbig]
    movaps  [r12+16], xmm0
    xor     r13d, r13d
1:  cmp     r13d, 8
    jae     9f
    movaps  xmm0, [rsp]
    movaps  xmm3, [rsp+16]
    test    r13d, 1
    jz      11f
    insertps xmm0, xmm3, 0x00
11: test    r13d, 2
    jz      12f
    insertps xmm0, xmm3, 0x50
12: test    r13d, 4
    jz      13f
    insertps xmm0, xmm3, 0xa0
13: insertps xmm0, [rip+lf_one], 0x30
    movaps  xmm1, xmm0
    dpps    xmm1, [rip+lg_mat], 0xf1
    movaps  xmm2, xmm0
    dpps    xmm2, [rip+lg_mat+16], 0xf2
    orps    xmm1, xmm2
    movaps  xmm2, xmm0
    dpps    xmm2, [rip+lg_mat+32], 0xf4
    orps    xmm1, xmm2
    movaps  xmm0, [r12]
    minps   xmm0, xmm1
    movaps  [r12], xmm0
    movaps  xmm0, [r12+16]
    maxps   xmm0, xmm1
    movaps  [r12+16], xmm0
    inc     r13d
    jmp     1b
7:  movups  xmm0, [rbx+OB_LOC]
    andps   xmm0, [rip+lf_xyz]
    movaps  [r12], xmm0
    movaps  [r12+16], xmm0
9:  add     rsp, 64
    pop     r13
    pop     r12
    pop     rbx
    ret

.section .note.GNU-stack,"",@progbits
