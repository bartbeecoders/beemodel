# =============================================================================
#  BeeModel - Properties › Physics for a force field (A1): a Force Field
#  section (its type, on, strength, falloff and reach, the type's own
#  values, the collision group it acts on), then the World section
#  (physui.s). Values come from the field's record each frame into fu_rec;
#  a change writes fu_rec back into the owned record (after the widget's
#  undo step).
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"
.include "widgets.inc"

.globl fl_props

.section .bss
.align 8
fu_rec:         .skip FF_SZ             # the field's values, as shown
.align 4
fu_on:          .skip 4
fu_grp:         .skip 4                 # -1: every group

.section .rodata
s_c_type:       .asciz "Type"
s_c_fall:       .asciz "Falloff"
s_c_law:        .asciz "Pull"
s_c_shape:      .asciz "Shape"
t_attr:         .asciz "Pulls things towards it."
t_zone:         .asciz "Inside, down is its -Y."
t_wind:         .asciz "Blows along its +X."
t_vortex:       .asciz "Turns things round its +Y."
t_turb:         .asciz "Swirls things about."
t_drag:         .asciz "Slows things down."
l_none:         .asciz "None"
l_radius:       .asciz "Radius"
l_smooth:       .asciz "Smooth"
l_square:       .asciz "1 / d^2"
l_lin:          .asciz "1 / d"
l_box:          .asciz "Box"
l_sphere:       .asciz "Sphere"
.align 8
fu_tips:        .quad t_attr, t_zone, t_wind, t_vortex, t_turb, t_drag
fu_falls:       .quad l_none, l_radius, l_smooth
fu_laws:        .quad l_square, l_lin
fu_shapes:      .quad l_box, l_sphere

.text
WIDGET wd_fl_sect,  WK_SECTION, "physics.section.field", "Force Field"
WIDGET wd_fl_type,  WK_ENUM, "field.type", cb=ftype_cb, undo="Field", aux=fl_tnames, n=6, tip="What it does: pull, a zone with its own down, wind, a vortex, turbulence or drag"
WIDGET wd_fl_on,    WK_TOGGLE, "field.enabled", "On", cb=fval_cb, undo="Field", tip="Off: nothing feels it"
WIDGET wd_fl_str,   WK_FLOAT, "field.strength", "Strength", -1000000.0, 1000000.0, 0.05, 2, WGF_CLAMP, cb=fval_cb, undo="Field", tip="How hard it acts (m/s2: an attractor's pull at 1 m, a zone's gravity, wind's push). Keyframe it as field:Name:strength"
WIDGET wd_fl_fall,  WK_ENUM, "field.falloff", cb=fval_cb, undo="Field", aux=fu_falls, n=3, tip="How it fades: not at all, stopping at the radius, or smoothly to the radius"
WIDGET wd_fl_rad,   WK_FLOAT, "field.radius", "Radius (m)", 0.01, 100000.0, 0.05, 2, WGF_CLAMP, cb=fval_cb, undo="Field", tip="Its reach (times the object's scale)"
WIDGET wd_fl_size,  WK_FLOAT, "field.radius", "Half size (m)", 0.01, 100000.0, 0.05, 2, WGF_CLAMP, cb=fval_cb, undo="Field", tip="The zone's half size (times the object's scale): a box or a sphere's radius"
WIDGET wd_fl_law,   WK_ENUM, "field.law", cb=fval_cb, undo="Field", aux=fu_laws, n=2, tip="Inverse square: like gravity (orbits). 1 / distance: a gentler pull"
WIDGET wd_fl_soft,  WK_FLOAT, "field.soft", "Soft core (m)", 0.0, 1000.0, 0.01, 2, WGF_CLAMP, cb=fval_cb, undo="Field", tip="Near the centre the pull softens over this distance (no infinite pull)"
WIDGET wd_fl_shape, WK_ENUM, "field.shape", cb=fval_cb, undo="Field", aux=fu_shapes, n=2, tip="The zone's shape"
WIDGET wd_fl_gust,  WK_SLIDER, "field.gust", "Gusts", 0.0, 1.0, 0.01, 2, cb=fval_cb, undo="Field", tip="How much the wind rises and falls"
WIDGET wd_fl_lift,  WK_FLOAT, "field.lift", "Lift", -1000000.0, 1000000.0, 0.05, 2, WGF_CLAMP, cb=fval_cb, undo="Field", tip="A pull along its axis (a tornado lifts)"
WIDGET wd_fl_inflow, WK_FLOAT, "field.inflow", "Inflow", -1000000.0, 1000000.0, 0.05, 2, WGF_CLAMP, cb=fval_cb, undo="Field", tip="A pull towards its axis"
WIDGET wd_fl_scale, WK_FLOAT, "field.scale", "Swirl size (m)", 0.01, 10000.0, 0.05, 2, WGF_CLAMP, cb=fval_cb, undo="Field", tip="How large its swirls are"
WIDGET wd_fl_seed,  WK_INT, "field.seed", "Seed", 0.0, 100000.0, 0.1, 0, WGF_CLAMP, cb=fval_cb, undo="Field", tip="Another pattern (turbulence, gusts)"
WIDGET wd_fl_grp,   WK_INT, "field.group", "Only group (-1: all)", -1.0, 15.0, 0.1, 0, WGF_CLAMP, cb=fval_cb, undo="Field", def=-1.0, tip="The collision group it acts on, or -1 for every group (cloth and particles are group 0)"

