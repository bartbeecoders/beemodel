# =============================================================================
#  BeeModel - modeling and CAD without the console: Add > Sketch, the feature
#  dialogs (pad, pocket, revolve, hole, shell, fillet, chamfer, pattern,
#  infill), the generators (L-system, wave function collapse) and the CAD
#  tab of the Properties editor (parameters, units, kernel, the feature
#  tree, mechanism joints, measuring).
#
#  The CAD features are BeeScript functions, so these operators are script
#  templates: the argument's words (a form's values; "quoted words" keep
#  their spaces) fill %1 .. %9, %a is the active object's name and %,n adds
#  ", word n" unless it is empty or 0 (%"n quotes it). One undo step.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"
.include "widgets.inc"
.include "icons.inc"

.globl cadui_props
.globl cad_script

.equ SRC_CAP,   1024
.equ MAXTOK,    9
.equ MAXF,      64                      # features shown
.equ MAXP,      64                      # parameters shown
.equ MAXJ,      32                      # joints shown
.equ FT_SZ,     128                     # (feature.s)
.equ FT_TYPE,   0
.equ FT_BODY,   4
.equ FT_REF,    12
.equ FT_FLAGS,  16
.equ FT_X,      32
.equ FF_OFF,    8
.equ PR_NAME,   0                       # (cad.s)
.equ PR_EXPR,   24
.equ MJ_TYPE,   0                       # (mech.s)
.equ MJ_B,      8
.equ MJ_EXPR,   64

.section .bss
.align 8
cs_args:        .skip 256               # the argument, split
cs_tok:         .skip 8*MAXTOK
cs_src:         .skip SRC_CAP
cu_on:          .skip 4*MAXF            # the features' On toggles
fm_arg:         .skip 32                # cad.feature_move's argument
cu_fval:        .skip 32*MAXF           # a number value as text
cu_arg:         .skip 160
cu_units:       .skip 4
cu_kernel:      .skip 4
cu_mass:        .skip 128               # the last mass properties
cu_mass_uid:    .skip 4

.section .rodata
s_fm_usage:     .asciz "  cad.feature_move <number> up|down"

s_up:           .asciz "up"
s_down:         .asciz "down"

s_empty:        .asciz ""
s_need_active:  .asciz "  select an object first"
s_need_sketch:  .asciz "select a sketch first"
s_need_mesh:    .asciz "select a mesh (a part) first"
s_h_params:     .asciz "Parameters"
s_h_feats:      .asciz "Features"
s_h_mech:       .asciz "Mechanism"
s_h_measure:    .asciz "Measure"
s_eq:           .asciz "= "
s_units:        .asciz "Scene units"
s_dot:          .asciz "  "
s_no_params:    .asciz "Parameters are named values (with units) that dimensions use."
s_no_feats:     .asciz "Make a sketch (Add > Sketch), then Pad it into a part."
s_no_joints:    .asciz "Joints make parts move: a revolute turns, a slider slides."
s_dist:         .asciz "Distance "
s_angle:        .asciz "Angle "
s_deg:          .asciz " deg"
s_rev:          .asciz "Revolute "
s_slide:        .asciz "Slider "
s_value:        .asciz " value "
s_sp:           .asciz " "
f_r2d:          .float 57.29578
.align 4
unit_mm:        .float 1.0, 10.0, 1000.0, 25.4

# the script templates (operator args)
t_sketch:       .asciz "select(sketch(\"%1\", \"%2\", %3))"
t_pad:          .asciz "_ = pad(\"%1\", \"%a\", \"%2\", \"%3\")\nselect(\"%1\")"
t_pocket:       .asciz "_ = pocket(\"%1\", \"%a\", \"%2\", \"%3\")\nselect(\"%1\")"
t_revolve:      .asciz "_ = revolve(\"%1\", \"%a\", \"%2\", \"%3\")\nselect(\"%1\")"
t_hole:         .asciz "_ = hole(\"%1\", \"%a\", \"%2\"%\"3)\nselect(\"%1\")"
t_shell:        .asciz "_ = shell(\"%a\", %1, \"%2\", \"%3\")"
t_fillet:       .asciz "_ = fillet(\"%a\", \"%1\", \"%2\")"
t_chamfer:      .asciz "_ = chamfer(\"%a\", \"%1\", \"%2\")"
t_pattern:      .asciz "_ = pattern(\"%a\", %1, %2, \"%3\", \"%4\", \"%5\")"
t_infill:       .asciz "_ = infill(\"%a\", %1, \"%2\", \"%3\", \"%4\")"
t_lsystem:      .asciz "select(lsystem(\"%1\", \"%2\", \"%3\", %4, %5, %6%,7))"
t_wfc:          .asciz "_ = wfc(\"%1\", %2, %3, %4, %5, \"%6\")"
t_feat_val:     .asciz "_ = feature(%1, 0, \"%2\")"
t_feat_off:     .asciz "_ = feature(%1, 3, %2)"

