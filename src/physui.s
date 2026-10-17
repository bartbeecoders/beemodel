# =============================================================================
#  BeeModel - the Physics section of the Properties area.
#
#  For the active mesh object: "+ Rigid Body" when it is not one; else its
#  type (Active / Passive) and shape (box, sphere, capsule, hull, compound)
#  as buttons that step through them, its mass, friction, bounce and
#  damping as fields to drag, x to remove it; its joints (x removes one);
#  the world (gravity, steps a second, solver iterations, substeps); while the
#  simulation runs, what it is doing.
#
#  Hit codes carry 0x80000 (mods.s passes them here): | 0x10000 a button
#  (id | index << 8), | 0x20000 a field (its number).
# =============================================================================
.intel_syntax noprefix
.include "const.inc"

.globl rb_props_draw
.globl rb_props_hit
.globl rb_drag_begin
.globl rb_drag_move
.globl rb_get

.equ RB_UID,    0
.equ RB_TYPE,   4
.equ RB_SHAPE,  8
.equ RB_MASS,   12
.equ RB_FLAGS,  28
.equ RW_GRAV,   0
.equ RW_RATE,   12
.equ RW_ITER,   16
.equ RW_SUB,    24
.equ RW_SET,    20
.equ JT_TYPE,   0
.equ JT_A,      4
.equ JT_B,      8
.equ PB_ADD,    1                       # buttons
.equ PB_REMOVE, 2
.equ PB_TYPE,   3
.equ PB_SHAPE,  4
.equ PB_JOINT,  5                       # (| the joint << 8)
.equ PF_MASS,   0                       # fields: body values 0-3,
.equ PF_GRAV,   4                       #  the world's
.equ PF_RATE,   5
.equ PF_ITER,   6
.equ PF_SUB,    7
.equ NFIELD,    8
.equ MAXBTN,    16
.equ MAXROW,    12

.section .rodata
.align 4
pf_step:        .float 0.02, 0.005, 0.005, 0.005, 0.02, 0.5, 0.1, 0.05
pf_max:         .float 1e6, 2.0, 1.0, 10.0, 1e3, 1000.0, 200.0, 64.0
pf_min:         .float 0.001, 0.0, 0.0, 0.0, -1e3, 1.0, 1.0, 1.0
pf_g:           .float -9.81
pf_120:         .float 120.0
pf_10:          .float 10.0
pf_4:           .float 4.0
s_physics:      .asciz "Physics"
s_add_rb:       .asciz "+ Rigid Body"
s_x:            .asciz "x"
s_active:       .asciz "Active"
s_passive:      .asciz "Passive"
s_l_body:       .asciz "Body"
s_l_mass:       .asciz "Mass"
s_l_fric:       .asciz "Friction"
s_l_bounce:     .asciz "Bounce"
s_l_damp:       .asciz "Damping"
s_l_joint:      .asciz "Joint"
s_l_world:      .asciz "World"
s_l_grav:       .asciz "Gravity"
s_l_rate:       .asciz "Steps / s"
s_l_iter:       .asciz "Iterations"
s_l_sub:        .asciz "Substeps"
s_l_sim:        .asciz "Simulation"
s_to:           .asciz " to "
s_world:        .asciz "world"
s_bodies:       .asciz " bodies, "
s_awake:        .asciz " awake, "
s_ms:           .asciz " ms"
s_undo:         .asciz "Physics"
.align 8
shape_lbl:      .quad sh_box, sh_sphere, sh_capsule, sh_hull, sh_compound
sh_box:         .asciz "Box"
sh_sphere:      .asciz "Sphere"
sh_capsule:     .asciz "Capsule"
sh_hull:        .asciz "Convex Hull"
sh_compound:    .asciz "Compound"
jt_lbl:         .quad sh_box, jt_fixed, jt_hinge, jt_point
jt_fixed:       .asciz "Fixed"
jt_hinge:       .asciz "Hinge"
jt_point:       .asciz "Point"
fld_lbl:        .quad s_l_mass, s_l_fric, s_l_bounce, s_l_damp

