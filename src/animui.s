# =============================================================================
#  BeeModel - animation and rigging without the console: the timeline's
#  transport and range in its header, the dope sheet / graph editor's key
#  menu, auto-key, I over a field keys that property, the Animation tab
#  (shape keys, actions and layers, drivers, onion skins, motion paths) and
#  the Rig tab (bones, the active bone's pose, constraints, parenting).
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"
.include "widgets.inc"
.include "icons.inc"

.globl an_autokey
.globl autokey_confirm
.globl tl_header_tools
.globl ae_header_tools
.globl field_key
.globl animui_props
.globl rigui_props

.equ AN_NACT,   36                      # (anim.s)
.equ AN_NLAY,   40
.equ AC_SZ,     48
.equ LY_SZ,     32
.equ LY_ACT,    0
.equ LY_TARGET, 4
.equ LY_INFL,   12
.equ LY_MUTE,   24
.equ DR_MUTE,   20                      # (rig.s)
.equ DR_EXPR,   120
.equ CN_OWNER,  0
.equ CN_BONE,   4
.equ CN_TYPE,   8
.equ CN_TARGET, 12
.equ CN_INFL,   32
.equ CN_FLAGS,  44
.equ CF_MUTE,   4
.equ SK_N,      0                       # (shape.s)
.equ SK_KEYS,   32
.equ SK_KSZ,    32
.equ SK_VAL,    24
.equ AR_N,      4                       # (arm.s)
.equ AR_ACT,    8
.equ AR_BONES,  64
.equ BN_SZ,     128
.equ BN_PARENT, 24
.equ BN_LOC,    60
.equ MAXROW,    32

.section .bss
.align 8
an_autokey:     .skip 4
tl_fr:          .skip 4                 # the header's frame, start, end, fps
tl_st:          .skip 4
tl_en:          .skip 4
tl_fps:         .skip 4
au_arg:         .skip 160
au_path:        .skip 96
au_vals:        .skip 4*MAXROW          # slider values (shape keys, layers,
au_tog:         .skip 4*MAXROW          #  constraints), toggles
au_tog2:        .skip 4*MAXROW
au_pose:        .skip 4*9
au_on:          .skip 4
au_ob:          .skip 8
au_uid:         .skip 4

.section .rodata
s_h_shapes:     .asciz "Shape Keys"
s_h_actions:    .asciz "Actions and Layers"
s_h_drivers:    .asciz "Drivers"
s_h_onion:      .asciz "Onion Skins and Motion Paths"
s_h_bones:      .asciz "Bones"
s_h_pose:       .asciz "Pose of "
s_h_cons:       .asciz "Constraints"
s_no_shapes:    .asciz "Shape keys store poses of the mesh to blend."
s_no_actions:   .asciz "Key some objects, then New Action keeps their keys."
s_no_drivers:   .asciz "A driver sets a value from an expression (anim.driver)."
s_no_cons:      .asciz "Constraints make an object follow, aim at or stay near another."
s_no_arm:       .asciz "Select an armature for its bones."
s_layer:        .asciz "Layer "
s_driver:       .asciz "Driver "
s_on:           .asciz " -> "
s_basis:        .asciz "Basis"
s_frames:       .asciz " frames "
s_dash:         .asciz " - "
s_sp:           .asciz " "
s_off:          .asciz "off"
s_remove:       .asciz " remove"
s_expr:         .asciz " expression "
s_infl:         .asciz " influence "
s_mute:         .asciz " mute "
s_loc:          .asciz " loc"
s_rot:          .asciz " rot"
s_scale:        .asciz " scale"
s_root:         .asciz "  (a root bone)"
s_parent:       .asciz "  parent: "
k_constant:     .asciz "constant"
k_linear:       .asciz "linear"
k_bezier:       .asciz "bezier"
k_auto:         .asciz "auto"
k_free:         .asciz "free"
ct_labels:      .quad 0, ctl_1, ctl_2, ctl_3, ctl_4, ctl_5, ctl_6, ctl_7, ctl_8, ctl_9
ctl_1:          .asciz "Copy Location"
ctl_2:          .asciz "Copy Rotation"
ctl_3:          .asciz "Copy Scale"
ctl_4:          .asciz "Track To"
ctl_5:          .asciz "Limit Location"
ctl_6:          .asciz "Limit Rotation"
ctl_7:          .asciz "Limit Scale"
ctl_8:          .asciz "Child Of"
ctl_9:          .asciz "IK"
xyz_names:      .asciz "x\0\0y\0\0z\0\0rx\0ry\0rz\0sx\0sy\0sz"
f_r2d:          .float 57.29578

# =============================================================================
#  Auto-key
# =============================================================================
.text
OPERATOR op_an_autokey, "anim.auto_key", "Auto-Key", do_autokey, check=chk_autokey, flags=OPF_AI_SAFE|OPF_QUIET, doc="Key what you move: after each move, turn or scale the selected objects get keys at the current frame (on / off)"
do_autokey:
    xor     dword ptr [rip+an_autokey], 1
    mov     dword ptr [rip+dirty], 1
    ret
chk_autokey:
    mov     eax, [rip+an_autokey]
    ret
# autokey_confirm - a transform was confirmed: key it when auto-key is on
autokey_confirm:
    cmp     dword ptr [rip+an_autokey], 0
    je      9f
    push    qword ptr [rip+op_arg]
    mov     qword ptr [rip+op_arg], 0
    lea     rdi, [rip+op_an_key]
    call    run_op
    pop     qword ptr [rip+op_arg]
9:  ret