# ---- the operators ------------------------------------------------------------------
.text
OPERATOR op_cad_sketch, "cad.sketch", "Sketch...", do_cad_sketch, arg=t_sketch, flags=OPF_AI_SAFE, form=form_sketch, doc="A new sketch on a plane, ready to draw on (sketch mode): cad.sketch <name> <XY|XZ|YZ> <offset>"
OPERATOR op_cad_pad, "cad.pad", "Pad...", cad_script, arg=t_pad, flags=OPF_AI_SAFE|OPF_OBJECT, poll=poll_sketch, form=form_pad, doc="Extrude the active sketch's closed profiles into a part: cad.pad <body> <distance> <normal|symmetric|reverse>"
OPERATOR op_cad_pocket, "cad.pocket", "Pocket...", cad_script, arg=t_pocket, flags=OPF_AI_SAFE|OPF_OBJECT, poll=poll_sketch, form=form_pocket, doc="Cut the active sketch's profiles into a part: cad.pocket <body> <depth> <normal|through|symmetric|reverse>"
OPERATOR op_cad_revolve, "cad.revolve", "Revolve...", cad_script, arg=t_revolve, flags=OPF_AI_SAFE|OPF_OBJECT, poll=poll_sketch, form=form_revolve, doc="Turn the active sketch's profiles about its u or v axis into a part: cad.revolve <body> <degrees> <u|v>"
OPERATOR op_cad_hole, "cad.hole", "Hole...", cad_script, arg=t_hole, flags=OPF_AI_SAFE|OPF_OBJECT, poll=poll_sketch, form=form_hole, doc="Drill a hole at every loose point of the active sketch: cad.hole <body> <diameter> [depth] (no depth or 0: through)"
OPERATOR op_cad_shell, "cad.shell", "Shell...", cad_script, arg=t_shell, flags=OPF_AI_SAFE|OPF_OBJECT, poll=poll_part, form=form_shell, doc="Hollow a pad of the active part: cad.shell <pad feature> <wall> <normal|bottom> (open at the top or the bottom)"
OPERATOR op_cad_fillet, "cad.fillet", "Fillet...", cad_script, arg=t_fillet, flags=OPF_AI_SAFE|OPF_OBJECT, poll=poll_part, form=form_fillet, doc="Round the active part's sharp edges: cad.fillet <radius> <all|vertical|horizontal|top|bottom>"
OPERATOR op_cad_chamfer, "cad.chamfer", "Chamfer...", cad_script, arg=t_chamfer, flags=OPF_AI_SAFE|OPF_OBJECT, poll=poll_part, form=form_chamfer, doc="Bevel the active part's sharp edges: cad.chamfer <size> <all|vertical|horizontal|top|bottom>"
OPERATOR op_cad_pattern, "cad.pattern", "Pattern...", cad_script, arg=t_pattern, flags=OPF_AI_SAFE|OPF_OBJECT, poll=poll_part, form=form_pattern, doc="Repeat a feature of the active part: cad.pattern <feature> <count> <step or angle> <x|y|z> <linear|circular>"
OPERATOR op_cad_infill, "cad.infill", "Infill...", cad_script, arg=t_infill, flags=OPF_AI_SAFE|OPF_OBJECT, poll=poll_part, form=form_infill, doc="Fill a shell's cavity of the active part with a lattice: cad.infill <shell feature> <gyroid|grid> <cell> <wall>"
OPERATOR op_gen_lsystem, "add.lsystem", "L-system...", cad_script, arg=t_lsystem, flags=OPF_AI_SAFE|OPF_OBJECT, form=form_lsystem, doc="A plant or fractal drawn by an L-system: add.lsystem <name> <axiom> \"<rules>\" <iterations> <angle> <step> [radius] (no radius: lines)"
OPERATOR op_gen_wfc, "add.wfc", "Wave Function Collapse...", cad_script, arg=t_wfc, flags=OPF_AI_SAFE|OPF_OBJECT, form=form_wfc, doc="Arrange tile objects on a grid so that neighbours fit: add.wfc <name> <nx> <nz> <layers> <seed> \"<tile names>\""

# poll_sketch / poll_part -> rax = 0 or why not
poll_sketch:
    sub     rsp, 8
    call    active_type
    add     rsp, 8
    cmp     eax, OT_SKETCH
    jne     1f
    xor     eax, eax
    ret
1:  lea     rax, [rip+s_need_sketch]
    ret
poll_part:
    sub     rsp, 8
    call    active_type
    add     rsp, 8
    cmp     eax, OT_MESH
    jne     1f
    xor     eax, eax
    ret
1:  lea     rax, [rip+s_need_mesh]
    ret
active_type:                            # -> eax = the active object's type, -1
    mov     edi, [rip+active_obj]
    test    edi, edi
    jz      1f
    sub     rsp, 8
    call    obj_get
    add     rsp, 8
    test    rax, rax
    jz      1f
    mov     eax, [rax+OB_TYPE]
    ret
1:  mov     eax, -1
    ret

# do_cad_sketch(rdi=template) - the sketch, then sketch mode on it
do_cad_sketch:
    sub     rsp, 8
    call    cad_script
    test    eax, eax
    jnz     9f
    call    active_type
    cmp     eax, OT_SKETCH
    jne     9f
    cmp     dword ptr [rip+skm_obj], 0
    jne     9f
    call    skm_toggle
9:  add     rsp, 8
    ret

# cad_script(rdi=template) -> eax = 0 ok, 1 failed: fills it from op_arg and
#   runs it (one undo step)
cad_script:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     rbx, rdi
    call    split_args
    lea     r12, [rip+cs_src]           # out
    lea     r14, [rip+cs_src+SRC_CAP-80]