.section .bss
.align 4
rp_nbtn:        .skip 4
rp_btn:         .skip 16*MAXBTN         # code, x, y, w
rp_nrow:        .skip 4
rp_row:         .skip 8*MAXROW          # field, y
rp_code:        .skip 4                 # the field dragged,
rp_x0:          .skip 4                 #  from where,
rp_v0:          .skip 4                 #  its value then
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
1:  cmp     r13d, 6
    jae     8f
    lea     rax, [rip+get_names]
    mov     rsi, [rax+r13*8]
    mov     rdi, r12
    call    str_eq
    test    eax, eax
    jnz     2f
    inc     r13d
    jmp     1b
2:  cmp     r13d, 2
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
get_names:      .quad g_type, g_shape, s_g_mass, g_fric, g_bounce, g_damp
g_type:         .asciz "type"
g_shape:        .asciz "shape"
s_g_mass:       .asciz "mass"
g_fric:         .asciz "friction"
g_bounce:       .asciz "bounce"
g_damp:         .asciz "damping"
.text

# ---- drawing ---------------------------------------------------------------------
# rp_button(edi=code, esi=x, edx=y, ecx=w, r8=label) - drawn, and hit later
rp_button:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     eax, [rip+rp_nbtn]
    cmp     eax, MAXBTN
    jae     1f
    shl     eax, 4
    lea     r9, [rip+rp_btn]
    mov     [r9+rax], edi
    mov     [r9+rax+4], esi
    mov     [r9+rax+8], edx
    mov     [r9+rax+12], ecx
    inc     dword ptr [rip+rp_nbtn]
1:  mov     ebx, esi
    mov     r12d, edx
    mov     r13d, ecx
    mov     r14, r8
    mov     edi, ebx
    lea     esi, [r12-2]
    mov     edx, r13d
    mov     ecx, 18
    mov     r8d, COL_FIELD
    call    fill_rect
    lea     edi, [rbx+5]
    mov     esi, r12d
    mov     rdx, r14
    mov     ecx, COL_TEXT
    call    draw_text
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# rp_label(edi=y, rsi=label) - dim, on the left
rp_label:
    mov     edx, edi
    mov     rax, rsi
    mov     edi, [rip+ed_x]
    add     edi, 18
    mov     esi, edx
    mov     rdx, rax
    mov     ecx, COL_TEXT_DIM
    jmp     draw_text

# rp_field(edi=field, esi=y) - a field's background and value (fmt_buf),
#   and its row to hit
rp_field:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     ebx, edi
    mov     r12d, esi
    mov     edi, [rip+ed_x]
    add     edi, 110
    lea     esi, [r12-2]
    mov     edx, [rip+ed_w]
    sub     edx, 124
    mov     ecx, 18
    mov     r8d, COL_FIELD
    call    fill_rect
    mov     edi, [rip+ed_x]
    add     edi, 116
    mov     esi, r12d
    lea     rdx, [rip+fmt_buf]
    mov     ecx, COL_TEXT
    call    draw_text
    mov     eax, [rip+rp_nrow]
    cmp     eax, MAXROW
    jae     9f
    lea     rcx, [rip+rp_row]
    mov     [rcx+rax*8], ebx
    lea     edx, [r12-2]
    mov     [rcx+rax*8+4], edx
    inc     dword ptr [rip+rp_nrow]
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# rp_value(edi=field, rsi=block, rdx=entry) -> xmm0 = what the field shows
rp_value:
    cmp     edi, PF_GRAV
    jae     1f
    movss   xmm0, [rdx+RB_MASS+rdi*4]
    ret
1:  lea     rcx, [rsi+AN_RW_]
    cmp     edi, PF_GRAV
    jne     2f
    movss   xmm0, [rip+pf_g]            # (not set: the default)
    cmp     dword ptr [rcx+RW_SET], 0
    je      9f
    movss   xmm0, [rcx+RW_GRAV+4]
    ret
2:  cmp     edi, PF_RATE
    jne     3f
    movss   xmm0, [rip+pf_120]
    cmp     dword ptr [rcx+RW_RATE], 0
    je      9f
    cvtsi2ss xmm0, dword ptr [rcx+RW_RATE]
    ret