# =============================================================================
#  The timeline's header: |< < play > >| frame, start, end, fps, auto-key
# =============================================================================
WIDGET wd_tl_first, WK_BUTTON, "timeline.first", flags=WGF_ICON, aux=op_an_first, n=ICON_FIRST
WIDGET wd_tl_prev,  WK_BUTTON, "timeline.prev", flags=WGF_ICON, aux=op_an_prev, n=ICON_PREV
WIDGET wd_tl_play,  WK_BUTTON, "timeline.play", flags=WGF_ICON, aux=op_an_play, n=ICON_PLAY
WIDGET wd_tl_pause, WK_BUTTON, "timeline.play", flags=WGF_ICON, aux=op_an_play, n=ICON_PAUSE
WIDGET wd_tl_next,  WK_BUTTON, "timeline.next", flags=WGF_ICON, aux=op_an_next, n=ICON_NEXT
WIDGET wd_tl_last,  WK_BUTTON, "timeline.last", flags=WGF_ICON, aux=op_an_last, n=ICON_LAST
WIDGET wd_tl_frame, WK_INT, "timeline.frame", "Frame", -100000.0, 100000.0, 0.2, 0, cb=tl_frame_cb, tip="The current frame (drag, or type a number)"
WIDGET wd_tl_start, WK_INT, "timeline.start", "Start", -100000.0, 100000.0, 0.2, 0, cb=tl_range_cb, tip="The first frame"
WIDGET wd_tl_end,   WK_INT, "timeline.end", "End", -100000.0, 100000.0, 0.2, 0, cb=tl_range_cb, tip="The last frame"
WIDGET wd_tl_fps,   WK_INT, "timeline.fps", "fps", 1.0, 1000.0, 0.1, 0, WGF_CLAMP, cb=tl_range_cb, tip="Frames per second"
WIDGET wd_tl_auto,  WK_BUTTON, "timeline.auto_key", flags=WGF_ICON, aux=op_an_autokey, n=ICON_RECORD

.section .rodata
.align 8
tl_items:       .quad wd_tl_first, 24, 0, wd_tl_prev, 24, 0, 0, 24, 0, wd_tl_next, 24, 0
                .quad wd_tl_last, 24, 0, wd_tl_frame, 100, tl_fr, wd_tl_start, 86, tl_st
                .quad wd_tl_end, 86, tl_en, wd_tl_fps, 70, tl_fps, wd_tl_auto, 24, 0, -1
.text
# tl_header_tools(edi=x, esi=header y, edx=right limit)
tl_header_tools:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     ebx, edi
    lea     r12d, [rsi+1]
    mov     r13d, edx
    movss   xmm0, [rip+an_frame]        # the values now
    cvtss2si eax, xmm0
    mov     [rip+tl_fr], eax
    call    an_range
    mov     [rip+tl_st], eax
    mov     [rip+tl_en], edx
    cvtss2si eax, xmm0
    mov     [rip+tl_fps], eax
    lea     r14, [rip+tl_items]
    jmp     tl_items_draw
# (shared with the key editors' header) r14 = items: desc, width, ptr; -1 ends
tl_items_draw:
1:  mov     rdi, [r14]
    cmp     rdi, -1
    je      9f
    test    rdi, rdi                    # 0: play or pause
    jnz     2f
    lea     rdi, [rip+wd_tl_play]
    cmp     dword ptr [rip+an_play], 0
    je      2f
    lea     rdi, [rip+wd_tl_pause]
2:  mov     ecx, [r14+8]
    lea     eax, [rbx+rcx]
    cmp     eax, r13d
    jg      9f
    mov     esi, ebx
    mov     edx, r12d
    mov     r8, [r14+16]
    cmp     r8, 4096                    # (small: a key editor's argument)
    jae     21f
    xor     r8d, r8d
21: xor     r9d, r9d
    call    wg
    mov     rcx, [r14+16]               # (a key editor button: its argument)
    cmp     rcx, 4096
    jae     3f
    test    rcx, rcx
    jz      3f
    test    eax, eax
    jz      3f
    call    ae_button
3:  mov     eax, [r14+8]
    lea     ebx, [rbx+rax+4]
    add     r14, 24
    jmp     1b
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

tl_frame_cb:                            # rdi = &tl_fr -> anim.frame
    sub     rsp, 8
    call    fmt_reset
    mov     edi, [rip+tl_fr]
    call    fmt_int
    add     rsp, 8
    lea     rdi, [rip+op_an_frame]
    jmp     run_fmt
tl_range_cb:                            # -> anim.range start end fps
    sub     rsp, 8
    call    fmt_reset
    mov     edi, [rip+tl_st]
    call    fmt_int
    mov     edi, ' '
    call    fmt_char
    mov     edi, [rip+tl_en]
    call    fmt_int
    mov     edi, ' '
    call    fmt_char
    mov     edi, [rip+tl_fps]
    call    fmt_int
    add     rsp, 8
    lea     rdi, [rip+op_an_range]
# run_fmt(rdi=op) - run it with fmt_buf (a copy) as its argument
run_fmt:
    push    rdi
    lea     rsi, [rip+fmt_buf]
    lea     rdi, [rip+au_arg]
    mov     ecx, 128
    rep     movsb
    pop     rdi
    lea     rsi, [rip+au_arg]
# run_arg3(rdi=op, rsi=argument)
run_arg3:
    push    qword ptr [rip+op_arg]
    mov     [rip+op_arg], rsi
    call    run_op
    pop     qword ptr [rip+op_arg]
    mov     dword ptr [rip+dirty], 1
    ret

# =============================================================================
#  The dope sheet / graph editor header: interpolation, handles, duplicate,
#  delete (the selected keys)
# =============================================================================
WIDGET wd_ae_const, WK_BUTTON, "keys.constant", "Constant", tip="The selected keys hold until the next one"
WIDGET wd_ae_lin,   WK_BUTTON, "keys.linear", "Linear", tip="Straight from key to key"
WIDGET wd_ae_bez,   WK_BUTTON, "keys.bezier", "Bezier", tip="Smooth curves through the keys (handles)"
WIDGET wd_ae_auto,  WK_BUTTON, "keys.handles_auto", "Auto", tip="Handles that keep the curve smooth"
WIDGET wd_ae_free,  WK_BUTTON, "keys.handles_free", "Free", tip="Handles you move yourself (graph editor)"
WIDGET wd_ae_dup,   WK_BUTTON, "keys.duplicate", "Duplicate", aux=op_ae_dup
WIDGET wd_ae_del,   WK_BUTTON, "keys.delete", "Delete", aux=op_ae_del