.Lcs_ch:
    cmp     r12, r14
    jae     .Lcs_run
    mov     al, [rbx]
    test    al, al
    jz      .Lcs_run
    inc     rbx
    cmp     al, '%'
    je      .Lcs_pct
    mov     [r12], al
    inc     r12
    jmp     .Lcs_ch
.Lcs_pct:
    mov     al, [rbx]
    inc     rbx
    cmp     al, 'a'
    je      .Lcs_active
    cmp     al, ','
    je      .Lcs_opt
    cmp     al, '"'
    je      .Lcs_opt
    sub     al, '1'
    movzx   eax, al
    call    tok_at
    mov     rsi, rax
    call    put_s
    jmp     .Lcs_ch
.Lcs_opt:                               # ", word" unless empty or 0
    mov     al, [rbx]
    inc     rbx
    sub     al, '1'
    movzx   eax, al
    call    tok_at
    mov     r13, rax
    cmp     byte ptr [r13], 0
    je      .Lcs_ch
    cmp     word ptr [r13], '0'
    je      .Lcs_ch
    mov     word ptr [r12], 0x202c      # ", "
    add     r12, 2
    cmp     byte ptr [rbx-2], '"'       # %"n: quoted
    jne     1f
    mov     byte ptr [r12], '"'
    inc     r12
1:  mov     rsi, r13
    call    put_s
    cmp     byte ptr [rbx-2], '"'
    jne     .Lcs_ch
    mov     byte ptr [r12], '"'
    inc     r12
    jmp     .Lcs_ch
.Lcs_active:
    mov     edi, [rip+active_obj]
    test    edi, edi
    jz      .Lcs_noact
    call    obj_get
    test    rax, rax
    jz      .Lcs_noact
    mov     rsi, rax                    # (OB_NAME)
    call    put_s
    jmp     .Lcs_ch
.Lcs_noact:
    lea     rdi, [rip+s_need_active]
    call    log_line
    mov     eax, 1
    jmp     .Lcs_ret
.Lcs_run:
    mov     byte ptr [r12], 0
    lea     rdi, [rip+cs_src]
    xor     esi, esi
    call    script_eval
.Lcs_ret:
    add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

put_s:                                  # rsi = text -> at r12 (to r14)
1:  cmp     r12, r14
    jae     2f
    mov     al, [rsi]
    test    al, al
    jz      2f
    mov     [r12], al
    inc     rsi
    inc     r12
    jmp     1b
2:  ret

tok_at:                                 # eax = index -> rax = the word or ""
    cmp     eax, MAXTOK
    jae     1f
    lea     rcx, [rip+cs_tok]
    mov     rax, [rcx+rax*8]
    test    rax, rax
    jz      1f
    ret
1:  lea     rax, [rip+s_empty]
    ret

# split_args - op_arg's words into cs_tok ("quoted words" are one)
split_args:
    lea     rdi, [rip+cs_tok]
    xor     eax, eax
    mov     ecx, MAXTOK
    rep     stosq
    mov     rsi, [rip+op_arg]
    test    rsi, rsi
    jz      9f
    lea     rdi, [rip+cs_args]
    lea     r8, [rip+cs_args+255]
    xor     edx, edx                    # words
1:  mov     al, [rsi]                   # skip spaces
    test    al, al
    jz      9f
    cmp     al, ' '
    jne     2f
    inc     rsi
    jmp     1b
2:  cmp     edx, MAXTOK
    jae     9f
    lea     rcx, [rip+cs_tok]
    mov     [rcx+rdx*8], rdi
    inc     edx
    mov     ah, ' '                     # the word's end
    cmp     al, '"'
    jne     3f
    mov     ah, '"'
    inc     rsi
3:  mov     al, [rsi]
    test    al, al
    jz      5f
    inc     rsi
    cmp     al, ah
    je      5f
    cmp     rdi, r8
    jae     3b
    mov     [rdi], al
    inc     rdi
    jmp     3b
5:  cmp     rdi, r8
    jae     9f
    mov     byte ptr [rdi], 0
    inc     rdi
    test    al, al
    jnz     1b
9:  ret