3:  cmp     edi, PF_SUB
    je      4f
    movss   xmm0, [rip+pf_10]
    cmp     dword ptr [rcx+RW_ITER], 0
    je      9f
    cvtsi2ss xmm0, dword ptr [rcx+RW_ITER]
    ret
4:  movss   xmm0, [rip+pf_4]
    cmp     dword ptr [rcx+RW_SUB], 0
    je      9f
    cvtsi2ss xmm0, dword ptr [rcx+RW_SUB]
9:  ret

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
    mov     dword ptr [rip+rp_nbtn], 0
    mov     dword ptr [rip+rp_nrow], 0
    call    rp_obj
    test    rax, rax
    jz      .Lpd_out
    mov     rbx, rax                    # the object
    add     r12d, 8
    mov     edi, [rip+ed_x]             # "Physics"
    add     edi, 14
    mov     esi, r12d
    lea     rdx, [rip+s_physics]
    mov     ecx, COL_ACCENT
    call    draw_heading
    mov     r14, [rip+an_cur]           # the block (0: none yet)
    mov     rdi, r14
    mov     esi, [rbx+OB_UID]
    call    rp_entry
    mov     r13, rax
    test    r13, r13
    jnz     1f
    mov     edi, PB_ADD|0x10000         # not a body: + Rigid Body
    mov     esi, [rip+ed_x]
    add     esi, [rip+ed_w]
    sub     esi, 118
    mov     edx, r12d
    mov     ecx, 104
    lea     r8, [rip+s_add_rb]
    call    rp_button
    add     r12d, 26
    jmp     .Lpd_out
1:  mov     edi, PB_REMOVE|0x10000      # x
    mov     esi, [rip+ed_x]
    add     esi, [rip+ed_w]
    sub     esi, 36
    mov     edx, r12d
    mov     ecx, 22
    lea     r8, [rip+s_x]
    call    rp_button
    add     r12d, 24
    mov     edi, r12d                   # Body: [Active] [Box]
    lea     rsi, [rip+s_l_body]
    call    rp_label
    mov     ebp, [rip+ed_w]
    sub     ebp, 128
    shr     ebp, 1                      # each button's width
    lea     r8, [rip+s_active]
    cmp     dword ptr [r13+RB_TYPE], 2
    jne     11f
    lea     r8, [rip+s_passive]
11: mov     edi, PB_TYPE|0x10000
    mov     esi, [rip+ed_x]
    add     esi, 110
    mov     edx, r12d
    mov     ecx, ebp
    call    rp_button
    mov     eax, [r13+RB_SHAPE]
    cmp     eax, 4
    jbe     12f
    xor     eax, eax
12: lea     rcx, [rip+shape_lbl]
    mov     r8, [rcx+rax*8]
    mov     edi, PB_SHAPE|0x10000
    mov     esi, [rip+ed_x]
    add     esi, 114
    add     esi, ebp
    mov     edx, r12d
    mov     ecx, ebp
    call    rp_button
    add     r12d, 22
    xor     r15d, r15d                  # mass, friction, bounce, damping
2:  cmp     r15d, 4
    jae     3f
    lea     rax, [rip+fld_lbl]
    mov     rsi, [rax+r15*8]
    mov     edi, r12d
    call    rp_label
    mov     edi, r15d
    mov     rsi, r14
    mov     rdx, r13
    call    rp_value
    call    fmt_reset
    call    fmt_val3
    mov     edi, r15d
    mov     esi, r12d
    call    rp_field
    add     r12d, 20
    inc     r15d
    jmp     2b
3:  xor     r15d, r15d                  # its joints: Hinge to world  x
4:  cmp     r15d, [r14+AN_NJT_]
    jae     5f
    imul    rax, r15, JT_SZ_
    lea     rcx, [r14+AN_JT_+rax]
    mov     eax, [rbx+OB_UID]
    cmp     [rcx+JT_A], eax
    je      41f
    cmp     [rcx+JT_B], eax
    jne     45f