.section .rodata
.align 8
ae_items:       .quad wd_ae_const, 70, 1, wd_ae_lin, 56, 2, wd_ae_bez, 56, 3
                .quad wd_ae_auto, 44, 4, wd_ae_free, 44, 5, wd_ae_dup, 76, 0, wd_ae_del, 56, 0, -1
ae_args:        .quad 0, k_constant, k_linear, k_bezier, k_auto, k_free
.text
# ae_header_tools(edi=x, esi=header y, edx=right limit)
ae_header_tools:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     ebx, edi
    lea     r12d, [rsi+1]
    mov     r13d, edx
    lea     r14, [rip+ae_items]
    jmp     tl_items_draw

ae_button:                              # rcx = 1..5: interpolation / handles
    lea     rax, [rip+ae_args]
    mov     rsi, [rax+rcx*8]
    lea     rdi, [rip+op_an_interp]
    cmp     ecx, 4
    jb      1f
    lea     rdi, [rip+op_an_ht]
1:  sub     rsp, 8
    call    run_arg3
    add     rsp, 8
    ret

# =============================================================================
#  I over a field: a key on that property at the current frame
# =============================================================================
.section .rodata
n_loc:          .asciz "object.location"
n_rot:          .asciz "object.rotation"
n_scale:        .asciz "object.scale"
n_mod:          .asciz "modifier.value"
p_mat:          .asciz "material:"
p_mod:          .asciz "modifier:"
s_mat_pref:     .asciz "material."
.text
# field_key(edi=widget id) -> eax = 1 when it keyed it
field_key:
    push    rbx
    push    r12
    push    r13
    call    wg_find
    test    rax, rax
    jz      .Lfk_no
    mov     rbx, rax
    mov     eax, [rbx+4]                # (E_KIND) numbers and colours only
    cmp     eax, WK_FLOAT
    je      0f
    cmp     eax, WK_SLIDER
    je      0f
    cmp     eax, WK_INT
    je      0f
    cmp     eax, WK_COLOR
    jne     .Lfk_no
0:  mov     rax, [rbx+32]               # (E_DESC) its name
    mov     r12, [rax+WD_NAME]
    mov     r13d, [rbx+40]              # (E_SUB)
    mov     edi, [rip+active_obj]
    call    obj_get
    test    rax, rax
    jz      .Lfk_no
    mov     [rip+au_ob], rax
    lea     rdi, [rip+au_path]
    xor     edx, edx                    # transform: "Cube:x" .. "Cube:sz"
    mov     rsi, r12
    lea     rcx, [rip+n_loc]
    call    seq
    jz      1f
    mov     edx, 3
    lea     rcx, [rip+n_rot]
    call    seq
    jz      1f
    mov     edx, 6
    lea     rcx, [rip+n_scale]
    call    seq
    jz      1f
    lea     rcx, [rip+n_mod]
    call    seq
    jz      .Lfk_mod
    mov     rsi, r12                    # "material.roughness"
    lea     rcx, [rip+s_mat_pref]
    call    pref
    jz      .Lfk_mat
    jmp     .Lfk_no
1:  add     edx, r13d                   # the axis
    push    rdx
    mov     rsi, [rip+au_ob]            # (OB_NAME)
    call    cpy3
    mov     byte ptr [rdi], ':'
    inc     rdi
    pop     rdx
    lea     rsi, [rip+xyz_names]
    lea     rsi, [rsi+rdx*2]
    add     rsi, rdx
    call    cpy3
    call    key_path
    jmp     .Lfk_yes
.Lfk_mod:                               # "modifier:Cube:0:levels"
    lea     rsi, [rip+p_mod]
    call    cpy3
    mov     rsi, [rip+au_ob]
    call    cpy3
    mov     byte ptr [rdi], ':'
    inc     rdi
    mov     eax, r13d
    shr     eax, 4
    add     al, '0'
    mov     [rdi], al
    mov     byte ptr [rdi+1], ':'
    add     rdi, 2
    mov     esi, r13d                   # its parameter's name
    shr     esi, 4
    mov     rdi, [rip+au_ob]
    call    stack_index
    test    rax, rax
    jz      .Lfk_no
    mov     ecx, [rax]                  # (MD_TYPE)
    lea     rax, [rip+mod_params]
    mov     rax, [rax+rcx*8]
    mov     ecx, r13d
    and     ecx, 15
    shl     ecx, 5
    mov     rsi, [rax+8+rcx]
    lea     rdi, [rip+au_path]          # (back to the end)
    call    endof
    call    cpy3
    call    key_path
    jmp     .Lfk_yes
.Lfk_mat:                               # "material:M:roughness" (each component)
    mov     rdi, [rip+au_ob]
    call    mat_of
    test    eax, eax
    js      .Lfk_no
    mov     edi, eax
    call    mat_get
    push    rax
    lea     rdi, [rip+au_path]
    lea     rsi, [rip+p_mat]
    call    cpy3
    pop     rsi                         # (MA_NAME)
    call    cpy3
    mov     byte ptr [rdi], ':'
    inc     rdi
    lea     rsi, [rip+mat_params]       # the parameter's script name
    mov     eax, r13d
    shl     eax, 5
    mov     rcx, [rsi+rax]
    mov     r12d, [rsi+rax+12]          # (components)
    mov     rsi, rcx
    call    cpy3
    cmp     r12d, 1
    je      3f
    mov     byte ptr [rdi], ':'         # colours: each component
    mov     byte ptr [rdi+2], 0
    mov     rbx, rdi
    xor     r13d, r13d
