# =============================================================================
#  BeeModel - physics from the Properties editor (below the rigid body
#  section): cloth / soft body / collider with their settings and pins, the
#  cloth world's wind, joints between two selected objects, and the
#  simulation cache (bake, free, budget; the cached range shows in the
#  timeline).
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"
.include "widgets.inc"

.globl sim_props

.equ CW_WIND,   0                       # (cloth.s)
.equ CW_SUB,    12
.equ CW_N,      20
.equ CL_UID,    0
.equ CL_TYPE,   4
.equ CL_STRETCH,8
.equ CL_FLAGS,  36

.section .bss
.align 8
sm_cl:          .skip 4*9               # type-1, stretch bend volume mass damping thickness friction, self
sm_wind:        .skip 12
sm_sub:         .skip 4
sm_budget:      .skip 4
sm_arg:         .skip 256

.section .rodata
s_h_cloth:      .asciz "Cloth and Soft Body"
s_h_world:      .asciz "Cloth World"
s_h_joint:      .asciz "Joints"
s_h_cache:      .asciz "Simulation Cache"
s_no_cloth:     .asciz "Make the selected objects cloth, soft bodies or colliders:"
s_joint_hint:   .asciz "Select two objects (or one, tied to the world)."
s_cloth_k:      .asciz "cloth"
s_soft_k:       .asciz "soft"
s_coll_k:       .asciz "collider"
s_cl_cloth:     .asciz "Cloth"
s_cl_soft:      .asciz "Soft body"
s_cl_coll:      .asciz "Collider"
k_stretch:      .asciz " stretch "
k_bend:         .asciz " bend "
k_volume:       .asciz " volume "
k_mass:         .asciz " mass "
k_damping:      .asciz " damping "
k_thick:        .asciz " thickness "
k_fric:         .asciz " friction "
k_self:         .asciz " self"
k_wind:         .asciz "wind "
k_substeps:     .asciz " substeps "
k_budget:       .asciz "budget "
k_selected:     .asciz "selected"
k_none:         .asciz "none"
s_sp:           .asciz " "
s_frames:       .asciz " frames cached (rigid), "
s_frames2:      .asciz " (cloth), "
s_mb:           .asciz " MB"
.align 8
l_cltype:       .quad s_cl_cloth, s_cl_soft, s_cl_coll
kw_cltype:      .quad s_cloth_k, s_soft_k, s_coll_k
cl_keys:        .quad k_stretch, k_bend, k_volume, k_mass, k_damping, k_thick, k_fric