41: mov     [rsp], rcx
    mov     edi, r12d
    lea     rsi, [rip+s_l_joint]
    call    rp_label
    call    fmt_reset
    mov     rcx, [rsp]
    mov     eax, [rcx+JT_TYPE]
    and     eax, 3
    lea     rdx, [rip+jt_lbl]
    mov     rdi, [rdx+rax*8]
    call    fmt_str
    lea     rdi, [rip+s_to]
    call    fmt_str
    mov     rcx, [rsp]                  # the other one
    mov     edi, [rcx+JT_B]
    mov     eax, [rbx+OB_UID]
    cmp     edi, eax
    jne     42f
    mov     edi, [rcx+JT_A]
42: lea     rdx, [rip+s_world]
    test    edi, edi
    jz      43f
    call    obj_by_uid
    lea     rdx, [rip+s_world]
    test    rax, rax
    jz      43f
    lea     rdx, [rax+OB_NAME]
43: mov     rdi, rdx
    call    fmt_str
    mov     edi, [rip+ed_x]
    add     edi, 116
    mov     esi, r12d
    lea     rdx, [rip+fmt_buf]
    mov     ecx, COL_TEXT
    call    draw_text
    mov     edi, r15d
    shl     edi, 8
    or      edi, PB_JOINT|0x10000
    mov     esi, [rip+ed_x]
    add     esi, [rip+ed_w]
    sub     esi, 36
    mov     edx, r12d
    mov     ecx, 22
    lea     r8, [rip+s_x]
    call    rp_button
    add     r12d, 20
45: inc     r15d
    jmp     4b
5:  add     r12d, 4                     # the world
    mov     edi, r12d
    lea     rsi, [rip+s_l_world]
    call    rp_label
    add     r12d, 20
    mov     r15d, PF_GRAV
6:  cmp     r15d, NFIELD
    jae     7f
    lea     rax, [rip+world_lbl]
    mov     rsi, [rax+r15*8-PF_GRAV*8]
    mov     edi, r12d
    call    rp_label
    mov     edi, r15d
    mov     rsi, r14
    mov     rdx, r13
    call    rp_value
    call    fmt_reset
    cmp     r15d, PF_GRAV
    jne     61f
    call    fmt_val3
    jmp     62f
61: cvttss2si edi, xmm0
    call    fmt_int
62: mov     edi, r15d
    mov     esi, r12d
    call    rp_field
    add     r12d, 20
    inc     r15d
    jmp     6b
7:  xor     edi, edi                    # running: what it is doing
    call    rb_info
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    jbe     8f
    mov     edi, r12d
    lea     rsi, [rip+s_l_sim]
    call    rp_label
    call    fmt_reset
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
    mov     edi, [rip+ed_x]
    add     edi, 116
    mov     esi, r12d
    lea     rdx, [rip+fmt_buf]
    mov     ecx, COL_TEXT_DIM
    call    draw_text
    add     r12d, 20
8:  add     r12d, 6
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

.section .rodata
.align 8
world_lbl:      .quad s_l_grav, s_l_rate, s_l_iter, s_l_sub
.text

# ---- hits ------------------------------------------------------------------------
# rb_props_hit(edi=x, esi=y) -> eax = code | 0x80000, or -1
rb_props_hit:
    xor     ecx, ecx
1:  cmp     ecx, [rip+rp_nbtn]
    jae     3f
    lea     rdx, [rip+rp_btn]
    mov     eax, ecx
    shl     eax, 4
    add     rdx, rax
    mov     eax, edi
    sub     eax, [rdx+4]
    js      2f
    cmp     eax, [rdx+12]
    jge     2f
    mov     eax, esi
    sub     eax, [rdx+8]
    add     eax, 2
    js      2f
    cmp     eax, 18
    jge     2f
    mov     eax, [rdx]
    or      eax, 0x80000
    ret
2:  inc     ecx
    jmp     1b
3:  mov     eax, [rip+ed_x]             # fields
    add     eax, 110
    cmp     edi, eax
    jl      8f
    xor     ecx, ecx