2:  lea     eax, [r13+'0']
    mov     [rbx+1], al
    call    key_path
    inc     r13d
    cmp     r13d, r12d
    jb      2b
    jmp     .Lfk_yes
3:  call    key_path
.Lfk_yes:
    mov     eax, 1
    jmp     9f
.Lfk_no:
    xor     eax, eax
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# key_path - anim.key au_path (the current frame and value)
key_path:
    lea     rdi, [rip+op_an_path]
    lea     rsi, [rip+au_path]
    jmp     run_arg3

seq:                                    # rsi = a, rcx = b -> ZF when equal
    push    rsi
    push    rdi
    push    rdx
    mov     rdi, rsi
    mov     rsi, rcx
    call    str_eq
    pop     rdx
    pop     rdi
    pop     rsi
    cmp     eax, 1
    ret
pref:                                   # rsi = text, rcx = prefix -> ZF when it starts so
1:  mov     al, [rcx]
    test    al, al
    jz      2f
    cmp     al, [rsi]
    jne     3f
    inc     rcx
    inc     rsi
    jmp     1b
2:  xor     eax, eax                    # (ZF)
    ret
3:  or      eax, 1
    ret
cpy3:                                   # rdi = dest, rsi = text -> rdi at its 0
1:  mov     al, [rsi]
    mov     [rdi], al
    test    al, al
    jz      2f
    inc     rsi
    inc     rdi
    jmp     1b
2:  ret
endof:                                  # rdi -> its 0
1:  cmp     byte ptr [rdi], 0
    je      2f
    inc     rdi
    jmp     1b
2:  ret

# =============================================================================
#  The Animation tab
# =============================================================================
WIDGET wd_au_sk,   WK_SLIDER, "shape.value", , 0.0, 1.0, 0.005, 2, cb=sk_cb, undo="Shape Key", tip="How much of this shape is mixed in (I: key it)"
WIDGET wd_au_skx,  WK_BUTTON, "shape.remove", flags=WGF_ICON|WGF_COMPACT, n=ICON_CLOSE, tip="Remove the shape key"
WIDGET wd_au_skadd, WK_BUTTON, "shape.add", "Add Shape Key...", aux=op_sk_add
WIDGET wd_au_lyinf, WK_SLIDER, "layer.influence", , 0.0, 1.0, 0.005, 2, cb=ly_inf_cb, undo="Layer", tip="How strongly the layer's action plays"
WIDGET wd_au_lymute, WK_TOGGLE, "layer.mute", "Mute", flags=WGF_COMPACT, cb=ly_mute_cb, undo="Layer"
WIDGET wd_au_lyx,  WK_BUTTON, "layer.remove_layer", flags=WGF_ICON|WGF_COMPACT, n=ICON_CLOSE, tip="Remove the layer"
WIDGET wd_au_act,  WK_BUTTON, "anim.new_action", "New Action...", aux=op_an_action
WIDGET wd_au_lay,  WK_BUTTON, "anim.add_layer", "Add Layer...", aux=op_an_layer
WIDGET wd_au_drx,  WK_TEXT, "driver.expression", flags=WGF_COMPACT, cb=dr_expr_cb, tip="The driver's expression (Enter)"
WIDGET wd_au_drmute, WK_TOGGLE, "driver.mute", "Mute", flags=WGF_COMPACT, cb=dr_mute_cb
WIDGET wd_au_drdel, WK_BUTTON, "driver.remove", flags=WGF_ICON|WGF_COMPACT, n=ICON_CLOSE, tip="Remove the driver"
WIDGET wd_au_on,   WK_TOGGLE, "onion.on", "Onion skins", cb=onion_cb, tip="Ghosts of the active object before (red) and after (green) this frame"
WIDGET wd_au_onb,  WK_INT, "onion.before", "Before", 0.0, 8.0, 0.05, 0, WGF_CLAMP, cb=onion_cb
WIDGET wd_au_ona,  WK_INT, "onion.after", "After", 0.0, 8.0, 0.05, 0, WGF_CLAMP, cb=onion_cb
WIDGET wd_au_ons,  WK_INT, "onion.step", "Every", 1.0, 100.0, 0.05, 0, WGF_CLAMP, cb=onion_cb, tip="Frames between ghosts"
WIDGET wd_au_mp,   WK_BUTTON, "anim.motion_paths", "Motion Paths", aux=op_mpath
WIDGET wd_au_mpx,  WK_BUTTON, "anim.clear_paths", "Clear Paths"

.text
# animui_props(edi=y) -> eax = y below it
animui_props:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r12d, edi
    call    pnl_begin
    mov     edi, [rip+active_obj]
    call    obj_get
    mov     rbx, rax
    mov     [rip+au_ob], rax
    # ---- shape keys (a mesh) ----
    test    rbx, rbx
    jz      .Lap_actions
    cmp     dword ptr [rbx+OB_TYPE], OT_MESH
    jne     .Lap_actions
    mov     eax, [rbx+OB_UID]
    mov     [rip+au_uid], eax
    lea     rdx, [rip+s_h_shapes]
    call    pnl_heading
    mov     rax, [rbx+OB_MESH]
    mov     r14, [rax+ME_SHAPE]
    test    r14, r14
    jz      1f
    cmp     dword ptr [r14+SK_N], 1
    ja      2f
1:  lea     rdx, [rip+s_no_shapes]
    call    pnl_hint
    jmp     5f