# =============================================================================
#  The CAD tab
# =============================================================================
WIDGET wd_cp_expr, WK_TEXT, "cad.param", flags=WGF_COMPACT, cb=param_cb, tip="The parameter's expression: a number with units, other parameters, + - * / ( ) (Enter)"
WIDGET wd_cp_del, WK_BUTTON, "cad.param.remove", flags=WGF_ICON|WGF_COMPACT, n=ICON_CLOSE, tip="Remove this parameter"
WIDGET wd_cp_add, WK_BUTTON, "cad.param.add", "Add Parameter...", aux=op_param_set
WIDGET wd_cp_units, WK_ENUM, "cad.units", cb=units_cb, aux=unit_lbl, n=4, tip="What one scene unit is (typed lengths with units convert)"
WIDGET wd_cp_kernel, WK_TOGGLE, "cad.kernel", "Exact B-rep solids", cb=kernel_cb, tip="Features make exact NURBS solids (STEP export) instead of meshes"
WIDGET wd_cf_val, WK_TEXT, "cad.feature.value", flags=WGF_COMPACT, cb=feat_val_cb, tip="The feature's size: distance, depth, diameter, wall, radius or step - a number or an expression (Enter)"
WIDGET wd_cf_up, WK_BUTTON, "cad.feature.up", flags=WGF_ICON|WGF_COMPACT, n=ICON_CHEVRON_UP, tip="Move the feature up: it runs earlier when the part rebuilds"
WIDGET wd_cf_down, WK_BUTTON, "cad.feature.down", flags=WGF_ICON|WGF_COMPACT, n=ICON_CHEVRON_DOWN, tip="Move the feature down: it runs later when the part rebuilds"
OPERATOR op_feat_move, "cad.feature_move", "Move Feature", do_feat_move, flags=OPF_AI_SAFE|OPF_UNDO, doc="Move a feature in the tree: cad.feature_move <number> up|down (the part rebuilds; a feature that needs a later one is marked)"
WIDGET wd_cf_on, WK_TOGGLE, "cad.feature.on", "On", flags=WGF_COMPACT, cb=feat_on_cb, tip="Suppress the feature (it is skipped when the part rebuilds)"
WIDGET wd_cf_pad, WK_BUTTON, "cad.add.pad", "Pad", aux=op_cad_pad
WIDGET wd_cf_pocket, WK_BUTTON, "cad.add.pocket", "Pocket", aux=op_cad_pocket
WIDGET wd_cf_revolve, WK_BUTTON, "cad.add.revolve", "Revolve", aux=op_cad_revolve
WIDGET wd_cf_hole, WK_BUTTON, "cad.add.hole", "Hole", aux=op_cad_hole
WIDGET wd_cf_shell, WK_BUTTON, "cad.add.shell", "Shell", aux=op_cad_shell
WIDGET wd_cf_fillet, WK_BUTTON, "cad.add.fillet", "Fillet", aux=op_cad_fillet
WIDGET wd_cf_chamfer, WK_BUTTON, "cad.add.chamfer", "Chamfer", aux=op_cad_chamfer
WIDGET wd_cf_pattern, WK_BUTTON, "cad.add.pattern", "Pattern", aux=op_cad_pattern
WIDGET wd_cf_infill, WK_BUTTON, "cad.add.infill", "Infill", aux=op_cad_infill
WIDGET wd_cf_sketch, WK_BUTTON, "cad.add.sketch", "New Sketch...", flags=WGF_PRIMARY, aux=op_cad_sketch
WIDGET wd_cj_expr, WK_TEXT, "cad.joint.value", flags=WGF_COMPACT, cb=joint_cb, tip="The joint's value: an angle or a distance, an expression of parameters and the frame (Enter)"
WIDGET wd_cj_add, WK_BUTTON, "cad.joint.add", "Add Joint...", aux=op_mj_add
WIDGET wd_cm_tool, WK_BUTTON, "cad.measure", "Measure Tool", aux=op_view_measure
WIDGET wd_cm_mass, WK_BUTTON, "cad.mass", "Mass Properties", tip="Volume, area, mass and centre of mass of the active part"

.section .rodata
.align 8
add_btns:       .quad wd_cf_pad, wd_cf_pocket, wd_cf_revolve, wd_cf_hole, wd_cf_shell
                .quad wd_cf_fillet, wd_cf_chamfer, wd_cf_pattern, wd_cf_infill, 0
.text

# cadui_props(edi=y) -> eax = y below it (r12d is the page's y)
cadui_props:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r12d, edi
    call    pnl_begin

    # ---- parameters ----
    lea     rdx, [rip+s_h_params]
    call    pnl_heading
    call    param_count
    test    eax, eax
    jnz     1f
    lea     rdx, [rip+s_no_params]
    call    pnl_hint
1:  xor     ebx, ebx
.Lcu_prow:
    call    param_count
    cmp     ebx, eax
    jae     .Lcu_pend
    cmp     ebx, MAXP
    jae     .Lcu_pend
    mov     edi, ebx
    call    param_rec
    mov     r13, rax
    mov     edi, [rip+pnl_x]             # name
    lea     esi, [r12+3]
    lea     rdx, [r13+PR_NAME]
    mov     ecx, COL_TEXT
    call    draw_small
    mov     eax, [rip+pnl_w]             # the expression: 28% .. 62%
    imul    eax, eax, 28
    cdq
    mov     ecx, 100
    idiv    ecx
    mov     r14d, eax                   # (its x offset)
    lea     rdi, [rip+wd_cp_expr]
    mov     esi, [rip+pnl_x]
    add     esi, r14d
    mov     ecx, [rip+pnl_w]
    imul    ecx, ecx, 34
    mov     eax, ecx
    cdq
    mov     ecx, 100
    idiv    ecx
    mov     ecx, eax
    mov     edx, r12d
    lea     r8, [r13+PR_EXPR]
    mov     r9d, ebx
    call    wg
    call    fmt_reset                   # "= value"
    lea     rdi, [rip+s_eq]
    call    fmt_str
    mov     edi, ebx
    call    param_value
    cvtsd2ss xmm0, xmm0
    call    fmt_val3
    mov     edi, [rip+pnl_x]             # (right-aligned before the x)
    add     edi, [rip+pnl_w]
    sub     edi, 22
    lea     esi, [r12+3]
    lea     rdx, [rip+fmt_buf]
    mov     ecx, COL_TEXT_DIM
    call    pnl_draw_right
    lea     rdi, [rip+wd_cp_del]        # remove
    mov     esi, [rip+pnl_x]
    add     esi, [rip+pnl_w]
    sub     esi, 18
    mov     edx, r12d
    mov     ecx, 18
    xor     r8d, r8d
    mov     r9d, ebx
    call    wg
    test    eax, eax
    jz      2f
    lea     rsi, [r13+PR_NAME]
    lea     rdi, [rip+op_param_remove]
    call    run_arg
    jmp     .Lcu_pend                   # (the list changed)