.text
WIDGET wd_sm_type, WK_ENUM, "cloth.type", cb=cl_cb, undo="Cloth", aux=l_cltype, n=3, tip="Cloth: a sheet. Soft body: a squashy solid. Collider: others bump into it"
WIDGET wd_sm_str,  WK_FLOAT, "cloth.stretch", "Stretch compliance", 0.0, 1.0, 0.00001, 6, WGF_CLAMP, cb=cl_cb, undo="Cloth", tip="How much it stretches (m/N, 0: not at all)"
WIDGET wd_sm_bend, WK_FLOAT, "cloth.bend", "Bend compliance", 0.0, 10.0, 0.0001, 5, WGF_CLAMP, cb=cl_cb, undo="Cloth", tip="How easily it folds (0: stiff)"
WIDGET wd_sm_vol,  WK_FLOAT, "cloth.volume", "Volume compliance", 0.0, 1.0, 0.00001, 6, WGF_CLAMP, cb=cl_cb, undo="Cloth", tip="Soft bodies: how much they squash"
WIDGET wd_sm_mass, WK_FLOAT, "cloth.mass", "Mass (kg)", 0.001, 100000.0, 0.01, 3, WGF_CLAMP, cb=cl_cb, undo="Cloth"
WIDGET wd_sm_damp, WK_FLOAT, "cloth.damping", "Damping", 0.0, 10.0, 0.005, 3, WGF_CLAMP, cb=cl_cb, undo="Cloth"
WIDGET wd_sm_thick, WK_FLOAT, "cloth.thickness", "Thickness", 0.0, 10.0, 0.001, 3, WGF_CLAMP, cb=cl_cb, undo="Cloth", tip="How far it stays from colliders"
WIDGET wd_sm_fric, WK_FLOAT, "cloth.friction", "Friction", 0.0, 2.0, 0.005, 3, WGF_CLAMP, cb=cl_cb, undo="Cloth"
WIDGET wd_sm_self, WK_TOGGLE, "cloth.self", "Collides with itself", cb=cl_cb, undo="Cloth"
WIDGET wd_sm_pin,  WK_BUTTON, "cloth.pin_selected", "Pin Selected", tip="Edit mode: the selected vertices hold to the object"
WIDGET wd_sm_unpin, WK_BUTTON, "cloth.unpin", "Unpin All"
WIDGET wd_sm_rem,  WK_BUTTON, "cloth.remove", "Remove", aux=op_cl_rem
WIDGET wd_sm_mk1,  WK_BUTTON, "cloth.make_cloth", "Cloth"
WIDGET wd_sm_mk2,  WK_BUTTON, "cloth.make_soft", "Soft Body"
WIDGET wd_sm_mk3,  WK_BUTTON, "cloth.make_collider", "Collider"
WIDGET wd_sm_wx,   WK_FLOAT, "cloth.wind_x", "Wind X", step=0.01, dec=2, flags=WGF_COMPACT, cb=wind_cb, undo="Cloth World"
WIDGET wd_sm_wy,   WK_FLOAT, "cloth.wind_y", "Y", step=0.01, dec=2, flags=WGF_COMPACT, cb=wind_cb, undo="Cloth World"
WIDGET wd_sm_wz,   WK_FLOAT, "cloth.wind_z", "Z", step=0.01, dec=2, flags=WGF_COMPACT, cb=wind_cb, undo="Cloth World"
WIDGET wd_sm_sub,  WK_INT, "cloth.substeps", "Substeps", 1.0, 100.0, 0.1, 0, WGF_CLAMP, cb=wind_cb, undo="Cloth World", tip="More is more accurate and slower"
WIDGET wd_sm_joint, WK_BUTTON, "rigid.add_joint", "Add Joint...", aux=op_rb_joint
WIDGET wd_sm_bake, WK_BUTTON, "sim.bake", "Bake", aux=op_sim_bake, tip="Simulate the frame range and keep it (saved with the file)"
WIDGET wd_sm_free, WK_BUTTON, "sim.free", "Free", aux=op_sim_free, tip="Forget the cache (simulated again when played)"
WIDGET wd_sm_budget, WK_INT, "sim.budget", "Memory budget (MB)", 16.0, 1048576.0, 1.0, 0, WGF_CLAMP, cb=budget_cb

.section .rodata
.align 8
cl_fields:      .quad wd_sm_str, wd_sm_bend, wd_sm_vol, wd_sm_mass, wd_sm_damp, wd_sm_thick, wd_sm_fric
.text

# sim_props(edi=y) -> eax = y below it (the Physics tab, after rigid bodies)
sim_props:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r12d, edi
    call    pnl_begin
    add     r12d, 8
    lea     rdx, [rip+s_h_cloth]
    call    pnl_heading
    mov     edi, [rip+active_obj]
    call    obj_get
    test    rax, rax
    jz      .Lsp_world
    mov     ebx, [rax+OB_UID]
    call    cloth_rec                   # (rax: its record, or 0)
    mov     r14, rax
    test    r14, r14
    jnz     1f
    lea     rdx, [rip+s_no_cloth]       # not yet: Cloth | Soft Body | Collider
    call    pnl_hint
    lea     r15, [rip+mk_btns]
    xor     r13d, r13d
0:  mov     rdi, [r15+r13*8]
    mov     eax, [rip+pnl_w]
    add     eax, 4
    xor     edx, edx
    mov     ecx, 3
    div     ecx
    mov     ecx, eax
    imul    eax, r13d
    mov     esi, [rip+pnl_x]
    add     esi, eax
    sub     ecx, 4
    mov     edx, r12d
    xor     r8d, r8d
    xor     r9d, r9d
    call    wg
    test    eax, eax
    jz      11f
    lea     rax, [rip+kw_cltype]
    mov     rsi, [rax+r13*8]
    lea     rdi, [rip+op_cl_add]
    call    run_arg_s
11: inc     r13d
    cmp     r13d, 3
    jb      0b
    add     r12d, WG_H+4
    jmp     .Lsp_world
1:  lea     rdi, [rip+sm_cl]            # its values
    mov     eax, [r14+CL_TYPE]
    dec     eax
    mov     [rdi], eax
    lea     rsi, [r14+CL_STRETCH]
    lea     rdi, [rip+sm_cl+4]
    mov     ecx, 28
    rep     movsb
    mov     eax, [r14+CL_FLAGS]
    and     eax, 1
    mov     [rip+sm_cl+32], eax
    lea     rdi, [rip+wd_sm_type]
    lea     r8, [rip+sm_cl]
    call    pnl_full
    xor     r13d, r13d