2:  mov     r13d, 1                     # each key but the Basis
3:  cmp     r13d, [r14+SK_N]
    jae     5f
    cmp     r13d, MAXROW
    jae     5f
    imul    eax, r13d, SK_KSZ
    lea     r15, [r14+SK_KEYS+rax]      # its name, its value
    mov     edi, [rip+pnl_x]
    lea     esi, [r12+3]
    mov     rdx, r15
    mov     ecx, COL_TEXT
    call    draw_small
    lea     rcx, [rip+au_vals]
    mov     eax, [r15+SK_VAL]
    mov     [rcx+r13*4], eax
    lea     r8, [rcx+r13*4]
    lea     rdi, [rip+wd_au_sk]
    call    row_mid
    lea     rdi, [rip+wd_au_skx]
    call    row_x
    test    eax, eax
    jz      4f
    call    fmt_reset                   # shape.remove <name> <object>
    mov     rdi, r15
    call    fmt_str
    lea     rdi, [rip+s_sp]
    call    fmt_str
    mov     rdi, rbx
    call    fmt_str
    lea     rdi, [rip+op_sk_rem]
    call    run_fmt
    jmp     5f
4:  add     r12d, 22
    inc     r13d
    jmp     3b
5:  lea     rdi, [rip+wd_au_skadd]
    xor     r8d, r8d
    call    pnl_full
    add     r12d, 8

.Lap_actions:                           # ---- actions and layers ----
    lea     rdx, [rip+s_h_actions]
    call    pnl_heading
    mov     r14, [rip+an_cur]
    test    r14, r14
    jz      1f
    cmp     dword ptr [r14+AN_NACT], 0
    jne     2f
1:  lea     rdx, [rip+s_no_actions]
    call    pnl_hint
    jmp     .Lap_layers
2:  xor     r13d, r13d                  # actions: "name  frames s - e"
3:  cmp     r13d, [r14+AN_NACT]
    jae     .Lap_layers
    cmp     r13d, MAXROW
    jae     .Lap_layers
    mov     rdi, r14
    mov     esi, r13d
    call    an_act_at
    mov     r15, rax
    call    fmt_reset
    mov     rdi, r15
    call    fmt_str
    lea     rdi, [rip+s_frames]
    call    fmt_str
    cvtss2si edi, dword ptr [r15+32]
    call    fmt_int
    lea     rdi, [rip+s_dash]
    call    fmt_str
    cvtss2si edi, dword ptr [r15+36]
    call    fmt_int
    lea     rdx, [rip+fmt_buf]
    call    pnl_text
    inc     r13d
    jmp     3b
.Lap_layers:
    test    r14, r14
    jz      .Lap_lbtn
    xor     r13d, r13d                  # layers: name, influence, mute, x
1:  cmp     r13d, [r14+AN_NLAY]
    jae     .Lap_lbtn
    cmp     r13d, MAXROW
    jae     .Lap_lbtn
    mov     rdi, r14
    mov     esi, r13d
    call    an_lay_at
    mov     r15, rax
    call    fmt_reset                   # "Layer n: action"
    lea     rdi, [rip+s_layer]
    call    fmt_str
    lea     edi, [r13+1]
    call    fmt_int
    mov     edi, ' '
    call    fmt_char
    mov     esi, [r15+LY_ACT]
    dec     esi
    js      2f
    mov     rdi, r14
    call    an_act_at
    mov     rdi, rax
    call    fmt_str
2:  lea     rdx, [rip+fmt_buf]
    mov     edi, [rip+pnl_x]
    lea     esi, [r12+3]
    mov     ecx, COL_TEXT
    call    draw_small
    lea     rcx, [rip+au_vals]
    mov     eax, [r15+LY_INFL]
    mov     [rcx+r13*4], eax
    lea     r8, [rcx+r13*4]
    lea     rdi, [rip+wd_au_lyinf]
    call    row_mid
    lea     rdi, [rip+wd_au_lyx]
    call    row_x
    test    eax, eax
    jz      3f
    call    fmt_reset
    lea     edi, [r13+1]
    call    fmt_int
    lea     rdi, [rip+op_an_lrem]
    call    run_fmt
    jmp     .Lap_lbtn
3:  add     r12d, 22
    lea     rcx, [rip+au_tog]           # mute, under it
    mov     eax, [r15+LY_MUTE]
    mov     [rcx+r13*4], eax
    lea     r8, [rcx+r13*4]
    lea     rdi, [rip+wd_au_lymute]
    mov     esi, [rip+pnl_x]
    add     esi, 12
    mov     edx, r12d
    mov     ecx, 90
    mov     r9d, r13d
    call    wg
    add     r12d, 22
    inc     r13d
    jmp     1b
.Lap_lbtn:
    lea     rdi, [rip+wd_au_act]
    xor     r8d, r8d
    call    pnl_left
    lea     rdi, [rip+wd_au_lay]
    xor     r8d, r8d
    call    pnl_right
    add     r12d, WG_H+12

    # ---- drivers ----
    lea     rdx, [rip+s_h_drivers]
    call    pnl_heading
    test    r14, r14
    jz      1f
    cmp     dword ptr [r14+AN_NDRV_], 0
    jne     2f
1:  lea     rdx, [rip+s_no_drivers]
    call    pnl_hint
    jmp     .Lap_onion
2:  xor     r13d, r13d
3:  cmp     r13d, [r14+AN_NDRV_]
    jae     .Lap_onion
    cmp     r13d, MAXROW
    jae     .Lap_onion
    imul    eax, r13d, DR_SZ_
    lea     r15, [r14+AN_DRV_+rax]
    call    fmt_reset                   # "Driver n"
    lea     rdi, [rip+s_driver]
    call    fmt_str
    lea     edi, [r13+1]
    call    fmt_int
    lea     rdx, [rip+fmt_buf]
    mov     edi, [rip+pnl_x]
    lea     esi, [r12+3]
    mov     ecx, COL_TEXT
    call    draw_small
    lea     r8, [r15+DR_EXPR]
    lea     rdi, [rip+wd_au_drx]
    call    row_mid
    lea     rdi, [rip+wd_au_drdel]
    call    row_x
    test    eax, eax
    jz      4f
    call    fmt_reset
    lea     edi, [r13+1]
    call    fmt_int
    lea     rdi, [rip+s_remove]
    call    fmt_str
    lea     rdi, [rip+op_dr_set]
    call    run_fmt
    jmp     .Lap_onion