2:  add     r12d, 22
    inc     ebx
    jmp     .Lcu_prow
.Lcu_pend:
    add     r12d, 4
    lea     rdi, [rip+wd_cp_add]
    xor     r8d, r8d
    call    pnl_full
    mov     edi, [rip+pnl_x]
    lea     esi, [r12+4]
    lea     rdx, [rip+s_units]
    mov     ecx, COL_TEXT_DIM
    call    draw_small
    call    cad_unit_mm                 # units
    cvtsd2ss xmm0, xmm0
    xor     ecx, ecx
    lea     rax, [rip+unit_mm]
3:  cmp     ecx, 3
    jae     4f
    ucomiss xmm0, [rax+rcx*4]
    je      4f
    inc     ecx
    jmp     3b
4:  mov     [rip+cu_units], ecx
    lea     rdi, [rip+wd_cp_units]
    lea     r8, [rip+cu_units]
    call    pnl_right
    add     r12d, WG_H+4
    call    cad_kernel
    mov     [rip+cu_kernel], eax
    lea     rdi, [rip+wd_cp_kernel]
    lea     r8, [rip+cu_kernel]
    call    pnl_full

    # ---- features ----
    add     r12d, 8
    lea     rdx, [rip+s_h_feats]
    call    pnl_heading
    call    feat_count
    test    eax, eax
    jnz     1f
    lea     rdx, [rip+s_no_feats]
    call    pnl_hint
1:  xor     ebx, ebx
.Lcu_frow:
    call    feat_count
    cmp     ebx, eax
    jae     .Lcu_fend
    cmp     ebx, MAXF
    jae     .Lcu_fend
    mov     edi, ebx
    call    feat_rec
    mov     r13, rax
    mov     edi, ebx                    # health: a dot
    call    feat_status
    mov     r15d, eax
    mov     r8d, COL_OK
    test    eax, eax
    jz      2f
    mov     r8d, COL_TEXT_OFF
    cmp     eax, 7                      # (S_OFF: suppressed)
    je      2f
    mov     r8d, COL_REC
2:  mov     edi, [rip+pnl_x]
    add     edi, 4
    lea     esi, [r12+9]
    mov     edx, 4
    call    fill_circle
    call    fmt_reset                   # "0 Pad  Body"
    mov     edi, ebx
    call    fmt_int
    mov     edi, ' '
    call    fmt_char
    mov     edi, [r13+FT_TYPE]
    call    feat_type_name
    mov     rdi, rax
    call    fmt_str
    lea     rdi, [rip+s_dot]
    call    fmt_str
    mov     edi, [r13+FT_BODY]
    call    obj_by_uid
    test    rax, rax
    jz      3f
    mov     rdi, rax
    call    fmt_str
3:  mov     edi, [rip+pnl_x]
    add     edi, 14
    lea     esi, [r12+3]
    lea     rdx, [rip+fmt_buf]
    mov     ecx, COL_TEXT
    test    r15d, r15d
    jz      31f
    mov     ecx, COL_TEXT_DIM
31: call    draw_small
    lea     r14, [r13+FT_X]             # the value: its text or the number
    cmp     byte ptr [r14], 1
    jne     4f
    movsd   xmm0, [r14+8]
    cvtsd2ss xmm0, xmm0
    mov     eax, ebx
    shl     eax, 5
    lea     rsi, [rip+cu_fval]
    add     rsi, rax
    mov     r14, rsi
    mov     edi, 3
    call    wg_ftoa
    mov     byte ptr [rax], 0
4:  lea     rdi, [rip+wd_cf_up]         # up / down, left of the value
    mov     esi, [rip+pnl_w]
    shr     esi, 1
    add     esi, [rip+pnl_x]
    sub     esi, 42
    mov     edx, r12d
    mov     ecx, 18
    xor     r8d, r8d
    mov     r9d, ebx
    call    wg
    test    eax, eax
    jz      41f
    lea     rdi, [rip+s_up]
    jmp     43f
41: lea     rdi, [rip+wd_cf_down]
    mov     esi, [rip+pnl_w]
    shr     esi, 1
    add     esi, [rip+pnl_x]
    sub     esi, 22
    mov     edx, r12d
    mov     ecx, 18
    xor     r8d, r8d
    mov     r9d, ebx
    call    wg
    test    eax, eax
    jz      44f
    lea     rdi, [rip+s_down]
43: push    rdi                         # cad.feature_move <n> up|down
    push    rdi
    call    fmt_reset
    mov     edi, ebx
    call    fmt_int
    mov     edi, ' '
    call    fmt_char
    pop     rdi
    pop     rdi
    call    fmt_str
    lea     rdi, [rip+fm_arg]           # (its own copy: running logs via fmt)
    lea     rsi, [rip+fmt_buf]
    mov     ecx, 32
    rep     movsb
    lea     rsi, [rip+fm_arg]
    lea     rdi, [rip+op_feat_move]
    call    run_arg
    jmp     .Lcu_fend                   # (the list changed)