# fu_own -> rax = the active field's record, writable (0: none)
fu_own:
    sub     rsp, 8
    call    fl_active
    test    rax, rax
    jz      9f
    mov     edi, [rax+OB_UID]
    mov     esi, [rdx+FF_TYPE]
    call    fl_rec_own
9:  add     rsp, 8
    ret

# the callbacks: fu_rec into the record
fval_cb:
    sub     rsp, 8
    call    fu_own
    test    rax, rax
    jz      9f
    mov     ecx, [rax+FF_TYPE]          # (the type stays: ftype_cb sets it)
    lea     rsi, [rip+fu_rec+FF_STR]
    lea     rdi, [rax+FF_STR]
    push    rcx
    push    rax
    mov     ecx, FF_SZ-FF_STR
    rep     movsb
    pop     rax
    pop     rcx
    mov     [rax+FF_TYPE], ecx
    mov     ecx, [rip+fu_grp]           # the group it acts on
    xor     edx, edx
    test    ecx, ecx
    js      1f
    mov     edx, 0xffff
    btr     edx, ecx
1:  mov     [rax+FF_SKIP], edx
    and     dword ptr [rax+FF_FLAGS], ~1
    cmp     dword ptr [rip+fu_on], 0
    jne     2f
    or      dword ptr [rax+FF_FLAGS], 1
2:  mov     dword ptr [rip+dirty], 1
9:  add     rsp, 8
    ret
ftype_cb:                               # another type: its defaults
    sub     rsp, 8
    call    fu_own
    test    rax, rax
    jz      9f
    mov     ecx, [rax+FF_FLAGS]
    push    rcx
    push    rax
    mov     rdi, rax
    mov     esi, [rip+fu_rec+FF_TYPE]
    call    fl_set_type
    pop     rax
    pop     rcx
    mov     [rax+FF_FLAGS], ecx
    mov     dword ptr [rip+dirty], 1
9:  add     rsp, 8
    ret

# fu_cap(rdi=desc, r8=ptr, rdx=caption) - caption left, the field right
fu_cap:
    push    rbx
    push    r13
    sub     rsp, 8
    mov     rbx, rdi
    mov     r13, r8
    call    pnl_caption
    mov     rdi, rbx
    mov     r8, r13
    call    pnl_right
    add     r12d, WG_H+4
    add     rsp, 8
    pop     r13
    pop     rbx
    ret

# fl_props(edi=y) -> eax = y below: the active field's section (pnl_begin
#   done)
fl_props:
    push    rbx
    push    r12
    push    r13
    mov     r12d, edi
    call    fl_active
    test    rax, rax
    jz      .Lfu_out
    lea     rdi, [rip+fu_rec]           # its values, as they are
    mov     rsi, rdx
    mov     ecx, FF_SZ
    rep     movsb
    mov     ecx, [rip+fu_rec+FF_FLAGS]
    not     ecx
    and     ecx, 1
    mov     [rip+fu_on], ecx
    mov     ecx, [rip+fu_rec+FF_SKIP]
    mov     eax, -1
    test    ecx, ecx
    jz      1f
    not     ecx
    and     ecx, 0xffff
    bsf     eax, ecx
    jnz     1f
    mov     eax, -1