4:  add     r12d, 22
    lea     rcx, [rip+au_tog2]
    mov     eax, [r15+DR_MUTE]
    mov     [rcx+r13*4], eax
    lea     r8, [rcx+r13*4]
    lea     rdi, [rip+wd_au_drmute]
    mov     esi, [rip+pnl_x]
    add     esi, 12
    mov     edx, r12d
    mov     ecx, 90
    mov     r9d, r13d
    call    wg
    add     r12d, 22
    inc     r13d
    jmp     3b

.Lap_onion:                             # ---- onion skins, motion paths ----
    add     r12d, 8
    lea     rdx, [rip+s_h_onion]
    call    pnl_heading
    mov     eax, [rip+on_on]
    mov     [rip+au_on], eax
    lea     rdi, [rip+wd_au_on]
    lea     r8, [rip+au_on]
    call    pnl_full
    lea     rdi, [rip+wd_au_onb]
    lea     r8, [rip+on_before]
    call    pnl_full
    lea     rdi, [rip+wd_au_ona]
    lea     r8, [rip+on_after]
    call    pnl_full
    lea     rdi, [rip+wd_au_ons]
    lea     r8, [rip+on_step]
    call    pnl_full
    lea     rdi, [rip+wd_au_mp]
    xor     r8d, r8d
    call    pnl_left
    lea     rdi, [rip+wd_au_mpx]
    xor     r8d, r8d
    call    pnl_right
    test    eax, eax
    jz      1f
    lea     rdi, [rip+op_mpath]
    lea     rsi, [rip+k_clear]
    call    run_arg3
1:  add     r12d, WG_H+4
    mov     eax, r12d
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# row_mid(rdi=desc, r8=ptr; r13d = sub) - the middle of a list row (40 %
#   .. the x) at r12d; row_x(rdi=desc) - its x at the right -> eax clicked
row_mid:
    mov     eax, [rip+pnl_w]
    imul    eax, eax, 40
    xor     edx, edx
    mov     ecx, 100
    div     ecx
    mov     esi, [rip+pnl_x]
    add     esi, eax
    mov     ecx, [rip+pnl_w]
    sub     ecx, eax
    sub     ecx, 22
    mov     edx, r12d
    mov     r9d, r13d
    sub     rsp, 8
    call    wg
    add     rsp, 8
    ret
row_x:
    mov     esi, [rip+pnl_x]
    add     esi, [rip+pnl_w]
    sub     esi, 18
    mov     ecx, 18
    mov     edx, r12d
    xor     r8d, r8d
    mov     r9d, r13d
    sub     rsp, 8
    call    wg
    add     rsp, 8
    ret

# ---- callbacks: rdi = the value, esi = the row --------------------------------------
sk_cb:                                  # a shape key's value, on the mesh
    movss   xmm0, [rdi]
    mov     edi, [rip+au_uid]
    mov     edx, 1
    sub     rsp, 8
    call    sk_chan
    add     rsp, 8
    mov     dword ptr [rip+dirty], 1
    ret
ly_inf_cb:                              # a layer's influence / mute
    mov     ecx, LY_INFL
    jmp     1f
ly_mute_cb:
    mov     ecx, LY_MUTE
1:  push    rbx
    push    r12
    push    r13
    mov     ebx, [rdi]
    mov     r12d, esi
    mov     r13d, ecx
    xor     edi, edi
    call    an_own_g
    test    rax, rax
    jz      9f
    mov     rdi, rax
    mov     esi, r12d
    call    an_lay_at
    mov     [rax+r13], ebx
    mov     dword ptr [rip+dirty], 1
9:  pop     r13
    pop     r12
    pop     rbx
    ret
dr_expr_cb:                             # rdi = new text -> anim.driver_set n expression
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    mov     r12d, esi
    call    fmt_reset
    lea     edi, [r12+1]
    call    fmt_int
    lea     rdi, [rip+s_expr]
    call    fmt_str
    mov     rdi, rbx
    call    fmt_str
    add     rsp, 8
    pop     r12
    pop     rbx
    lea     rdi, [rip+op_dr_set]
    jmp     run_fmt
dr_mute_cb:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     ebx, [rdi]
    mov     r12d, esi
    call    fmt_reset
    lea     edi, [r12+1]
    call    fmt_int
    lea     rdi, [rip+s_mute]
    call    fmt_str
    mov     edi, ebx
    call    fmt_int
    add     rsp, 8
    pop     r12
    pop     rbx
    lea     rdi, [rip+op_dr_set]
    jmp     run_fmt
onion_cb:                               # anim.onion before after step | off
    sub     rsp, 8
    call    fmt_reset
    cmp     dword ptr [rip+au_on], 0
    je      1f
    mov     edi, [rip+on_before]
    call    fmt_int
    mov     edi, ' '
    call    fmt_char
    mov     edi, [rip+on_after]
    call    fmt_int
    mov     edi, ' '
    call    fmt_char
    mov     edi, [rip+on_step]
    call    fmt_int
    jmp     2f
1:  lea     rdi, [rip+s_off]
    call    fmt_str
2:  add     rsp, 8
    lea     rdi, [rip+op_onion]
    jmp     run_fmt