44: lea     rdi, [rip+wd_cf_val]
    mov     esi, [rip+pnl_w]             # 50% .. 80%
    shr     esi, 1
    add     esi, [rip+pnl_x]
    mov     ecx, [rip+pnl_w]
    imul    ecx, ecx, 3
    mov     eax, ecx
    cdq
    mov     ecx, 10
    idiv    ecx
    mov     ecx, eax
    mov     edx, r12d
    mov     r8, r14
    mov     r9d, ebx
    call    wg
    lea     rax, [rip+cu_on]            # On
    xor     ecx, ecx
    test    dword ptr [r13+FT_FLAGS], FF_OFF
    sete    cl
    mov     [rax+rbx*4], ecx
    lea     r8, [rax+rbx*4]
    lea     rdi, [rip+wd_cf_on]
    mov     eax, [rip+pnl_w]
    imul    eax, eax, 4
    cdq
    mov     ecx, 5
    idiv    ecx
    lea     esi, [rax+6]
    add     esi, [rip+pnl_x]
    mov     edx, r12d
    mov     ecx, [rip+pnl_w]
    sub     ecx, eax
    sub     ecx, 6
    mov     r9d, ebx
    call    wg
    add     r12d, 22
    test    r15d, r15d                  # what is wrong, under it
    jz      5f
    cmp     r15d, 7
    je      5f
    mov     edi, r15d
    call    feat_status_name
    mov     rdx, rax
    mov     edi, [rip+pnl_x]
    add     edi, 14
    mov     esi, r12d
    mov     ecx, COL_REC
    call    draw_small
    add     r12d, 16
5:  inc     ebx
    jmp     .Lcu_frow
.Lcu_fend:
    add     r12d, 4
    lea     rdi, [rip+wd_cf_sketch]
    xor     r8d, r8d
    call    pnl_full
    lea     r15, [rip+add_btns]         # the features, three to a row
    xor     ebx, ebx
6:  mov     rdi, [r15+rbx*8]
    test    rdi, rdi
    jz      8f
    mov     eax, [rip+pnl_w]
    add     eax, 4
    xor     edx, edx
    mov     ecx, 3
    div     ecx
    mov     r13d, eax                   # (a column)
    mov     eax, ebx
    xor     edx, edx
    mov     ecx, 3
    div     ecx
    imul    edx, r13d
    mov     esi, [rip+pnl_x]
    add     esi, edx
    mov     ecx, r13d
    sub     ecx, 4
    push    rax
    push    rax
    mov     edx, r12d
    xor     r8d, r8d
    xor     r9d, r9d
    call    wg
    pop     rax
    pop     rax
    inc     ebx
    mov     eax, ebx
    xor     edx, edx
    mov     ecx, 3
    div     ecx
    test    edx, edx
    jnz     6b
    add     r12d, WG_H+4
    jmp     6b
8:  mov     eax, ebx                    # (a part row left over)
    xor     edx, edx
    mov     ecx, 3
    div     ecx
    test    edx, edx
    jz      9f
    add     r12d, WG_H+4

    # ---- mechanism ----
9:  add     r12d, 8
    lea     rdx, [rip+s_h_mech]
    call    pnl_heading
    call    joint_count
    test    eax, eax
    jnz     1f
    lea     rdx, [rip+s_no_joints]
    call    pnl_hint
1:  xor     ebx, ebx
.Lcu_jrow:
    call    joint_count
    cmp     ebx, eax
    jae     .Lcu_jend
    mov     rax, [rip+an_cur]
    imul    r13, rbx, MJ_SZ_
    lea     r13, [rax+AN_MJ_+r13]
    call    fmt_reset                   # "1 Revolute Part"
    lea     edi, [rbx+1]
    call    fmt_int
    lea     rdi, [rip+s_sp]
    call    fmt_str
    lea     rdi, [rip+s_rev]
    cmp     dword ptr [r13+MJ_TYPE], 1
    je      2f
    lea     rdi, [rip+s_slide]
2:  call    fmt_str
    mov     edi, [r13+MJ_B]
    call    obj_by_uid
    test    rax, rax
    jz      3f
    mov     rdi, rax
    call    fmt_str
3:  mov     edi, [rip+pnl_x]
    lea     esi, [r12+3]
    lea     rdx, [rip+fmt_buf]
    mov     ecx, COL_TEXT
    call    draw_small
    call    fmt_reset                   # its value now, at the right
    mov     edi, ebx
    call    mech_value
    cmp     dword ptr [r13+MJ_TYPE], 1
    jne     4f
    mulss   xmm0, [rip+f_r2d]
    call    fmt_val3
    lea     rdi, [rip+s_deg]
    call    fmt_str
    jmp     5f
4:  call    fmt_val3
5:  mov     edi, [rip+pnl_x]
    add     edi, [rip+pnl_w]
    lea     esi, [r12+3]
    lea     rdx, [rip+fmt_buf]
    mov     ecx, COL_TEXT_DIM
    call    pnl_draw_right
    add     r12d, 20                    # the expression under it
    lea     rdi, [rip+wd_cj_expr]
    mov     esi, [rip+pnl_x]
    add     esi, 14
    mov     ecx, [rip+pnl_w]
    sub     ecx, 14
    mov     edx, r12d
    lea     r8, [r13+MJ_EXPR]
    mov     r9d, ebx
    call    wg
    add     r12d, 22
    inc     ebx
    cmp     ebx, MAXJ
    jb      .Lcu_jrow