1:  mov     [rip+fu_grp], eax
    mov     ebx, [rip+fu_rec+FF_TYPE]
    cmp     ebx, FLD_N
    jb      2f
    xor     ebx, ebx
2:  lea     rdi, [rip+wd_fl_sect]
    mov     esi, [rip+pnl_x]
    sub     esi, 6
    mov     ecx, [rip+pnl_w]
    add     ecx, 12
    mov     edx, r12d
    xor     r8d, r8d
    xor     r9d, r9d
    call    wg
    add     r12d, 28
    test    eax, eax
    jz      .Lfu_out
    lea     rax, [rip+fu_tips]
    mov     rdx, [rax+rbx*8]
    call    pnl_hint
    add     r12d, 4
    lea     rdi, [rip+wd_fl_type]
    lea     r8, [rip+fu_rec+FF_TYPE]
    lea     rdx, [rip+s_c_type]
    call    fu_cap
    lea     rdi, [rip+wd_fl_on]
    lea     r8, [rip+fu_on]
    call    pnl_full
    lea     rdi, [rip+wd_fl_str]
    lea     r8, [rip+fu_rec+FF_STR]
    call    pnl_full
    cmp     ebx, FLD_ZONE
    jne     3f
    lea     rdi, [rip+wd_fl_shape]      # a zone: its shape and size
    lea     r8, [rip+fu_rec+FF_LAW]
    lea     rdx, [rip+s_c_shape]
    call    fu_cap
    lea     rdi, [rip+wd_fl_size]
    lea     r8, [rip+fu_rec+FF_RAD]
    call    pnl_full
    jmp     .Lfu_grp
3:  lea     rdi, [rip+wd_fl_fall]
    lea     r8, [rip+fu_rec+FF_FALL]
    lea     rdx, [rip+s_c_fall]
    call    fu_cap
    cmp     dword ptr [rip+fu_rec+FF_FALL], 0
    je      4f
    lea     rdi, [rip+wd_fl_rad]
    lea     r8, [rip+fu_rec+FF_RAD]
    call    pnl_full
4:  cmp     ebx, FLD_ATTR
    jne     5f
    lea     rdi, [rip+wd_fl_law]
    lea     r8, [rip+fu_rec+FF_LAW]
    lea     rdx, [rip+s_c_law]
    call    fu_cap
    lea     rdi, [rip+wd_fl_soft]
    lea     r8, [rip+fu_rec+FF_SOFT]
    call    pnl_full
    jmp     .Lfu_grp
5:  cmp     ebx, FLD_WIND
    jne     6f
    lea     rdi, [rip+wd_fl_gust]
    lea     r8, [rip+fu_rec+FF_GUST]
    call    pnl_full
    lea     rdi, [rip+wd_fl_seed]
    lea     r8, [rip+fu_rec+FF_SEED]
    call    pnl_full
    jmp     .Lfu_grp
6:  cmp     ebx, FLD_VORTEX
    jne     7f
    lea     rdi, [rip+wd_fl_lift]
    lea     r8, [rip+fu_rec+FF_LIFT]
    call    pnl_full
    lea     rdi, [rip+wd_fl_inflow]
    lea     r8, [rip+fu_rec+FF_INFLOW]
    call    pnl_full
    jmp     .Lfu_grp
7:  cmp     ebx, FLD_TURB
    jne     .Lfu_grp
    lea     rdi, [rip+wd_fl_scale]
    lea     r8, [rip+fu_rec+FF_SCALE]
    call    pnl_full
    lea     rdi, [rip+wd_fl_seed]
    lea     r8, [rip+fu_rec+FF_SEED]
    call    pnl_full
.Lfu_grp:
    lea     rdi, [rip+wd_fl_grp]
    lea     r8, [rip+fu_grp]
    call    pnl_full
    add     r12d, 6
.Lfu_out:
    mov     eax, r12d
    pop     r13
    pop     r12
    pop     rbx
    ret

.section .note.GNU-stack,"",@progbits