# =============================================================================
#  The Rig tab
# =============================================================================
WIDGET wd_rg_bone, WK_ROW, "rig.bone", cb=bone_cb, tip="Make it the active bone"
WIDGET wd_rg_loc,  WK_FLOAT, "rig.pose.location", step=0.01, dec=3, flags=WGF_COMPACT, cb=pose_cb, undo="Pose"
WIDGET wd_rg_rot,  WK_FLOAT, "rig.pose.rotation", step=0.00872665, dec=1, flags=WGF_COMPACT|WGF_DEG, cb=pose_cb, undo="Pose"
WIDGET wd_rg_scl,  WK_FLOAT, "rig.pose.scale", step=0.005, dec=3, flags=WGF_COMPACT, cb=pose_cb, undo="Pose"
WIDGET wd_rg_cinf, WK_SLIDER, "constraint.influence", , 0.0, 1.0, 0.005, 2, cb=cn_inf_cb, undo="Constraint"
WIDGET wd_rg_cmute, WK_TOGGLE, "constraint.mute", "Mute", flags=WGF_COMPACT, cb=cn_mute_cb, undo="Constraint"
WIDGET wd_rg_cx,   WK_BUTTON, "constraint.remove", flags=WGF_ICON|WGF_COMPACT, n=ICON_CLOSE, tip="Remove the constraint"
WIDGET wd_rg_cadd, WK_BUTTON, "constraint.add", "Add Constraint...", aux=op_cn_add
WIDGET wd_rg_par,  WK_BUTTON, "rig.parent", "Parent to Armature...", aux=op_arm_parent, tip="Skin this mesh to an armature with automatic weights"
.section .rodata
k_clear:        .asciz "clear"
.section .bss
.align 8
rg_blk:         .skip 8
rg_act:         .skip 4
.text
# rigui_props(edi=y) -> eax = y below it
rigui_props:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r12d, edi
    call    pnl_begin
    mov     edi, [rip+active_obj]
    call    obj_get
    mov     rbx, rax
    mov     [rip+au_ob], rax
    test    rbx, rbx
    jz      .Lrp_out
    mov     eax, [rbx+OB_UID]
    mov     [rip+au_uid], eax
    lea     rdx, [rip+s_h_bones]        # ---- bones ----
    call    pnl_heading
    mov     rdi, rbx
    call    arm_of
    mov     r14, rax
    mov     [rip+rg_blk], rax
    test    r14, r14
    jnz     1f
    lea     rdx, [rip+s_no_arm]
    call    pnl_hint
    cmp     dword ptr [rbx+OB_TYPE], OT_MESH   # a mesh: Parent to Armature
    jne     .Lrp_cons
    lea     rdi, [rip+wd_rg_par]
    xor     r8d, r8d
    call    pnl_full
    jmp     .Lrp_cons
1:  mov     eax, [r14+AR_ACT]
    mov     [rip+rg_act], eax
    xor     r13d, r13d
2:  cmp     r13d, [r14+AR_N]
    jae     4f
    cmp     r13d, 64
    jae     4f
    imul    eax, r13d, BN_SZ
    lea     r15, [r14+AR_BONES+rax]
    lea     rdi, [rip+wd_rg_bone]
    mov     esi, [rip+pnl_x]
    mov     edx, r12d
    mov     ecx, [rip+pnl_w]
    lea     r8, [rip+rg_act]
    mov     r9d, r13d
    call    wg
    mov     rdi, r15
    call    wg_set_label
    mov     edi, [rip+pnl_x]            # (a child is indented)
    add     edi, 8
    cmp     dword ptr [r15+BN_PARENT], 0
    jl      3f
    add     edi, 12
3:  lea     esi, [r12+3]
    mov     rdx, r15
    mov     ecx, COL_TEXT
    call    draw_text
    add     r12d, 24
    inc     r13d
    jmp     2b
4:  mov     eax, [r14+AR_ACT]           # the active bone's pose
    test    eax, eax
    js      .Lrp_cons
    cmp     eax, [r14+AR_N]
    jae     .Lrp_cons
    imul    eax, eax, BN_SZ
    lea     r15, [r14+AR_BONES+rax]
    add     r12d, 6
    call    fmt_reset
    lea     rdi, [rip+s_h_pose]
    call    fmt_str
    mov     rdi, r15
    call    fmt_str
    lea     rdx, [rip+fmt_buf]
    call    pnl_heading
    lea     rsi, [r15+BN_LOC]           # loc rot scale (9 floats)
    lea     rdi, [rip+au_pose]
    mov     ecx, 36
    rep     movsb
    xor     r13d, r13d
5:  lea     rax, [rip+pose_descs]
    mov     rdi, [rax+r13*8]
    mov     eax, r13d                   # three fields a row
    xor     edx, edx
    mov     ecx, 3
    div     ecx
    mov     eax, [rip+pnl_w]
    imul    eax, edx
    push    rdx
    xor     edx, edx
    mov     ecx, 3
    div     ecx
    pop     rdx
    mov     esi, [rip+pnl_x]
    add     esi, eax
    mov     ecx, [rip+pnl_w]
    push    rdx
    mov     eax, ecx
    xor     edx, edx
    mov     ecx, 3
    div     ecx
    lea     ecx, [rax-4]
    pop     rdx
    mov     edx, r12d
    lea     r8, [rip+au_pose]
    lea     r8, [r8+r13*4]
    mov     r9d, r13d
    call    wg
    inc     r13d
    mov     eax, r13d
    xor     edx, edx
    mov     ecx, 3
    div     ecx
    test    edx, edx
    jnz     6f
    add     r12d, 22
6:  cmp     r13d, 9
    jb      5b

.Lrp_cons:                              # ---- constraints on it ----
    add     r12d, 10
    lea     rdx, [rip+s_h_cons]
    call    pnl_heading
    mov     r14, [rip+an_cur]
    xor     r13d, r13d
    xor     r15d, r15d                  # (shown)