.Lcu_jend:
    add     r12d, 4
    lea     rdi, [rip+wd_cj_add]
    xor     r8d, r8d
    call    pnl_full

    # ---- measure ----
    add     r12d, 8
    lea     rdx, [rip+s_h_measure]
    call    pnl_heading
    lea     rdi, [rip+wd_cm_tool]
    xor     r8d, r8d
    call    pnl_full
    lea     rdi, [rip+wd_cm_mass]
    xor     r8d, r8d
    call    pnl_full
    test    eax, eax
    jz      1f
    call    mass_now
1:
    call    measure_value               # the measure tool's result
    test    eax, eax
    jz      3f
    mov     ebx, eax
    call    fmt_reset
    cmp     ebx, 1
    jne     2f
    lea     rdi, [rip+s_dist]
    movsd   [rsp-16], xmm0
    sub     rsp, 16
    call    fmt_str
    movsd   xmm0, [rsp]
    add     rsp, 16
    call    fmt_len
    jmp     21f
2:  lea     rdi, [rip+s_angle]
    cvtsd2ss xmm0, xmm0
    mulss   xmm0, [rip+f_r2d]
    movss   [rsp-16], xmm0
    sub     rsp, 16
    call    fmt_str
    movss   xmm0, [rsp]
    add     rsp, 16
    call    fmt_val3
    lea     rdi, [rip+s_deg]
    call    fmt_str
21: lea     rdx, [rip+fmt_buf]
    call    pnl_text
3:  mov     edi, [rip+active_obj]       # the active part's mass properties
    test    edi, edi
    jz      4f
    call    obj_get
    test    rax, rax
    jz      4f
    mov     eax, [rax+OB_UID]
    cmp     eax, [rip+cu_mass_uid]
    jne     4f
    lea     rbx, [rip+cu_mass]          # a line per ", " part
41: mov     rdx, rbx
42: mov     al, [rbx]
    test    al, al
    jz      43f
    inc     rbx
    cmp     al, ','
    jne     42b
    cmp     byte ptr [rbx], ' '
    jne     42b
    mov     byte ptr [rbx-1], 0
    push    rbx
    push    rbx
    call    pnl_text
    pop     rbx
    pop     rbx
    mov     byte ptr [rbx-1], ','
    inc     rbx
    jmp     41b
43: call    pnl_text
4:  mov     eax, r12d
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

joint_count:                            # -> eax
    mov     rax, [rip+an_cur]
    test    rax, rax
    jz      1f
    mov     eax, [rax+AN_NMJ_]
    ret
1:  xor     eax, eax
    ret

# mass_now - the active part's mass properties into cu_mass
mass_now:
    push    rbx
    mov     edi, [rip+active_obj]
    test    edi, edi
    jz      9f
    call    obj_get
    test    rax, rax
    jz      9f
    mov     rbx, rax
    mov     rdi, rax
    call    mass_props
    test    eax, eax
    jz      9f
    mov     rdi, rbx
    call    fmt_props
    lea     rsi, [rip+fmt_buf]
    lea     rdi, [rip+cu_mass]
    mov     ecx, 127
1:  mov     al, [rsi]
    mov     [rdi], al
    test    al, al
    jz      2f
    inc     rsi
    inc     rdi
    dec     ecx
    jnz     1b
    mov     byte ptr [rdi], 0
2:  mov     eax, [rbx+OB_UID]
    mov     [rip+cu_mass_uid], eax
9:  pop     rbx
    ret

# ---- callbacks ----------------------------------------------------------------------
# run_arg(rdi=op, rsi=argument) - run it with that argument
run_arg:
    push    qword ptr [rip+op_arg]
    mov     [rip+op_arg], rsi
    call    run_op
    pop     qword ptr [rip+op_arg]
    ret

# arg_begin / arg_str(rsi) / arg_int(edi) - build cu_arg (r8 = its end)
param_cb:                               # rdi = new text, esi = parameter
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    mov     edi, esi
    call    param_rec
    lea     r8, [rip+cu_arg]            # "name expression"
    lea     rsi, [rax+PR_NAME]
    call    arg_str
    lea     rsi, [rip+s_sp]
    call    arg_str
    mov     rsi, rbx
    call    arg_str
    lea     rdi, [rip+op_param_set]
    lea     rsi, [rip+cu_arg]
    call    run_arg
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

joint_cb:                               # rdi = new text, esi = joint
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    mov     r12d, esi
    call    fmt_reset                   # "n value expression"
    lea     edi, [r12+1]
    call    fmt_int
    lea     rdi, [rip+s_value]
    call    fmt_str
    lea     r8, [rip+cu_arg]
    lea     rsi, [rip+fmt_buf]
    call    arg_str
    mov     rsi, rbx
    call    arg_str
    lea     rdi, [rip+op_mj_set]
    lea     rsi, [rip+cu_arg]
    call    run_arg
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

feat_val_cb:                            # rdi = new text, esi = feature
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    mov     r12d, esi
    call    fmt_reset                   # "n \"text\""
    mov     edi, r12d
    call    fmt_int
    lea     r8, [rip+cu_arg]
    lea     rsi, [rip+fmt_buf]
    call    arg_str
    mov     word ptr [r8], 0x2220       # ' "'
    add     r8, 2
    mov     rsi, rbx
    call    arg_str
    mov     word ptr [r8], 0x22
    lea     rdi, [rip+t_feat_val]
    jmp     feat_run