4:  cmp     ecx, [rip+rp_nrow]
    jae     8f
    lea     rdx, [rip+rp_row]
    mov     eax, esi
    sub     eax, [rdx+rcx*8+4]
    js      5f
    cmp     eax, 18
    jge     5f
    mov     eax, [rdx+rcx*8]
    or      eax, 0xA0000
    ret
5:  inc     ecx
    jmp     4b
8:  mov     eax, -1
    ret

# rp_own -> rbx = the block, ready to change (an undo step first); r13 =
#   the active object's entry (0: none), r12 = the object
rp_own:
    sub     rsp, 8
    lea     rdi, [rip+s_undo]
    call    undo_push
    xor     edi, edi
    call    an_own_g
    mov     rbx, rax
    call    rp_obj
    mov     r12, rax
    xor     r13d, r13d
    test    rax, rax
    jz      9f
    mov     rdi, rbx
    mov     esi, [r12+OB_UID]
    call    rp_entry
    mov     r13, rax
9:  add     rsp, 8
    ret

# rb_drag_begin(edi=code) - buttons act; fields start a drag
rb_drag_begin:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r14d, edi
    test    r14d, 0x10000
    jz      .Lpb_field
    call    rp_own
    test    rbx, rbx
    jz      .Lpb_out
    test    r12, r12
    jz      .Lpb_out
    mov     eax, r14d
    and     eax, 0xff
    cmp     eax, PB_ADD
    jne     2f
    test    r13, r13                    # a new entry: active, a box
    jnz     .Lpb_done
    mov     eax, [rbx+AN_NRB_]
    cmp     eax, RB_MAX_
    jae     .Lpb_done
    inc     dword ptr [rbx+AN_NRB_]
    imul    rdi, rax, RB_SZ_
    lea     rdi, [rbx+AN_RB_+rdi]
    mov     r13, rdi
    xor     eax, eax
    mov     ecx, RB_SZ_
    rep     stosb
    mov     eax, [r12+OB_UID]
    mov     [r13+RB_UID], eax
    mov     dword ptr [r13+RB_TYPE], 1
    mov     eax, 0x3f800000             # mass 1, friction 0.5
    mov     [r13+RB_MASS], eax
    mov     eax, 0x3f000000
    mov     [r13+RB_MASS+4], eax
    jmp     .Lpb_done
2:  test    r13, r13
    jz      .Lpb_done
    cmp     eax, PB_TYPE
    jne     3f
    mov     eax, [r13+RB_TYPE]          # active <-> passive
    xor     eax, 3
    mov     [r13+RB_TYPE], eax
    jmp     .Lpb_done
3:  cmp     eax, PB_SHAPE
    jne     4f
    mov     eax, [r13+RB_SHAPE]         # the next shape
    inc     eax
    cmp     eax, 5
    jb      31f
    xor     eax, eax
31: mov     [r13+RB_SHAPE], eax
    jmp     .Lpb_done
4:  cmp     eax, PB_REMOVE
    jne     5f
    call    rb_back                     # (the objects back at the start first)
    mov     r15d, [r12+OB_UID]
    mov     ecx, [rbx+AN_NRB_]          # the entry: the last into its place
    dec     ecx
    mov     [rbx+AN_NRB_], ecx
    imul    rsi, rcx, RB_SZ_
    lea     rsi, [rbx+AN_RB_+rsi]
    mov     rdi, r13
    mov     ecx, RB_SZ_
    rep     movsb
    xor     ecx, ecx                    # its joints go too
41: cmp     ecx, [rbx+AN_NJT_]
    jae     .Lpb_done
    imul    rdi, rcx, JT_SZ_
    lea     rdi, [rbx+AN_JT_+rdi]
    cmp     [rdi+JT_A], r15d
    je      42f
    cmp     [rdi+JT_B], r15d
    jne     43f
42: mov     esi, ecx
    call    rp_joint_del
    jmp     41b
43: inc     ecx
    jmp     41b