1:  test    r14, r14
    jz      7f
    cmp     r13d, [r14+AN_NCON_]
    jae     7f
    cmp     r13d, MAXROW
    jae     7f
    imul    eax, r13d, CN_SZ_
    lea     rax, [r14+AN_CON_+rax]
    mov     ecx, [rip+au_uid]
    cmp     [rax+CN_OWNER], ecx
    jne     6f
    push    rax
    push    rax
    call    fmt_reset                   # "IK -> Target"
    mov     rax, [rsp]
    mov     ecx, [rax+CN_TYPE]
    cmp     ecx, 9
    ja      2f
    lea     rdx, [rip+ct_labels]
    mov     rdi, [rdx+rcx*8]
    test    rdi, rdi
    jz      2f
    call    fmt_str
2:  mov     rax, [rsp]
    mov     edi, [rax+CN_TARGET]
    test    edi, edi
    jz      3f
    call    obj_by_uid
    test    rax, rax
    jz      3f
    push    rax
    lea     rdi, [rip+s_on]
    call    fmt_str
    pop     rdi
    call    fmt_str
3:  lea     rdx, [rip+fmt_buf]
    call    pnl_text
    mov     rax, [rsp]
    lea     rcx, [rip+au_vals]          # influence | mute | x
    mov     edx, [rax+CN_INFL]
    mov     [rcx+r13*4], edx
    lea     r8, [rcx+r13*4]
    lea     rdi, [rip+wd_rg_cinf]
    call    row_mid
    mov     rax, [rsp]
    lea     rcx, [rip+au_tog]
    mov     edx, [rax+CN_FLAGS]
    shr     edx, 2                      # (CF_MUTE)
    and     edx, 1
    mov     [rcx+r13*4], edx
    lea     r8, [rcx+r13*4]
    lea     rdi, [rip+wd_rg_cmute]
    mov     esi, [rip+pnl_x]
    mov     edx, r12d
    mov     ecx, 80
    mov     r9d, r13d
    call    wg
    lea     rdi, [rip+wd_rg_cx]
    call    row_x
    pop     rcx
    pop     rcx
    test    eax, eax
    jz      5f
    call    fmt_reset
    lea     edi, [r13+1]
    call    fmt_int
    lea     rdi, [rip+op_cn_rem]
    call    run_fmt
    jmp     7f
5:  add     r12d, 26
    inc     r15d
6:  inc     r13d
    jmp     1b
7:  test    r15d, r15d
    jnz     8f
    lea     rdx, [rip+s_no_cons]
    call    pnl_hint
8:  lea     rdi, [rip+wd_rg_cadd]
    xor     r8d, r8d
    call    pnl_full
.Lrp_out:
    mov     eax, r12d
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.section .rodata
.align 8
pose_descs:     .quad wd_rg_loc, wd_rg_loc, wd_rg_loc, wd_rg_rot, wd_rg_rot, wd_rg_rot
                .quad wd_rg_scl, wd_rg_scl, wd_rg_scl
pose_kw:        .quad s_loc, s_rot, s_scale
.text

bone_cb:                                # rdi = &rg_act -> arm.select_bone
    mov     esi, [rdi]
    mov     rdi, [rip+rg_blk]
    test    rdi, rdi
    jz      9f
    imul    eax, esi, BN_SZ
    lea     rsi, [rdi+AR_BONES+rax]
    lea     rdi, [rip+op_arm_sel]
    jmp     run_arg3
9:  ret

# pose_cb(esi=field 0..8) - "bone loc|rot|scale x y z" to arm.pose's exec (the
#   field made the undo step)
pose_cb:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     eax, esi
    xor     edx, edx
    mov     ecx, 3
    div     ecx
    mov     r12d, eax                   # which: loc rot scale
    mov     rdi, [rip+rg_blk]
    test    rdi, rdi
    jz      9f
    mov     eax, [rdi+AR_ACT]
    imul    eax, eax, BN_SZ
    lea     rax, [rdi+AR_BONES+rax]
    push    rax
    sub     rsp, 8
    call    fmt_reset
    mov     rdi, [rsp+8]
    call    fmt_str
    lea     rax, [rip+pose_kw]
    mov     rdi, [rax+r12*8]
    call    fmt_str
    imul    ebx, r12d, 3
    add     rsp, 16
    xor     r12d, r12d
1:  mov     edi, ' '
    call    fmt_char
    lea     rax, [rip+au_pose]
    movss   xmm0, [rax+rbx*4]
    mov     eax, ebx                    # (rot: degrees)
    sub     eax, 3
    cmp     eax, 3
    jae     3f
    mulss   xmm0, [rip+f_r2d]
3:  call    fmt_val3
    inc     ebx
    inc     r12d
    cmp     r12d, 3
    jb      1b
    lea     rsi, [rip+fmt_buf]          # (a copy)
    lea     rdi, [rip+au_arg]
    mov     ecx, 128
    rep     movsb
    push    qword ptr [rip+op_arg]
    lea     rax, [rip+au_arg]
    mov     [rip+op_arg], rax
    call    fa_mark
    push    rax
    call    do_arm_pose
    pop     rdi
    call    fa_release
    pop     qword ptr [rip+op_arg]
    mov     dword ptr [rip+dirty], 1
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

cn_inf_cb:                              # a constraint's influence / mute
    push    rbx
    push    r12
    sub     rsp, 8
    mov     ebx, [rdi]
    mov     r12d, esi
    xor     edi, edi
    call    an_own_g
    test    rax, rax
    jz      9f
    imul    ecx, r12d, CN_SZ_
    mov     [rax+AN_CON_+rcx+CN_INFL], ebx
    jmp     8f
cn_mute_cb:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     ebx, [rdi]
    mov     r12d, esi
    xor     edi, edi
    call    an_own_g
    test    rax, rax
    jz      9f
    imul    ecx, r12d, CN_SZ_
    lea     rax, [rax+AN_CON_+rcx]
    and     dword ptr [rax+CN_FLAGS], ~CF_MUTE
    test    ebx, ebx
    jz      8f
    or      dword ptr [rax+CN_FLAGS], CF_MUTE
8:  mov     dword ptr [rip+dirty], 1
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

.section .note.GNU-stack,"",@progbits