feat_on_cb:                             # rdi = &on, esi = feature
    push    rbx
    push    r12
    sub     rsp, 8
    mov     ebx, [rdi]
    mov     r12d, esi
    call    fmt_reset                   # "n 0|1" (1: suppressed)
    mov     edi, r12d
    call    fmt_int
    mov     edi, ' '
    call    fmt_char
    mov     edi, 1
    sub     edi, ebx
    call    fmt_int
    lea     r8, [rip+cu_arg]
    lea     rsi, [rip+fmt_buf]
    call    arg_str
    lea     rdi, [rip+t_feat_off]
feat_run:                               # rdi = template, cu_arg its words
    push    qword ptr [rip+op_arg]
    lea     rax, [rip+cu_arg]
    mov     [rip+op_arg], rax
    sub     rsp, 8
    call    cad_script
    add     rsp, 8
    pop     qword ptr [rip+op_arg]
    mov     dword ptr [rip+dirty], 1
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

arg_str:                                # rsi = text -> at r8 (cu_arg, 0-ended)
    lea     rcx, [rip+cu_arg+158]
1:  cmp     r8, rcx
    jae     2f
    mov     al, [rsi]
    test    al, al
    jz      2f
    mov     [r8], al
    inc     rsi
    inc     r8
    jmp     1b
2:  mov     byte ptr [r8], 0
    ret

units_cb:                               # rdi = &cu_units -> scene.units
    mov     eax, [rdi]
    lea     rcx, [rip+unit_kw]
    mov     rsi, [rcx+rax*8]
    lea     rdi, [rip+op_scene_units]
    jmp     run_arg

kernel_cb:                              # rdi = &cu_kernel -> cad.kernel
    lea     rsi, [rip+s_on]
    cmp     dword ptr [rdi], 0
    jne     1f
    lea     rsi, [rip+s_off]
1:  lea     rdi, [rip+op_cad_kernel]
    jmp     run_arg

.section .rodata
s_on:           .asciz "on"
s_off:          .asciz "off"
s_mm:           .asciz "Millimetres"
s_cm:           .asciz "Centimetres"
s_m:            .asciz "Metres"
s_in:           .asciz "Inches"
k_mm:           .asciz "mm"
k_cm:           .asciz "cm"
k_m:            .asciz "m"
k_in:           .asciz "in"
.align 8
unit_lbl:       .quad s_mm, s_cm, s_m, s_in
unit_kw:        .quad k_mm, k_cm, k_m, k_in

.text
# cad.feature_move <n> up|down - the feature and its neighbour trade places;
#   features that refer to either (shell -> pad, patterns, infill -> shell)
#   keep referring to the same one; the parts rebuild
do_feat_move:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rsi, [rip+op_arg]
    call    im_next_word
    xor     ebx, ebx                    # the number
    lea     rcx, [rip+im_word]
    test    eax, eax
    jz      .Lfm_bad
1:  movzx   eax, byte ptr [rcx]
    test    eax, eax
    jz      2f
    sub     eax, '0'
    cmp     eax, 9
    ja      .Lfm_bad
    imul    ebx, ebx, 10
    add     ebx, eax
    inc     rcx
    jmp     1b
2:  push    rsi
    call    im_next_word
    pop     rsi
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+s_up]
    call    str_eq
    lea     r12d, [rbx-1]               # up: with the one before
    test    eax, eax
    jnz     3f
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+s_down]
    call    str_eq
    test    eax, eax
    jz      .Lfm_bad
    lea     r12d, [rbx+1]               # down: with the one after
3:  test    r12d, r12d
    js      .Lfm_none
    call    feat_count
    cmp     ebx, eax
    jae     .Lfm_none
    cmp     r12d, eax
    jae     .Lfm_none
    mov     r15d, eax
    call    cad_cow                     # (ours to change)
    mov     edi, ebx
    call    feat_rec
    mov     r13, rax
    mov     edi, r12d
    call    feat_rec
    mov     r14, rax
    xor     ecx, ecx                    # swap the two records
4:  mov     rax, [r13+rcx]
    mov     rdx, [r14+rcx]
    mov     [r13+rcx], rdx
    mov     [r14+rcx], rax
    add     ecx, 8
    cmp     ecx, FT_SZ
    jb      4b
    xor     ecx, ecx                    # references follow
5:  cmp     ecx, r15d
    jae     7f
    push    rcx
    mov     edi, ecx
    call    feat_rec
    pop     rcx
    mov     edx, [rax+FT_TYPE]
    cmp     edx, 5                      # shell, patterns, infill: by number
    je      51f
    cmp     edx, 8
    jb      6f
51: mov     edx, [rax+FT_REF]
    cmp     edx, ebx
    jne     52f
    mov     [rax+FT_REF], r12d
    jmp     6f
52: cmp     edx, r12d
    jne     6f
    mov     [rax+FT_REF], ebx
6:  inc     ecx
    jmp     5b
7:  call    feat_rebuild
    mov     dword ptr [rip+dirty], 1
    jmp     9f
.Lfm_none:
    call    undo_drop_last              # (nothing moved: no undo step)
    jmp     9f
.Lfm_bad:
    lea     rdi, [rip+s_fm_usage]
    call    log_line
    call    undo_drop_last
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.section .note.GNU-stack,"",@progbits