2:  lea     rax, [rip+cl_fields]
    mov     rdi, [rax+r13*8]
    lea     r8, [rip+sm_cl+4]
    lea     r8, [r8+r13*4]
    call    pnl_full
    inc     r13d
    cmp     r13d, 7
    jb      2b
    lea     rdi, [rip+wd_sm_self]
    lea     r8, [rip+sm_cl+32]
    call    pnl_full
    lea     rdi, [rip+wd_sm_pin]        # pins | unpin | remove
    xor     r8d, r8d
    call    pnl_left
    test    eax, eax
    jz      3f
    lea     rdi, [rip+op_cl_pin]
    lea     rsi, [rip+k_selected]
    call    run_arg_s
3:  lea     rdi, [rip+wd_sm_unpin]
    xor     r8d, r8d
    call    pnl_right
    test    eax, eax
    jz      4f
    lea     rdi, [rip+op_cl_pin]
    lea     rsi, [rip+k_none]
    call    run_arg_s
4:  add     r12d, WG_H+4
    lea     rdi, [rip+wd_sm_rem]
    xor     r8d, r8d
    call    pnl_full

.Lsp_world:                             # ---- the cloth world ----
    add     r12d, 8
    lea     rdx, [rip+s_h_world]
    call    pnl_heading
    mov     rax, [rip+an_cur]
    test    rax, rax
    jz      .Lsp_joint
    lea     rsi, [rax+AN_CW_+CW_WIND]
    lea     rdi, [rip+sm_wind]
    mov     ecx, 12
    rep     movsb
    mov     ecx, [rax+AN_CW_+CW_SUB]
    test    ecx, ecx
    jnz     1f
    mov     ecx, 10
1:  mov     [rip+sm_sub], ecx
    xor     r13d, r13d                  # wind x y z in a row
2:  lea     rax, [rip+wind_fields]
    mov     rdi, [rax+r13*8]
    mov     eax, [rip+pnl_w]
    xor     edx, edx
    mov     ecx, 3
    div     ecx
    mov     ecx, eax
    imul    eax, r13d
    mov     esi, [rip+pnl_x]
    add     esi, eax
    sub     ecx, 4
    mov     edx, r12d
    lea     r8, [rip+sm_wind]
    lea     r8, [r8+r13*4]
    xor     r9d, r9d
    call    wg
    inc     r13d
    cmp     r13d, 3
    jb      2b
    add     r12d, 24
    lea     rdi, [rip+wd_sm_sub]
    lea     r8, [rip+sm_sub]
    call    pnl_full

.Lsp_joint:                             # ---- joints ----
    add     r12d, 8
    lea     rdx, [rip+s_h_joint]
    call    pnl_heading
    lea     rdx, [rip+s_joint_hint]
    call    pnl_hint
    lea     rdi, [rip+wd_sm_joint]
    xor     r8d, r8d
    call    pnl_full

    add     r12d, 8                     # ---- the cache ----
    lea     rdx, [rip+s_h_cache]
    call    pnl_heading
    call    fmt_reset                   # "n frames (rigid), m (cloth), k MB"
    xor     edi, edi
    call    sc_info
    cvtss2si edi, xmm0
    call    fmt_int
    lea     rdi, [rip+s_frames]
    call    fmt_str
    mov     edi, 1
    call    sc_info
    cvtss2si edi, xmm0
    call    fmt_int
    lea     rdi, [rip+s_frames2]
    call    fmt_str
    mov     edi, 2
    call    sc_info
    call    fmt_val3
    lea     rdi, [rip+s_mb]
    call    fmt_str
    lea     rdx, [rip+fmt_buf]
    call    pnl_hint
    lea     rdi, [rip+wd_sm_bake]
    xor     r8d, r8d
    call    pnl_left
    lea     rdi, [rip+wd_sm_free]
    xor     r8d, r8d
    call    pnl_right
    add     r12d, WG_H+4
    mov     edi, 6
    call    sc_info
    cvtss2si eax, xmm0
    mov     [rip+sm_budget], eax
    lea     rdi, [rip+wd_sm_budget]
    lea     r8, [rip+sm_budget]
    call    pnl_full
    mov     eax, r12d
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.section .rodata
.align 8
mk_btns:        .quad wd_sm_mk1, wd_sm_mk2, wd_sm_mk3
wind_fields:    .quad wd_sm_wx, wd_sm_wy, wd_sm_wz
.text