5:  cmp     eax, PB_JOINT               # one joint
    jne     .Lpb_done
    call    rb_back
    mov     esi, r14d
    shr     esi, 8
    and     esi, 0xff
    cmp     esi, [rbx+AN_NJT_]
    jae     .Lpb_done
    call    rp_joint_del
.Lpb_done:
    mov     dword ptr [rip+dirty], 1
    jmp     .Lpb_out
.Lpb_field:                             # a field: its value now
    mov     eax, r14d
    and     eax, 0xff
    cmp     eax, NFIELD
    jae     .Lpb_out
    mov     [rip+rp_code], eax
    mov     eax, [rip+ptr_x]
    mov     [rip+rp_x0], eax
    call    rp_own
    test    rbx, rbx
    jz      .Lpb_out
    mov     edi, [rip+rp_code]
    cmp     edi, PF_GRAV
    jae     6f
    test    r13, r13
    jz      .Lpb_out
6:  mov     rsi, rbx
    mov     rdx, r13
    call    rp_value
    movss   [rip+rp_v0], xmm0
.Lpb_out:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# rp_joint_del(rbx=block, esi=joint) - it goes, the last into its place
#   (ecx kept)
rp_joint_del:
    push    rcx
    mov     eax, [rbx+AN_NJT_]
    dec     eax
    mov     [rbx+AN_NJT_], eax
    imul    rdi, rsi, JT_SZ_
    lea     rdi, [rbx+AN_JT_+rdi]
    imul    rsi, rax, JT_SZ_
    lea     rsi, [rbx+AN_JT_+rsi]
    mov     ecx, JT_SZ_
    rep     movsb
    pop     rcx
    ret

# rb_back - no simulation: objects back where they began (before removing)
rb_back:
    sub     rsp, 8
    xorps   xmm0, xmm0                  # (frame 0: at or before any start)
    call    rb_frame
    add     rsp, 8
    ret

# rb_drag_move(edi=x logical) - the field: its value then + the drag
rb_drag_move:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 16
    sub     edi, [rip+rp_x0]
    cvtsi2ss xmm0, edi
    mov     ecx, [rip+rp_code]
    lea     rax, [rip+pf_step]
    mulss   xmm0, [rax+rcx*4]
    addss   xmm0, [rip+rp_v0]
    lea     rax, [rip+pf_max]
    minss   xmm0, [rax+rcx*4]
    lea     rax, [rip+pf_min]
    maxss   xmm0, [rax+rcx*4]
    movss   [rsp], xmm0
    xor     edi, edi
    call    an_own_g
    test    rax, rax
    jz      9f
    mov     rbx, rax
    mov     ecx, [rip+rp_code]
    cmp     ecx, PF_GRAV
    jae     2f
    call    rp_obj
    test    rax, rax
    jz      9f
    mov     rdi, rbx
    mov     esi, [rax+OB_UID]
    call    rp_entry
    test    rax, rax
    jz      9f
    mov     ecx, [rip+rp_code]
    movss   xmm0, [rsp]
    movss   [rax+RB_MASS+rcx*4], xmm0
    jmp     8f
2:  lea     rdx, [rbx+AN_RW_]
    movss   xmm0, [rsp]
    cmp     ecx, PF_GRAV
    jne     3f
    cmp     dword ptr [rdx+RW_SET], 0   # (gravity set: straight down, this much)
    jne     21f
    mov     qword ptr [rdx+RW_GRAV], 0
    mov     dword ptr [rdx+RW_GRAV+8], 0
    mov     dword ptr [rdx+RW_SET], 1
21: movss   [rdx+RW_GRAV+4], xmm0
    jmp     8f
3:  cvtss2si eax, xmm0
    cmp     ecx, PF_RATE
    jne     4f
    mov     [rdx+RW_RATE], eax
    jmp     8f
4:  cmp     ecx, PF_SUB
    jne     5f
    mov     [rdx+RW_SUB], eax
    jmp     8f
5:  mov     [rdx+RW_ITER], eax
8:  mov     dword ptr [rip+dirty], 1
9:  add     rsp, 16
    pop     r13
    pop     r12
    pop     rbx
    ret

.section .note.GNU-stack,"",@progbits