# cloth_rec(ebx=uid) -> rax = its cloth record, or 0
cloth_rec:
    mov     rax, [rip+an_cur]
    test    rax, rax
    jz      8f
    mov     ecx, [rax+AN_CW_+CW_N]
    lea     rax, [rax+AN_CL_]
1:  test    ecx, ecx
    jz      8f
    cmp     [rax+CL_UID], ebx
    je      9f
    add     rax, CL_SZ_
    dec     ecx
    jmp     1b
8:  xor     eax, eax
9:  ret

# run_arg_s(rdi=op, rsi=argument) - run it (an undo step of its own)
run_arg_s:
    push    qword ptr [rip+op_arg]
    mov     [rip+op_arg], rsi
    call    run_op
    pop     qword ptr [rip+op_arg]
    ret

# exec_arg(rdi=exec, sm_arg) - an operator's exec with that argument (the
#   field made the undo step)
exec_arg:
    push    rbx
    push    r12
    sub     rsp, 16
    mov     rbx, rdi
    push    qword ptr [rip+op_arg]
    lea     rax, [rip+sm_arg]
    mov     [rip+op_arg], rax
    call    fa_mark
    mov     r12, rax
    call    rbx
    mov     rdi, r12
    call    fa_release
    pop     qword ptr [rip+op_arg]
    mov     dword ptr [rip+dirty], 1
    add     rsp, 16
    pop     r12
    pop     rbx
    ret

# cl_cb - cloth.add <type> stretch .. friction .. [self] on the selection
cl_cb:
    push    rbx
    sub     rsp, 16
    call    fmt_reset
    mov     eax, [rip+sm_cl]
    lea     rcx, [rip+kw_cltype]
    mov     rdi, [rcx+rax*8]
    call    fmt_str
    xor     ebx, ebx
1:  lea     rax, [rip+cl_keys]
    mov     rdi, [rax+rbx*8]
    call    fmt_str
    lea     rax, [rip+sm_cl+4]
    movss   xmm0, [rax+rbx*4]
    call    put_num6                    # (6 decimals: compliances are small)
    inc     ebx
    cmp     ebx, 7
    jb      1b
    cmp     dword ptr [rip+sm_cl+32], 0
    je      2f
    lea     rdi, [rip+k_self]
    call    fmt_str
2:  call    arg_from_fmt
    lea     rdi, [rip+do_cl_add]
    call    exec_arg
    add     rsp, 16
    pop     rbx
    ret

# wind_cb - cloth.world wind x y z substeps n
wind_cb:
    push    rbx
    sub     rsp, 16
    call    fmt_reset
    lea     rdi, [rip+k_wind]
    call    fmt_str
    xor     ebx, ebx
1:  lea     rax, [rip+sm_wind]
    movss   xmm0, [rax+rbx*4]
    call    put_num6
    mov     edi, ' '
    call    fmt_char
    inc     ebx
    cmp     ebx, 3
    jb      1b
    lea     rdi, [rip+k_substeps]
    call    fmt_str
    mov     edi, [rip+sm_sub]
    call    fmt_int
    call    arg_from_fmt
    lea     rdi, [rip+do_cl_world]
    call    exec_arg
    add     rsp, 16
    pop     rbx
    ret

budget_cb:                              # sim.cache budget n
    sub     rsp, 8
    call    fmt_reset
    lea     rdi, [rip+k_budget]
    call    fmt_str
    mov     edi, [rip+sm_budget]
    call    fmt_int
    call    arg_from_fmt
    lea     rdi, [rip+op_sim_cache]
    lea     rsi, [rip+sm_arg]
    call    run_arg_s
    add     rsp, 8
    ret

# put_num6(xmm0) - appends the number with up to six decimals
put_num6:
    sub     rsp, 40
    lea     rsi, [rsp]
    mov     edi, 6
    call    wg_ftoa
    mov     byte ptr [rax], 0
    lea     rdi, [rsp]
    call    fmt_str
    add     rsp, 40
    ret

arg_from_fmt:                           # sm_arg = fmt_buf
    lea     rsi, [rip+fmt_buf]
    lea     rdi, [rip+sm_arg]
    mov     ecx, 128
    rep     movsb
    ret

.section .note.GNU-stack,"",@progbits
