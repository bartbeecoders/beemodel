# =============================================================================
#  BeeModel - force fields (stage A1): objects that push and pull.
#
#  Add › Force Field › makes an object of type OT_FIELD (drawn as a small
#  wire octahedron, like a light, with its own gizmo):
#    Attractor     pulls towards its centre: strength / d^2 (softened near
#                  the centre: s d / (d^2 + soft^2)^1.5), or strength / d;
#                  a negative strength pushes away.
#    Gravity zone  a box (its half size: radius x the object's scale) or a
#                  sphere inside which "down" is the object's -Y at this
#                  strength, instead of the world's gravity.
#    Wind          along the object's +X, with gusts (0..1). Bodies feel it
#                  as this acceleration; cloth as air of this speed (m/s).
#    Vortex        turns things round the object's +Y: strength along the
#                  tangent, lift along the axis, inflow towards it.
#    Turbulence    curl noise (swirls this many metres across).
#    Drag          -strength x velocity.
#  Every field has a falloff (none; radius: stops at it; smooth: (1 -
#  (d/r)^2)^2), a strength that can be keyframed (field:<name>:strength),
#  collision groups it leaves alone, and can be switched off.
#
#  The settings are one block of records by object uid, reference counted
#  and copied on write like the light settings (undo.s ST_FLD), kept in
#  .bee files as a FLDS chunk. The solvers call fl_prep once a step (the
#  fields as they are now: fl_tab) and fl_accel per body or particle.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

.globl fl_cur
.globl fl_ref
.globl fl_unref
.globl fl_reset
.globl fl_write
.globl fl_read
.globl fl_get
.globl fl_view
.globl fl_rec_own
.globl fl_set_type
.globl fl_copy
.globl fl_chan
.globl fl_prep
.globl fl_accel
.globl fl_wind
.globl fl_n
.globl fl_nw
.globl fl_mix
.globl fl_draw
.globl fl_tnames
.globl fl_kwtypes
.globl fl_parse
.globl fl_active
.globl fl_sample
.globl fl_time
.globl fl_show_a
.globl fl_show_l
.globl fl_info
.globl fl_type_of
.globl fl_ops
.globl do_fl_add

.equ FL_REFS,   0
.equ FL_N,      4
.equ FL_BYTES,  8
.equ FL_HDR,    32
.equ FL_MAX,    256
.equ FL_SIZE,   FL_HDR+FL_MAX*FF_SZ
.equ MAP_ANON_PRIV, 0x22
# a field as it is this step (fl_tab)
.equ FT_C,      0                       # centre
.equ FT_AX,     16                      # its axis: wind +X, else +Y (unit)
.equ FT_U,      32                      # its +X, +Z (unit)
.equ FT_V,      48
.equ FT_HS,     64                      # a box zone's half sizes
.equ FT_OFF,    80                      # turbulence: where in the noise
.equ FT_TYPE,   96
.equ FT_FALL,   100
.equ FT_STR,    104                     # (wind: with this moment's gust)
.equ FT_RAD,    108
.equ FT_LAW,    112
.equ FT_SKIP,   116
.equ FT_LIFT,   120
.equ FT_INFLOW, 124
.equ FT_SOFT2,  128
.equ FT_ISCALE, 132
.equ FT_SZ,     144
.equ FT_MAX,    64
.equ SEGS,      24
.equ FO_NX,     9                       # the overlay's grid: 9 x 5 x 9
.equ FO_NY,     5
.equ FO_N,      FO_NX*FO_NY*FO_NX
.equ FO_SEEDS,  16                      # streamlines from an object
.equ FO_STEPS,  80

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

.section .bss
.align 16
fl_tab:         .skip FT_SZ*FT_MAX
fl_g:           .skip 16                # the world's gravity (fl_prep)
fd_c:           .skip 16                # drawing: the field's centre, axes
fd_x:           .skip 16
fd_y:           .skip 16
fd_z:           .skip 16
fd_m:           .skip 48
.align 8
fl_cur:         .skip 8
.align 4
fl_n:           .skip 4                 # fields this step
fl_nw:          .skip 4                 #  of them wind
fd_col:         .skip 4
fd_k:           .skip 4                 # the icon's size (its scale)
fl_dflt:        .skip FF_SZ             # (no record: the defaults)
fo_na:          .skip 4                 # the overlay: arrows drawn,
fo_nl:          .skip 4                 #  line segments drawn,
fo_max:         .skip 4                 #  the largest pull
fo_cell:        .skip 4
.align 16
fo_c:           .skip 16                # its grid: centre, half sizes
fo_h:           .skip 16
fo_p:           .skip 16                # (a point)
fo_q:           .skip 16
fo_acc:         .skip 16*FO_N           # the pulls on the grid
.section .data
.align 4
fl_show_a:      .long 0                 # View > Force Field Arrows
fl_show_l:      .long 0                 #  ... Lines
.section .bss

.section .rodata
.align 16
fq_xyz:         .long -1, -1, -1, 0
fq_abs:         .long 0x7fffffff, 0x7fffffff, 0x7fffffff, 0x7fffffff
fq_sign:        .long 0x80000000, 0x80000000, 0x80000000, 0x80000000
.align 4
fq_one:         .float 1.0
fq_ten:         .float 10.0
fq_tiny:        .float 1.0e-6
fq_min:         .float 0.01
fq_half:        .float 0.5
fq_quarter:     .float 0.25
fq_gs:          .float 7.13
fq_g37:         .float 0.37
fq_o1:          .float 13.7
fq_o2:          .float 3.1
fq_o3:          .float 5.9
fq_2pi:         .float 6.28318531
fq_segs:        .float 24.0
fc_eps:         .float 0.01
fc_eps2:        .float 0.02
fc_inv:         .float 50.0             # 1 / (2 eps)
# curl: (potential, axis, minus, into)
fc_terms:       .byte 2, 1, 0, 0,  1, 2, 1, 0
                .byte 0, 2, 0, 1,  2, 0, 1, 1
                .byte 1, 0, 0, 2,  0, 1, 1, 2
fc_offs:        .float 0.0, 0.0, 0.0
                .float 31.416, -12.7, 47.1
                .float -19.3, 57.9, 7.3
# the defaults, per type: strength, falloff, radius, law, gust, scale, skip,
#   flags, lift, inflow, soft, seed (FF_STR on)
.macro FDEF s, fall, rad, gust=0.0
    .float \s
    .long \fall
    .float \rad
    .long 0
    .float \gust, 2.0
    .long 0, 0
    .float 0.0, 0.0, 0.1
    .long 0, 0, 0
.endm
fl_defs:        FDEF 10.0, 0, 10.0
                FDEF 9.81, 0, 2.0
                FDEF 5.0, 0, 10.0, 0.3
                FDEF 5.0, 2, 5.0
                FDEF 5.0, 0, 10.0
                FDEF 0.5, 0, 10.0
.equ FDEF_SZ,   56
# gizmo numbers
gz_a:           .float 0.45, 0.9, 0.18, 1.5, 0.4, 0.8, 0.25, 1.0, 0.3
fo_zero4:       .float 0, 0, 0, 0
fo_k:           .float 0.85                 # an arrow: at most this of a cell
fo_seed_r:      .float 0.8
fo_eps:         .float 1.0e-5

s_fl_attr:      .asciz "Attractor"
s_fl_zone:      .asciz "Gravity Zone"
s_fl_wind:      .asciz "Wind"
s_fl_vortex:    .asciz "Vortex"
s_fl_turb:      .asciz "Turbulence"
s_fl_drag:      .asciz "Drag"
k_attr:         .asciz "attractor"
k_zone:         .asciz "zone"
k_wind:         .asciz "wind"
k_vortex:       .asciz "vortex"
k_turb:         .asciz "turbulence"
k_drag:         .asciz "drag"
k_planet:       .asciz "planet"
k_hole:         .asciz "blackhole"
k_tornado:      .asciz "tornado"
k_breeze:       .asciz "breeze"
s_pr_planet:    .asciz "Planet"
s_pr_core:      .asciz "Planet Core"
s_pr_hole:      .asciz "Black Hole"
s_pr_tornado:   .asciz "Tornado"
s_pr_breeze:    .asciz "Breeze"
s_ps_planet:    .asciz "strength 981 soft 1"
s_ps_hole:      .asciz "strength 2000 soft 0.2 falloff smooth radius 8"
s_ps_tornado:   .asciz "strength 15 lift 8 inflow 4 falloff smooth radius 6"
s_ps_breeze:    .asciz "strength 2 gust 0.6"
k_none:         .asciz "none"
k_radius:       .asciz "radius"
k_smooth:       .asciz "smooth"
k_square:       .asciz "square"
k_linear:       .asciz "linear"
k_box:          .asciz "box"
k_sphere:       .asciz "sphere"
k_strength:     .asciz "strength"
k_falloff:      .asciz "falloff"
k_size:         .asciz "size"
k_law:          .asciz "law"
k_shape:        .asciz "shape"
k_gust:         .asciz "gust"
k_scale:        .asciz "scale"
k_seed:         .asciz "seed"
k_lift:         .asciz "lift"
k_inflow:       .asciz "inflow"
k_soft:         .asciz "soft"
k_groups:       .asciz "groups"
k_type:         .asciz "type"
k_on:           .asciz "on"
k_off:          .asciz "off"
k_all:          .asciz "all"
s_added:        .asciz "  added "
s_bad:          .asciz "  field: not understood: "
s_nofield:      .asciz "  select a force field first (Add > Force Field)"
.align 8
fl_tnames:      .quad s_fl_attr, s_fl_zone, s_fl_wind, s_fl_vortex, s_fl_turb, s_fl_drag
fl_kwtypes:     .quad k_attr, k_zone, k_wind, k_vortex, k_turb, k_drag
                .quad k_planet, k_hole, k_tornado, k_breeze, 0
fl_ops:         .quad op_fl_attr, op_fl_zone, op_fl_wind, op_fl_vortex, op_fl_turb, op_fl_drag
                .quad op_fl_planet, op_fl_hole, op_fl_tornado, op_fl_breeze
# presets: type, name, settings
fl_presets:     .quad FLD_ATTR, s_pr_core, s_ps_planet
                .quad FLD_ATTR, s_pr_hole, s_ps_hole
                .quad FLD_VORTEX, s_pr_tornado, s_ps_tornado
                .quad FLD_WIND, s_pr_breeze, s_ps_breeze
kw_fall:        .quad k_none, k_radius, k_smooth, 0
kw_law:         .quad k_square, k_linear, 0
kw_shape:       .quad k_box, k_sphere, 0
# field.set words: (word, offset, kind, list); kinds: 0 float, 1 whole,
#   2 one of list, 3 type, 4 groups, 5 on, 6 off
fp_tab:         .quad k_strength
                .long FF_STR, 0
                .quad 0
                .quad k_falloff
                .long FF_FALL, 2
                .quad kw_fall
                .quad k_radius
                .long FF_RAD, 0
                .quad 0
                .quad k_size
                .long FF_RAD, 0
                .quad 0
                .quad k_law
                .long FF_LAW, 2
                .quad kw_law
                .quad k_shape
                .long FF_LAW, 2
                .quad kw_shape
                .quad k_gust
                .long FF_GUST, 0
                .quad 0
                .quad k_scale
                .long FF_SCALE, 0
                .quad 0
                .quad k_seed
                .long FF_SEED, 1
                .quad 0
                .quad k_lift
                .long FF_LIFT, 0
                .quad 0
                .quad k_inflow
                .long FF_INFLOW, 0
                .quad 0
                .quad k_soft
                .long FF_SOFT, 0
                .quad 0
                .quad k_groups
                .long FF_SKIP, 4
                .quad 0
                .quad k_type
                .long FF_TYPE, 3
                .quad 0
                .quad k_on
                .long 0, 5
                .quad 0
                .quad k_off
                .long 0, 6
                .quad 0
                .quad 0

.text
.set FL_OPTS, 0
OPERATOR op_fl_attr,   "field.add_attractor",  "Attractor",    do_fl_add, arg=0, flags=OPF_AI_SAFE|OPF_UNDO, doc="Add an Attractor at the 3D cursor: it pulls rigid bodies, cloth and particles towards it (strength / distance squared; a negative strength pushes away): field.add_attractor [strength s] [law square|linear] [soft m] [falloff none|radius|smooth] [radius m] [groups all|0,3]"
OPERATOR op_fl_zone,   "field.add_zone",       "Gravity Zone", do_fl_add, arg=1, flags=OPF_AI_SAFE|OPF_UNDO, doc="Add a Gravity Zone: inside its box (or sphere) down is the object's -Y at this strength instead of the world's gravity: field.add_zone [strength s] [shape box|sphere] [size half-size m]"
OPERATOR op_fl_wind,   "field.add_wind",       "Wind",         do_fl_add, arg=2, flags=OPF_AI_SAFE|OPF_UNDO, doc="Add Wind: it blows along the object's +X (rotate it to aim), with gusts; cloth feels it as air of this speed (m/s): field.add_wind [strength s] [gust 0..1] [falloff none|radius|smooth] [radius m]"
OPERATOR op_fl_vortex, "field.add_vortex",     "Vortex",       do_fl_add, arg=3, flags=OPF_AI_SAFE|OPF_UNDO, doc="Add a Vortex: it turns things round the object's +Y: field.add_vortex [strength s] [lift s] [inflow s] [falloff none|radius|smooth] [radius m]"
OPERATOR op_fl_turb,   "field.add_turbulence", "Turbulence",   do_fl_add, arg=4, flags=OPF_AI_SAFE|OPF_UNDO, doc="Add Turbulence: swirling curl noise: field.add_turbulence [strength s] [scale m] [seed n] [falloff none|radius|smooth] [radius m]"
OPERATOR op_fl_drag,   "field.add_drag",       "Drag",         do_fl_add, arg=5, flags=OPF_AI_SAFE|OPF_UNDO, doc="Add Drag: it slows things down (strength x their velocity): field.add_drag [strength s] [falloff none|radius|smooth] [radius m]"
OPERATOR op_fl_planet,  "field.add_planet",    "Planet",     do_fl_preset, arg=0, flags=OPF_AI_SAFE|OPF_UNDO, doc="Add a planet at the 3D cursor: a 10 m sphere with an Attractor at its centre (9.81 m/s2 at its surface) and the world's gravity off - walk round it in play mode"
OPERATOR op_fl_hole,    "field.add_blackhole", "Black Hole", do_fl_preset, arg=1, flags=OPF_AI_SAFE|OPF_UNDO, doc="Add a Black Hole: a strong, short Attractor (strength 2000, smooth falloff to 8 m)"
OPERATOR op_fl_tornado, "field.add_tornado",   "Tornado",    do_fl_preset, arg=2, flags=OPF_AI_SAFE|OPF_UNDO, doc="Add a Tornado: a Vortex that turns things round its +Y, lifts them and pulls them in (smooth falloff to 6 m)"
OPERATOR op_fl_breeze,  "field.add_breeze",    "Breeze",     do_fl_preset, arg=3, flags=OPF_AI_SAFE|OPF_UNDO, doc="Add a Breeze: gentle, gusty Wind along +X"
OPERATOR op_fl_arrows,  "view.field_arrows",   "Force Field Arrows", op_toggle_flag, op_check_flag, fl_show_a, doc="Show the force fields' pull as arrows on a grid round them (gravity left out)"
OPERATOR op_fl_lines,   "view.field_lines",    "Force Field Lines",  op_toggle_flag, op_check_flag, fl_show_l, doc="Show the force fields' pull as lines (streamlines) from the selected objects"
OPERATOR op_fl_set,    "field.set",            "Field Settings", do_fl_set, flags=OPF_AI_SAFE|OPF_UNDO, doc="The active force field's settings: field.set [type attractor|zone|wind|vortex|turbulence|drag] [strength s] [falloff none|radius|smooth] [radius m] [law square|linear] [shape box|sphere] [gust 0..1] [scale m] [seed n] [lift s] [inflow s] [soft m] [groups all|0,3] [on|off]"

# ---- the block ----------------------------------------------------------------------
fl_ref:
    test    rdi, rdi
    jz      1f
    lock inc dword ptr [rdi+FL_REFS]
1:  ret
fl_unref:
    test    rdi, rdi
    jz      1f
    lock dec dword ptr [rdi+FL_REFS]
    jnz     1f
    mov     rsi, [rdi+FL_BYTES]
    call    plat_munmap
1:  ret
fl_reset:
    mov     rdi, [rip+fl_cur]
    mov     qword ptr [rip+fl_cur], 0
    jmp     fl_unref

fl_alloc:                               # -> rax = an empty block, or 0
    mov     esi, FL_SIZE
    xor     edi, edi
    mov     edx, PROT_RW
    mov     r10d, MAP_ANON_PRIV
    mov     r8d, -1
    xor     r9d, r9d
    call    plat_mmap
    cmp     rax, -4096
    jbe     1f
    xor     eax, eax
    ret
1:  mov     dword ptr [rax+FL_REFS], 1
    mov     qword ptr [rax+FL_BYTES], FL_SIZE
    ret

# fl_own -> rax = fl_cur, unshared (made when none), or 0
fl_own:
    push    rbx
    mov     rbx, [rip+fl_cur]
    test    rbx, rbx
    jz      1f
    cmp     dword ptr [rbx+FL_REFS], 1
    jne     1f
    mov     rax, rbx
    pop     rbx
    ret
1:  call    fl_alloc
    test    rax, rax
    jz      9f
    test    rbx, rbx
    jz      2f
    mov     ecx, [rbx+FL_N]             # copy what is there
    mov     [rax+FL_N], ecx
    imul    ecx, ecx, FF_SZ
    lea     rsi, [rbx+FL_HDR]
    lea     rdi, [rax+FL_HDR]
    rep     movsb
2:  mov     [rip+fl_cur], rax
    push    rax
    mov     rdi, rbx
    call    fl_unref
    pop     rax
9:  pop     rbx
    ret

# fl_get(edi=uid) -> rax = its record (read only), or 0
fl_get:
    mov     rax, [rip+fl_cur]
    test    rax, rax
    jz      8f
    mov     ecx, [rax+FL_N]
    lea     rax, [rax+FL_HDR]
1:  test    ecx, ecx
    jz      8f
    cmp     [rax+FF_UID], edi
    je      9f
    add     rax, FF_SZ
    dec     ecx
    jmp     1b
8:  xor     eax, eax
9:  ret

# fl_view(rdi=field object) -> rax = its record, or the defaults (read only)
fl_view:
    push    rbx
    mov     rbx, rdi
    mov     edi, [rbx+OB_UID]
    call    fl_get
    test    rax, rax
    jnz     9f
    lea     rdi, [rip+fl_dflt]
    mov     eax, [rbx+OB_UID]
    mov     [rdi+FF_UID], eax
    xor     esi, esi
    call    fl_set_type
    lea     rax, [rip+fl_dflt]
9:  pop     rbx
    ret

# fl_set_type(rdi=record, esi=type) - that type with its defaults
fl_set_type:
    cmp     esi, FLD_N
    jb      1f
    xor     esi, esi
1:  mov     [rdi+FF_TYPE], esi
    imul    esi, esi, FDEF_SZ
    lea     rax, [rip+fl_defs]
    lea     rsi, [rax+rsi]
    add     rdi, FF_STR
    mov     ecx, FDEF_SZ
    rep     movsb
    ret

# fl_rec_own(edi=uid, esi=type for a new one) -> rax = its record, writable,
#   or 0
fl_rec_own:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     ebx, edi
    mov     r12d, esi
    call    fl_own
    test    rax, rax
    jz      9f
    mov     edi, ebx
    call    fl_get
    test    rax, rax
    jnz     9f
    mov     rcx, [rip+fl_cur]           # a new one
    mov     edx, [rcx+FL_N]
    cmp     edx, FL_MAX
    jae     8f
    inc     dword ptr [rcx+FL_N]
    imul    edx, edx, FF_SZ
    lea     rax, [rcx+FL_HDR+rdx]
    mov     [rax+FF_UID], ebx
    push    rax
    push    rax
    mov     rdi, rax
    mov     esi, r12d
    call    fl_set_type
    pop     rax
    pop     rax
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# fl_copy(edi=uid, esi=new uid) - a duplicate's settings (object.duplicate)
fl_copy:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     ebx, edi
    mov     r12d, esi
    call    fl_get
    test    rax, rax
    jz      9f
    mov     edi, r12d
    xor     esi, esi
    call    fl_rec_own
    test    rax, rax
    jz      9f
    push    rax
    push    rax
    mov     edi, ebx                    # (the block may have been copied)
    call    fl_get
    pop     rdi
    pop     rdi
    test    rax, rax
    jz      9f
    lea     rsi, [rax+4]
    add     rdi, 4
    mov     ecx, FF_SZ-4
    rep     movsb
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# fl_write - the records (formats.s: the FLDS chunk)
fl_write:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, [rip+fl_cur]
    xor     r12d, r12d
    test    rbx, rbx
    jz      1f
    mov     r12d, [rbx+FL_N]
1:  mov     edi, r12d
    call    wb_u32
    test    r12d, r12d
    jz      9f
    lea     rsi, [rbx+FL_HDR]
    imul    edx, r12d, FF_SZ
    call    wb_bytes
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# fl_read(rdi=chunk, esi=size)
fl_read:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12d, esi
    call    fl_reset
    cmp     r12d, 4
    jb      9f
    mov     r13d, [rbx]
    cmp     r13d, FL_MAX
    jbe     1f
    mov     r13d, FL_MAX
1:  imul    eax, r13d, FF_SZ
    add     eax, 4
    cmp     eax, r12d
    ja      9f
    call    fl_alloc
    test    rax, rax
    jz      9f
    mov     [rip+fl_cur], rax
    mov     [rax+FL_N], r13d
    lea     rsi, [rbx+4]
    lea     rdi, [rax+FL_HDR]
    imul    ecx, r13d, FF_SZ
    rep     movsb
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# fl_chan(edi=uid, esi=1 to set, xmm0=value) -> xmm0 = its strength, eax =
#   1 (0: no such field) - the field:<name>:strength channel (anim.s)
fl_chan:
    push    rbx
    push    r12
    sub     rsp, 24
    mov     ebx, edi
    mov     r12d, esi
    movss   [rsp], xmm0
    call    obj_by_uid
    test    rax, rax
    jz      8f
    cmp     dword ptr [rax+OB_TYPE], OT_FIELD
    jne     8f
    mov     [rsp+8], rax
    test    r12d, r12d
    jz      1f
    mov     edi, ebx
    xor     esi, esi
    call    fl_rec_own
    test    rax, rax
    jz      8f
    movss   xmm0, [rsp]
    movss   [rax+FF_STR], xmm0
1:  mov     rdi, [rsp+8]
    call    fl_view
    movss   xmm0, [rax+FF_STR]
    mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 24
    pop     r12
    pop     rbx
    ret

# fl_mix(rax=hash) -> rax: the fields (where they are, their settings) mixed
#   in (a simulation's cache key). A field that keys move, or whose strength
#   is keyed, mixes in the animation instead of where it is and its strength
#   now: those change every frame, and the cache would be begun again on each
fl_mix:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, FF_SZ+8
    mov     r13, rax
    xor     ebx, ebx
    xor     r14d, r14d                  # (an animated field)
1:  cmp     ebx, [rip+obj_count]
    jae     8f
    mov     edi, ebx
    call    obj_at
    inc     ebx
    cmp     dword ptr [rax+OB_TYPE], OT_FIELD
    jne     1b
    mov     r12, rax
    mov     edi, [r12+OB_UID]
    call    an_moves
    test    eax, eax
    jz      2f
    mov     r14d, 1
    jmp     3f
2:  mov     rax, r13
    lea     rdi, [r12+OB_LOC]
    mov     esi, 36
    call    sc_mix
    mov     r13, rax
3:  mov     ecx, [r12+OB_FLAGS]
    and     ecx, OBF_HIDDEN
    xor     r13, rcx
    mov     rdi, r12
    call    fl_view
    mov     rsi, rax                    # (a copy: the keyed strength left out)
    mov     rdi, rsp
    mov     ecx, FF_SZ
    rep     movsb
    mov     edi, [r12+OB_UID]
    call    an_fkeyed
    test    eax, eax
    jz      4f
    mov     r14d, 1
    mov     dword ptr [rsp+FF_STR], 0
4:  mov     rdi, rsp
    mov     esi, FF_SZ
    mov     rax, r13
    call    sc_mix
    mov     r13, rax
    jmp     1b
8:  mov     rax, r13
    test    r14d, r14d
    jz      9f
    call    an_hash
9:  add     rsp, FF_SZ+8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ---- this step's fields --------------------------------------------------------------
# fl_col(rdi=out (4 floats), rsi=&m[column] of a 3x4 matrix) -> out = that
#   column, unit (w 0); xmm0 = its length
fl_col:
    movss   xmm0, [rsi]
    movss   xmm1, [rsi+16]
    movss   xmm2, [rsi+32]
    unpcklps xmm0, xmm1
    movlhps xmm0, xmm2
    andps   xmm0, [rip+fq_xyz]
    movaps  xmm1, xmm0
    DOT3    xmm1, xmm1
    sqrtss  xmm1, xmm1
    maxss   xmm1, [rip+fq_tiny]
    movaps  xmm2, xmm1
    shufps  xmm2, xmm2, 0
    divps   xmm0, xmm2
    andps   xmm0, [rip+fq_xyz]
    movaps  [rdi], xmm0
    movaps  xmm0, xmm1
    ret

# fl_prep(xmm0=time (s), rdi=the world's gravity (4 floats)) - fl_tab: every
#   visible field that is on, as it is now
fl_prep:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    and     rsp, -16
    sub     rsp, 64                     # [0] its matrix, [48] the time, [52] p
    movups  xmm1, [rdi]
    andps   xmm1, [rip+fq_xyz]
    movaps  [rip+fl_g], xmm1
    movss   [rsp+48], xmm0
    xor     eax, eax
    mov     [rip+fl_n], eax
    mov     [rip+fl_nw], eax
    xor     ebx, ebx
1:  cmp     ebx, [rip+obj_count]
    jae     9f
    mov     edi, ebx
    call    obj_at
    inc     ebx
    cmp     dword ptr [rax+OB_TYPE], OT_FIELD
    jne     1b
    test    dword ptr [rax+OB_FLAGS], OBF_HIDDEN
    jnz     1b
    mov     r12, rax
    mov     rdi, rax
    call    fl_view
    mov     r13, rax
    test    dword ptr [r13+FF_FLAGS], 1
    jnz     1b
    mov     eax, [rip+fl_n]
    cmp     eax, FT_MAX
    jae     9f
    imul    r14, rax, FT_SZ
    lea     rcx, [rip+fl_tab]
    add     r14, rcx
    mov     rdi, r12
    mov     rsi, rsp
    call    obj_matrix
    movss   xmm0, [rsp+12]              # the centre
    movss   [r14+FT_C], xmm0
    movss   xmm0, [rsp+28]
    movss   [r14+FT_C+4], xmm0
    movss   xmm0, [rsp+44]
    movss   [r14+FT_C+8], xmm0
    mov     dword ptr [r14+FT_C+12], 0
    lea     rdi, [r14+FT_U]             # the axes, their scales
    lea     rsi, [rsp]
    call    fl_col
    movss   [r14+FT_HS], xmm0
    lea     rdi, [r14+FT_AX]
    lea     rsi, [rsp+4]
    call    fl_col
    movss   [r14+FT_HS+4], xmm0
    lea     rdi, [r14+FT_V]
    lea     rsi, [rsp+8]
    call    fl_col
    movss   [r14+FT_HS+8], xmm0
    mov     dword ptr [r14+FT_HS+12], 0
    movss   xmm0, [r13+FF_RAD]          # radius x its X scale; a box's half
    movss   xmm1, xmm0                  #  sizes
    mulss   xmm1, [r14+FT_HS]
    movss   [r14+FT_RAD], xmm1
    shufps  xmm0, xmm0, 0
    movaps  xmm1, [r14+FT_HS]
    mulps   xmm1, xmm0
    movaps  [r14+FT_HS], xmm1
    mov     eax, [r13+FF_TYPE]
    mov     [r14+FT_TYPE], eax
    mov     eax, [r13+FF_FALL]
    mov     [r14+FT_FALL], eax
    mov     eax, [r13+FF_LAW]
    mov     [r14+FT_LAW], eax
    mov     eax, [r13+FF_SKIP]
    and     eax, 0xffff
    mov     [r14+FT_SKIP], eax
    mov     eax, [r13+FF_LIFT]
    mov     [r14+FT_LIFT], eax
    mov     eax, [r13+FF_INFLOW]
    mov     [r14+FT_INFLOW], eax
    movss   xmm0, [r13+FF_SOFT]
    mulss   xmm0, xmm0
    movss   [r14+FT_SOFT2], xmm0
    movss   xmm1, [r13+FF_SCALE]
    maxss   xmm1, [rip+fq_min]
    movss   xmm0, [rip+fq_one]
    divss   xmm0, xmm1
    movss   [r14+FT_ISCALE], xmm0
    cvtsi2ss xmm0, dword ptr [r13+FF_SEED]  # turbulence: where in the noise
    movss   xmm1, xmm0
    mulss   xmm1, [rip+fq_o1]
    movss   xmm2, [rsp+48]
    mulss   xmm2, [rip+fq_quarter]
    addss   xmm1, xmm2
    movss   [r14+FT_OFF], xmm1
    movss   xmm1, xmm0
    mulss   xmm1, [rip+fq_o2]
    movss   [r14+FT_OFF+4], xmm1
    mulss   xmm0, [rip+fq_o3]
    movss   [r14+FT_OFF+8], xmm0
    mov     dword ptr [r14+FT_OFF+12], 0
    mov     eax, [r13+FF_STR]
    mov     [r14+FT_STR], eax
    cmp     dword ptr [r13+FF_TYPE], FLD_WIND
    jne     5f
    movaps  xmm0, [r14+FT_U]            # wind: along +X, with its gust now
    movaps  [r14+FT_AX], xmm0
    inc     dword ptr [rip+fl_nw]
    movss   xmm0, [r13+FF_GUST]
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    jbe     5f
    movss   xmm0, [rsp+48]
    mulss   xmm0, [rip+fq_half]
    movss   [rsp+52], xmm0
    cvtsi2ss xmm0, dword ptr [r13+FF_SEED]
    mulss   xmm0, [rip+fq_gs]
    addss   xmm0, [rip+fq_half]
    movss   [rsp+56], xmm0
    mov     eax, [rip+fq_g37]
    mov     [rsp+60], eax
    lea     rdi, [rsp+52]
    call    perlin
    mulss   xmm0, [r13+FF_GUST]
    addss   xmm0, [rip+fq_one]
    mulss   xmm0, [r14+FT_STR]
    movss   [r14+FT_STR], xmm0
5:  inc     dword ptr [rip+fl_n]
    jmp     1b
9:  lea     rsp, [rbp-40]
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret

# fl_fall(xmm0=distance, r12=the field) -> xmm0 = its falloff there (leaf:
#   xmm1, xmm2, eax)
fl_fall:
    mov     eax, [r12+FT_FALL]
    test    eax, eax
    jz      1f
    comiss  xmm0, [r12+FT_RAD]
    jae     8f
    cmp     eax, 1
    je      1f
    movss   xmm1, [r12+FT_RAD]
    maxss   xmm1, [rip+fq_tiny]
    divss   xmm0, xmm1
    mulss   xmm0, xmm0
    movss   xmm1, [rip+fq_one]
    subss   xmm1, xmm0
    mulss   xmm1, xmm1
    movss   xmm0, xmm1
    ret
1:  movss   xmm0, [rip+fq_one]
    ret
8:  xorps   xmm0, xmm0
    ret

# fl_accel(rdi=position, rsi=velocity or 0 (16 bytes each, x y z read),
#   edx=its collision group's bit, ecx=1 to leave wind out (cloth: it is
#   air there)) -> xmm0 = the acceleration (x y z, w 0): the fields' sum
#   plus gravity (a gravity zone's when inside one, else the world's).
#   Re-entrant: the solvers' workers call it (with any stack alignment).
fl_accel:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    and     rsp, -16
    sub     rsp, 128    # [0] p [16] v [32] sum [48] zone g [64] [80] tmp [96] curl [112] f
    movups  xmm0, [rdi]
    andps   xmm0, [rip+fq_xyz]
    movaps  [rsp], xmm0
    xorps   xmm1, xmm1
    test    rsi, rsi
    jz      1f
    movups  xmm1, [rsi]
    andps   xmm1, [rip+fq_xyz]
1:  movaps  [rsp+16], xmm1
    xorps   xmm0, xmm0
    movaps  [rsp+32], xmm0
    mov     r13d, edx
    mov     r14d, ecx
    xor     r15d, r15d                  # in a zone
    xor     ebx, ebx
.Lfa_loop:
    cmp     ebx, [rip+fl_n]
    jae     .Lfa_end
    imul    r12, rbx, FT_SZ
    lea     rax, [rip+fl_tab]
    add     r12, rax
    inc     ebx
    test    [r12+FT_SKIP], r13d
    jnz     .Lfa_loop
    movaps  xmm1, [rsp]
    subps   xmm1, [r12+FT_C]            # d = p - c
    mov     eax, [r12+FT_TYPE]
    cmp     eax, FLD_ATTR
    je      .Lfa_attr
    cmp     eax, FLD_ZONE
    je      .Lfa_zone
    cmp     eax, FLD_WIND
    je      .Lfa_wind
    cmp     eax, FLD_VORTEX
    je      .Lfa_vortex
    cmp     eax, FLD_TURB
    je      .Lfa_turb
    cmp     eax, FLD_DRAG
    je      .Lfa_drag
    jmp     .Lfa_loop

.Lfa_attr:                              # -d s f / q^1.5 (q = d2 + soft2), or / q
    movaps  [rsp+64], xmm1
    movaps  xmm2, xmm1
    DOT3    xmm2, xmm2
    movss   [rsp+80], xmm2
    sqrtss  xmm0, xmm2
    call    fl_fall
    movss   xmm2, [rsp+80]
    addss   xmm2, [r12+FT_SOFT2]
    movss   xmm3, [r12+FT_STR]
    mulss   xmm3, xmm0
    cmp     dword ptr [r12+FT_LAW], 0
    jne     2f
    movss   xmm4, xmm2
    sqrtss  xmm4, xmm4
    mulss   xmm2, xmm4
2:  maxss   xmm2, [rip+fq_tiny]
    divss   xmm3, xmm2
    shufps  xmm3, xmm3, 0
    movaps  xmm1, [rsp+64]
    mulps   xmm1, xmm3
    movaps  xmm0, [rsp+32]
    subps   xmm0, xmm1
    movaps  [rsp+32], xmm0
    jmp     .Lfa_loop

.Lfa_zone:                              # inside: down = -Y s (the first zone)
    test    r15d, r15d
    jnz     .Lfa_loop
    cmp     dword ptr [r12+FT_LAW], 0
    jne     3f
    movaps  xmm2, xmm1
    DOT3    xmm2, [r12+FT_U]
    andps   xmm2, [rip+fq_abs]
    comiss  xmm2, [r12+FT_HS]
    ja      .Lfa_loop
    movaps  xmm2, xmm1
    DOT3    xmm2, [r12+FT_AX]
    andps   xmm2, [rip+fq_abs]
    comiss  xmm2, [r12+FT_HS+4]
    ja      .Lfa_loop
    movaps  xmm2, xmm1
    DOT3    xmm2, [r12+FT_V]
    andps   xmm2, [rip+fq_abs]
    comiss  xmm2, [r12+FT_HS+8]
    ja      .Lfa_loop
    jmp     4f
3:  DOT3    xmm1, xmm1
    sqrtss  xmm1, xmm1
    comiss  xmm1, [r12+FT_RAD]
    ja      .Lfa_loop
4:  movss   xmm0, [r12+FT_STR]
    xorps   xmm0, [rip+fq_sign]
    shufps  xmm0, xmm0, 0
    mulps   xmm0, [r12+FT_AX]
    movaps  [rsp+48], xmm0
    mov     r15d, 1
    jmp     .Lfa_loop

.Lfa_wind:                              # along its axis, s f
    test    r14d, 1
    jnz     .Lfa_loop
    DOT3    xmm1, xmm1
    sqrtss  xmm0, xmm1
    call    fl_fall
    mulss   xmm0, [r12+FT_STR]
    shufps  xmm0, xmm0, 0
    mulps   xmm0, [r12+FT_AX]
    addps   xmm0, [rsp+32]
    movaps  [rsp+32], xmm0
    jmp     .Lfa_loop

.Lfa_vortex:                            # f (s t - inflow r + lift a)
    movaps  xmm2, xmm1
    DOT3    xmm2, [r12+FT_AX]
    shufps  xmm2, xmm2, 0
    mulps   xmm2, [r12+FT_AX]
    subps   xmm1, xmm2                  # r: off the axis
    andps   xmm1, [rip+fq_xyz]
    movaps  xmm0, xmm1
    DOT3    xmm0, xmm0
    sqrtss  xmm0, xmm0
    comiss  xmm0, [rip+fq_tiny]
    jbe     .Lfa_loop
    movaps  [rsp+64], xmm1
    movss   [rsp+80], xmm0
    call    fl_fall
    movss   [rsp+84], xmm0
    movaps  xmm1, [r12+FT_AX]
    movaps  xmm2, [rsp+64]
    CROSS   xmm3, xmm1, xmm2, xmm4      # a x r
    movss   xmm5, [rsp+80]
    shufps  xmm5, xmm5, 0
    divps   xmm3, xmm5                  # t
    movss   xmm4, [r12+FT_STR]
    shufps  xmm4, xmm4, 0
    mulps   xmm3, xmm4
    movaps  xmm2, [rsp+64]
    divps   xmm2, xmm5
    movss   xmm4, [r12+FT_INFLOW]
    shufps  xmm4, xmm4, 0
    mulps   xmm2, xmm4
    subps   xmm3, xmm2
    movss   xmm4, [r12+FT_LIFT]
    shufps  xmm4, xmm4, 0
    mulps   xmm4, [r12+FT_AX]
    addps   xmm3, xmm4
    movss   xmm0, [rsp+84]
    shufps  xmm0, xmm0, 0
    mulps   xmm3, xmm0
    andps   xmm3, [rip+fq_xyz]
    addps   xmm3, [rsp+32]
    movaps  [rsp+32], xmm3
    jmp     .Lfa_loop

.Lfa_turb:                              # s f curl(noise(p / scale + off))
    DOT3    xmm1, xmm1
    sqrtss  xmm0, xmm1
    call    fl_fall
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    jbe     .Lfa_loop
    movss   [rsp+112], xmm0
    movss   xmm1, [r12+FT_ISCALE]
    shufps  xmm1, xmm1, 0
    movaps  xmm0, [rsp]
    mulps   xmm0, xmm1
    addps   xmm0, [r12+FT_OFF]
    movaps  [rsp+64], xmm0
    lea     rdi, [rsp+64]
    lea     rsi, [rsp+96]
    call    fl_curl
    movups  xmm0, [rsp+96]
    andps   xmm0, [rip+fq_xyz]
    movss   xmm1, [rsp+112]
    mulss   xmm1, [r12+FT_STR]
    shufps  xmm1, xmm1, 0
    mulps   xmm0, xmm1
    addps   xmm0, [rsp+32]
    movaps  [rsp+32], xmm0
    jmp     .Lfa_loop

.Lfa_drag:                              # -s f v
    DOT3    xmm1, xmm1
    sqrtss  xmm0, xmm1
    call    fl_fall
    mulss   xmm0, [r12+FT_STR]
    shufps  xmm0, xmm0, 0
    mulps   xmm0, [rsp+16]
    movaps  xmm1, [rsp+32]
    subps   xmm1, xmm0
    movaps  [rsp+32], xmm1
    jmp     .Lfa_loop

.Lfa_end:
    movaps  xmm0, [rip+fl_g]
    test    r15d, r15d
    jz      5f
    movaps  xmm0, [rsp+48]
5:  addps   xmm0, [rsp+32]
    andps   xmm0, [rip+fq_xyz]
    lea     rsp, [rbp-40]
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret

# fl_curl(rdi=q (3 floats), rsi=out (3 floats)) - the curl of three noise
#   potentials at q (central differences)
fl_curl:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 48                     # [0] p, [16] the + sample, [20] axis
    mov     r12, rdi
    mov     r13, rsi
    xor     eax, eax
    mov     [r13], eax
    mov     [r13+4], eax
    mov     [r13+8], eax
    xor     ebx, ebx
1:  cmp     ebx, 6
    jae     9f
    lea     rax, [rip+fc_terms]
    movzx   ecx, byte ptr [rax+rbx*4]   # the potential: q + its offset
    imul    ecx, ecx, 12
    lea     rdx, [rip+fc_offs]
    add     rdx, rcx
    movss   xmm0, [r12]
    addss   xmm0, [rdx]
    movss   [rsp], xmm0
    movss   xmm0, [r12+4]
    addss   xmm0, [rdx+4]
    movss   [rsp+4], xmm0
    movss   xmm0, [r12+8]
    addss   xmm0, [rdx+8]
    movss   [rsp+8], xmm0
    movzx   ecx, byte ptr [rax+rbx*4+1] # along this axis
    mov     [rsp+20], ecx
    movss   xmm0, [rsp+rcx*4]
    addss   xmm0, [rip+fc_eps]
    movss   [rsp+rcx*4], xmm0
    mov     rdi, rsp
    call    perlin
    movss   [rsp+16], xmm0
    mov     ecx, [rsp+20]
    movss   xmm0, [rsp+rcx*4]
    subss   xmm0, [rip+fc_eps2]
    movss   [rsp+rcx*4], xmm0
    mov     rdi, rsp
    call    perlin
    movss   xmm1, [rsp+16]
    subss   xmm1, xmm0
    mulss   xmm1, [rip+fc_inv]
    lea     rax, [rip+fc_terms]
    cmp     byte ptr [rax+rbx*4+2], 0
    je      2f
    xorps   xmm1, [rip+fq_sign]
2:  movzx   ecx, byte ptr [rax+rbx*4+3]
    addss   xmm1, [r13+rcx*4]
    movss   [r13+rcx*4], xmm1
    inc     ebx
    jmp     1b
9:  add     rsp, 48
    pop     r13
    pop     r12
    pop     rbx
    ret

# fl_wind(xmm0=position (4 floats)) -> xmm0 = the wind fields' air there
#   (cloth: group 0). Keeps rbx, r12.
fl_wind:
    push    r12
    push    rbx
    andps   xmm0, [rip+fq_xyz]
    movaps  xmm4, xmm0
    xorps   xmm5, xmm5
    xor     ebx, ebx
1:  cmp     ebx, [rip+fl_n]
    jae     9f
    imul    r12, rbx, FT_SZ
    lea     rax, [rip+fl_tab]
    add     r12, rax
    inc     ebx
    cmp     dword ptr [r12+FT_TYPE], FLD_WIND
    jne     1b
    test    dword ptr [r12+FT_SKIP], 1
    jnz     1b
    movaps  xmm1, xmm4
    subps   xmm1, [r12+FT_C]
    DOT3    xmm1, xmm1
    sqrtss  xmm0, xmm1
    call    fl_fall
    mulss   xmm0, [r12+FT_STR]
    shufps  xmm0, xmm0, 0
    mulps   xmm0, [r12+FT_AX]
    addps   xmm5, xmm0
    jmp     1b
9:  movaps  xmm0, xmm5
    pop     rbx
    pop     r12
    ret

# fl_sample(rdi=point (3 floats), rsi=out (3 floats)) - the acceleration a
#   still thing of group 0 feels there now (BeeScript force(), the overlay)
fl_sample:
    push    rbx
    push    r12
    sub     rsp, 40
    mov     rbx, rdi
    mov     r12, rsi
    call    rb_gravity
    mov     rdi, rax
    call    fl_time
    call    fl_prep
    mov     rax, [rbx]
    mov     [rsp], rax
    mov     eax, [rbx+8]
    mov     [rsp+8], eax
    mov     dword ptr [rsp+12], 0
    mov     rdi, rsp
    xor     esi, esi
    mov     edx, 1
    xor     ecx, ecx
    call    fl_accel
    movups  [rsp+16], xmm0
    mov     rax, [rsp+16]
    mov     [r12], rax
    mov     eax, [rsp+24]
    mov     [r12+8], eax
    add     rsp, 40
    pop     r12
    pop     rbx
    ret

# fl_time -> xmm0 = the scene's time now (s: frame / fps); keeps rdi
fl_time:
    movss   xmm0, [rip+an_frame]
    mov     rax, [rip+an_cur]
    test    rax, rax
    jz      9f
    movss   xmm1, [rax+32]              # (anim.s AN_FPS)
    maxss   xmm1, [rip+fq_one]
    divss   xmm0, xmm1
9:  ret

# fl_active -> rax = the active object when it is a field (else 0), rdx = its
#   record (fl_view)
fl_active:
    push    rbx
    mov     edi, [rip+active_obj]
    call    obj_get
    test    rax, rax
    jz      8f
    cmp     dword ptr [rax+OB_TYPE], OT_FIELD
    jne     8f
    mov     rbx, rax
    mov     rdi, rax
    call    fl_view
    mov     rdx, rax
    mov     rax, rbx
    pop     rbx
    ret
8:  xor     eax, eax
    xor     edx, edx
    pop     rbx
    ret

# ---- operators ------------------------------------------------------------------------
# do_fl_add(rdi=type) - field.add_<type> [settings]: at the 3D cursor
do_fl_add:
    lea     rcx, [rip+fl_tnames]
    mov     eax, edi
    mov     rsi, [rcx+rax*8]
    xor     edx, edx
# fl_add_named(edi=type, rsi=name, rdx=preset settings or 0) - a field at the
#   3D cursor, with the preset's settings, then op_arg's
fl_add_named:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     ebx, edi
    mov     r14, rsi
    mov     r15, rdx
    call    prim_light
    test    rax, rax
    jz      9f
    mov     rdx, rax
    mov     edi, OT_FIELD
    mov     rsi, r14
    call    obj_new
    test    eax, eax
    jz      9f
    mov     r12d, eax
    mov     edi, eax
    xor     esi, esi
    call    obj_click_select
    mov     edi, r12d
    call    obj_get
    mov     r13, rax
    mov     rcx, [rip+cursor_pos]
    mov     [r13+OB_LOC], rcx
    mov     ecx, [rip+cursor_pos+8]
    mov     [r13+OB_LOC+8], ecx
    mov     edi, [r13+OB_UID]
    mov     esi, ebx
    call    fl_rec_own
    test    rax, rax
    jz      8f
    mov     r12, rax
    mov     rdi, rax
    mov     rsi, r15
    call    fl_parse
    mov     rdi, r12
    mov     rsi, [rip+op_arg]
    call    fl_parse
8:  mov     dword ptr [rip+dirty], 1
    cmp     dword ptr [rip+op_quiet], 0
    jne     9f
    lea     rdi, [rip+s_added]
    mov     rsi, r13
    call    log_pair
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# do_fl_preset(rdi=0 planet, 1 black hole, 2 tornado, 3 breeze) - a field
#   (and for a planet its sphere, the world's gravity off) set for it
do_fl_preset:
    push    rbx
    sub     rsp, 16
    mov     ebx, edi
    test    edi, edi
    jnz     1f
    mov     edi, 1                      # a planet: a 10 m sphere (the UV
    call    op_create                   #  sphere's create.* index) at the
    mov     edi, [rip+active_obj]       #  cursor, gravity off
    lea     rsi, [rip+s_pr_planet]
    call    obj_rename
    mov     edi, [rip+active_obj]
    call    obj_get
    test    rax, rax
    jz      11f
    mov     ecx, [rip+fq_ten]
    mov     [rax+OB_SCALE], ecx
    mov     [rax+OB_SCALE+4], ecx
    mov     [rax+OB_SCALE+8], ecx
11: xor     edi, edi
    call    an_own_g
    test    rax, rax
    jz      1f
    xor     ecx, ecx
    mov     [rax+AN_RW_], ecx
    mov     [rax+AN_RW_+4], ecx
    mov     [rax+AN_RW_+8], ecx
    mov     dword ptr [rax+AN_RW_+20], 1        # (rbody.s RW_SET)
1:  lea     rax, [rip+fl_presets]
    imul    ecx, ebx, 24
    mov     edi, [rax+rcx]
    mov     rsi, [rax+rcx+8]
    mov     rdx, [rax+rcx+16]
    call    fl_add_named
    add     rsp, 16
    pop     rbx
    ret

# do_fl_set - field.set ... on the active field
do_fl_set:
    sub     rsp, 8
    call    fl_active
    test    rax, rax
    jz      8f
    mov     edi, [rax+OB_UID]
    xor     esi, esi
    call    fl_rec_own
    test    rax, rax
    jz      9f
    mov     rdi, rax
    mov     rsi, [rip+op_arg]
    call    fl_parse
    mov     dword ptr [rip+dirty], 1
    jmp     9f
8:  lea     rdi, [rip+s_nofield]
    call    log_line
9:  add     rsp, 8
    ret

# fl_type_of(rdi=text) -> eax = the field type it names (attractor ..
#   drag), or -1
fl_type_of:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     r12, rdi
    xor     ebx, ebx
1:  lea     rax, [rip+fl_kwtypes]
    mov     rsi, [rax+rbx*8]
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
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# fl_word(rdi=list, 0 ended) -> eax = im_word's place in it, or -1
fl_word:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     r12, rdi
    xor     ebx, ebx
1:  mov     rsi, [r12+rbx*8]
    test    rsi, rsi
    jz      8f
    lea     rdi, [rip+im_word]
    call    str_eq
    test    eax, eax
    jnz     2f
    inc     ebx
    jmp     1b
2:  mov     eax, ebx
    jmp     9f
8:  mov     eax, -1
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# fl_parse(rdi=record (writable), rsi=text or 0) -> eax = 1 (0: a word it did
#   not understand, said in the console)
fl_parse:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     rbx, rdi
    mov     r12, rsi
    test    r12, r12
    jz      .Lfp_ok
.Lfp_next:
    mov     rsi, r12
    call    im_next_word
    mov     r12, rsi
    test    eax, eax
    jz      .Lfp_ok
    xor     r13d, r13d
1:  imul    rax, r13, 24
    lea     r14, [rip+fp_tab]
    add     r14, rax
    mov     rsi, [r14]
    test    rsi, rsi
    jz      .Lfp_bad
    lea     rdi, [rip+im_word]
    call    str_eq
    test    eax, eax
    jnz     2f
    inc     r13d
    jmp     1b
2:  mov     eax, [r14+12]
    cmp     eax, 5
    jne     3f
    and     dword ptr [rbx+FF_FLAGS], ~1
    jmp     .Lfp_next
3:  cmp     eax, 6
    jne     4f
    or      dword ptr [rbx+FF_FLAGS], 1
    jmp     .Lfp_next
4:  mov     rsi, r12                    # its value
    call    im_next_word
    mov     r12, rsi
    test    eax, eax
    jz      .Lfp_bad
    mov     ecx, [r14+12]
    cmp     ecx, 2
    je      .Lfp_enum
    cmp     ecx, 3
    je      .Lfp_type
    cmp     ecx, 4
    je      .Lfp_groups
    lea     rsi, [rip+im_word]          # a number
    lea     rdx, [rsi+rax]
    call    parse_float
    test    eax, eax
    jz      .Lfp_bad
    mov     ecx, [r14+8]
    cmp     dword ptr [r14+12], 1
    jne     5f
    cvttss2si eax, xmm0
    mov     [rbx+rcx], eax
    jmp     .Lfp_next
5:  movss   [rbx+rcx], xmm0
    jmp     .Lfp_next
.Lfp_enum:
    mov     rdi, [r14+16]
    call    fl_word
    test    eax, eax
    js      .Lfp_bad
    mov     ecx, [r14+8]
    mov     [rbx+rcx], eax
    jmp     .Lfp_next
.Lfp_type:
    lea     rdi, [rip+fl_kwtypes]
    call    fl_word
    test    eax, eax
    js      .Lfp_bad
    cmp     eax, [rbx+FF_TYPE]
    je      .Lfp_next
    mov     rdi, rbx
    mov     esi, eax
    call    fl_set_type
    jmp     .Lfp_next
.Lfp_groups:                            # all, or 0,3,5: those feel it
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_all]
    call    str_eq
    test    eax, eax
    jz      6f
    mov     dword ptr [rbx+FF_SKIP], 0
    jmp     .Lfp_next
6:  lea     rsi, [rip+im_word]
    xor     edx, edx                    # the groups named
    xor     ecx, ecx                    # a number so far
    xor     r8d, r8d                    # digits in it
7:  movzx   eax, byte ptr [rsi]
    inc     rsi
    cmp     eax, '0'
    jb      71f
    cmp     eax, '9'
    ja      .Lfp_bad
    imul    ecx, ecx, 10
    lea     ecx, [rcx+rax-'0']
    inc     r8d
    jmp     7b
71: test    r8d, r8d                    # a number ends
    jz      72f
    cmp     ecx, 15
    ja      .Lfp_bad
    bts     edx, ecx
72: xor     ecx, ecx
    xor     r8d, r8d
    cmp     eax, ','
    je      7b
    test    eax, eax
    jnz     .Lfp_bad
    test    edx, edx
    jz      .Lfp_bad
    not     edx
    and     edx, 0xffff
    mov     [rbx+FF_SKIP], edx
    jmp     .Lfp_next
.Lfp_ok:
    mov     eax, 1
    jmp     9f
.Lfp_bad:
    lea     rdi, [rip+s_bad]
    lea     rsi, [rip+im_word]
    call    log_pair
    xor     eax, eax
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ---- in the viewport ------------------------------------------------------------------
# fd_at(rdi=out (3 floats), xmm0..xmm2 = x y z along the field's axes, in
#   icon sizes) - centre + k (x X + y Y + z Z)
fd_at:
    movss   xmm3, [rip+fd_k]
    mulss   xmm0, xmm3
    mulss   xmm1, xmm3
    mulss   xmm2, xmm3
    shufps  xmm0, xmm0, 0
    shufps  xmm1, xmm1, 0
    shufps  xmm2, xmm2, 0
    mulps   xmm0, [rip+fd_x]
    mulps   xmm1, [rip+fd_y]
    mulps   xmm2, [rip+fd_z]
    addps   xmm0, xmm1
    addps   xmm0, xmm2
    addps   xmm0, [rip+fd_c]
    movlps  [rdi], xmm0
    movhlps xmm0, xmm0
    movss   [rdi+8], xmm0
    ret

# fd_seg(xmm0..2 = a, xmm3..5 = b, field axes) - a line
fd_seg:
    sub     rsp, 24
    movss   [rsp], xmm3
    movss   [rsp+4], xmm4
    movss   [rsp+8], xmm5
    lea     rdi, [rip+lp0]
    call    fd_at
    movss   xmm0, [rsp]
    movss   xmm1, [rsp+4]
    movss   xmm2, [rsp+8]
    lea     rdi, [rip+lp1]
    call    fd_at
    mov     edx, [rip+fd_col]
    call    line3d
    add     rsp, 24
    ret

# fd_circle(edi=plane: 0 XZ (round Y), 1 XY (round Z), 2 YZ (round X),
#   xmm0=radius, xmm1=offset along the plane's normal) - in icon sizes
fd_circle:
    push    rbx
    push    r12
    sub     rsp, 56                     # [0] r, [4] off, [8..32] the points
    mov     r12d, edi
    movss   [rsp], xmm0
    movss   [rsp+4], xmm1
    xor     ebx, ebx
1:  cmp     ebx, SEGS
    ja      9f
    cvtsi2ss xmm0, ebx
    mulss   xmm0, [rip+fq_2pi]
    divss   xmm0, [rip+fq_segs]
    call    sincos
    mulss   xmm0, [rsp]                 # r sin, r cos
    mulss   xmm1, [rsp]
    movss   xmm2, [rsp+4]
    cmp     r12d, 1
    je      2f
    cmp     r12d, 2
    je      3f
    movss   xmm3, xmm1                  # XZ: (cos, off, sin)
    movss   xmm4, xmm2
    movss   xmm5, xmm0
    jmp     4f
2:  movss   xmm3, xmm1                  # XY: (cos, sin, off)
    movss   xmm4, xmm0
    movss   xmm5, xmm2
    jmp     4f
3:  movss   xmm3, xmm2                  # YZ: (off, cos, sin)
    movss   xmm4, xmm1
    movss   xmm5, xmm0
4:  test    ebx, ebx
    jz      5f
    movss   xmm0, [rsp+8]
    movss   xmm1, [rsp+12]
    movss   xmm2, [rsp+16]
    movss   [rsp+8], xmm3
    movss   [rsp+12], xmm4
    movss   [rsp+16], xmm5
    call    fd_seg
    jmp     6f
5:  movss   [rsp+8], xmm3
    movss   [rsp+12], xmm4
    movss   [rsp+16], xmm5
6:  inc     ebx
    jmp     1b
9:  add     rsp, 56
    pop     r12
    pop     rbx
    ret

# fd_arrow(xmm0..2 = from, xmm3..5 = to; icon sizes) - a line with a head
#   (two strokes back from the tip, a quarter of its length)
fd_arrow:
    sub     rsp, 72
    movss   [rsp], xmm0
    movss   [rsp+4], xmm1
    movss   [rsp+8], xmm2
    movss   [rsp+12], xmm3
    movss   [rsp+16], xmm4
    movss   [rsp+20], xmm5
    call    fd_seg
    movss   xmm0, [rsp+12]              # the direction, a quarter of it
    subss   xmm0, [rsp]
    movss   xmm1, [rsp+16]
    subss   xmm1, [rsp+4]
    movss   xmm2, [rsp+20]
    subss   xmm2, [rsp+8]
    movss   xmm3, [rip+fq_quarter]
    mulss   xmm0, xmm3
    mulss   xmm1, xmm3
    mulss   xmm2, xmm3
    movss   [rsp+24], xmm0
    movss   [rsp+28], xmm1
    movss   [rsp+32], xmm2
    # a side: the direction turned in a plane (swap two parts, one negated)
    movss   xmm3, xmm1                  # side = (y, -x, 0) unless along Z-ish
    movss   xmm4, xmm0
    xorps   xmm4, [rip+fq_sign]
    xorps   xmm5, xmm5
    movaps  xmm6, xmm3
    mulss   xmm6, xmm6
    movaps  xmm7, xmm4
    mulss   xmm7, xmm7
    addss   xmm6, xmm7
    comiss  xmm6, [rip+fq_tiny]
    ja      1f
    movss   xmm3, xmm2                  # (z, 0, -x)
    xorps   xmm4, xmm4
    movss   xmm5, xmm0
    xorps   xmm5, [rip+fq_sign]
1:  mulss   xmm3, [rip+fq_half]
    mulss   xmm4, [rip+fq_half]
    mulss   xmm5, [rip+fq_half]
    movss   [rsp+36], xmm3
    movss   [rsp+40], xmm4
    movss   [rsp+44], xmm5
    xor     eax, eax                    # both strokes: tip - dir +- side
2:  mov     [rsp+48], eax
    movss   xmm0, [rsp+12]
    movss   xmm1, [rsp+16]
    movss   xmm2, [rsp+20]
    movss   xmm3, xmm0
    subss   xmm3, [rsp+24]
    movss   xmm4, xmm1
    subss   xmm4, [rsp+28]
    movss   xmm5, xmm2
    subss   xmm5, [rsp+32]
    test    eax, eax
    jnz     3f
    addss   xmm3, [rsp+36]
    addss   xmm4, [rsp+40]
    addss   xmm5, [rsp+44]
    jmp     4f
3:  subss   xmm3, [rsp+36]
    subss   xmm4, [rsp+40]
    subss   xmm5, [rsp+44]
4:  call    fd_seg
    mov     eax, [rsp+48]
    inc     eax
    cmp     eax, 2
    jb      2b
    add     rsp, 72
    ret

# fd_rad(xmm0=radius in metres) -> xmm0 = in icon sizes
fd_rad:
    divss   xmm0, [rip+fd_k]
    ret

# fl_draw - (viewport_draw) every visible field's gizmo: its kind, its reach
fl_draw:
    push    rbx
    push    r12
    push    r13
    xor     ebx, ebx
.Lfd_obj:
    cmp     ebx, [rip+obj_count]
    jae     .Lfd_out
    mov     edi, ebx
    call    obj_at
    inc     ebx
    cmp     dword ptr [rax+OB_TYPE], OT_FIELD
    jne     .Lfd_obj
    test    dword ptr [rax+OB_FLAGS], OBF_HIDDEN
    jnz     .Lfd_obj
    mov     r12, rax
    mov     dword ptr [rip+fd_col], COL_TEXT_DIM
    test    dword ptr [r12+OB_FLAGS], OBF_SELECTED
    jz      1f
    mov     dword ptr [rip+fd_col], COL_ACCENT
1:  mov     rdi, r12
    call    fl_view
    mov     r13, rax
    mov     rdi, r12
    lea     rsi, [rip+fd_m]
    call    obj_matrix
    lea     rdi, [rip+fd_x]
    lea     rsi, [rip+fd_m]
    call    fl_col
    movss   [rip+fd_k], xmm0
    lea     rdi, [rip+fd_y]
    lea     rsi, [rip+fd_m+4]
    call    fl_col
    lea     rdi, [rip+fd_z]
    lea     rsi, [rip+fd_m+8]
    call    fl_col
    movss   xmm0, [rip+fd_m+12]
    movss   [rip+fd_c], xmm0
    movss   xmm0, [rip+fd_m+28]
    movss   [rip+fd_c+4], xmm0
    movss   xmm0, [rip+fd_m+44]
    movss   [rip+fd_c+8], xmm0
    mov     eax, [r13+FF_TYPE]
    cmp     eax, FLD_ZONE
    je      .Lfd_zone
    cmp     dword ptr [r13+FF_FALL], 0  # its reach: three circles
    je      2f
    movss   xmm0, [r13+FF_RAD]
    xorps   xmm1, xmm1
    mov     edi, 0
    call    fd_circle
    cmp     dword ptr [r13+FF_TYPE], FLD_VORTEX
    je      2f
    movss   xmm0, [r13+FF_RAD]
    xorps   xmm1, xmm1
    mov     edi, 1
    call    fd_circle
    movss   xmm0, [r13+FF_RAD]
    xorps   xmm1, xmm1
    mov     edi, 2
    call    fd_circle
2:  mov     eax, [r13+FF_TYPE]
    cmp     eax, FLD_ATTR
    je      .Lfd_attr
    cmp     eax, FLD_WIND
    je      .Lfd_wind
    cmp     eax, FLD_VORTEX
    je      .Lfd_vortex
    cmp     eax, FLD_TURB
    je      .Lfd_turb
    # drag: two rings
    movss   xmm0, [rip+gz_a]            # 0.45
    xorps   xmm1, xmm1
    mov     edi, 0
    call    fd_circle
    movss   xmm0, [rip+gz_a+20]         # 0.8
    xorps   xmm1, xmm1
    mov     edi, 0
    call    fd_circle
    jmp     .Lfd_obj

.Lfd_attr:                              # six arrows in (out when it pushes)
    xor     r12d, r12d
3:  cmp     r12d, 6
    jae     .Lfd_obj
    movss   xmm0, [rip+gz_a+4]          # from 0.9 to 0.3 on an axis, +-
    movss   xmm3, [rip+gz_a+32]
    xorps   xmm6, xmm6
    comiss  xmm6, [r13+FF_STR]          # pushing: the other way
    jbe     31f
    movss   xmm6, xmm0
    movss   xmm0, xmm3
    movss   xmm3, xmm6
31: test    r12d, 1
    jz      32f
    xorps   xmm0, [rip+fq_sign]
    xorps   xmm3, [rip+fq_sign]
32: xorps   xmm1, xmm1
    xorps   xmm2, xmm2
    xorps   xmm4, xmm4
    xorps   xmm5, xmm5
    mov     eax, r12d
    shr     eax, 1
    cmp     eax, 1
    jb      34f
    je      33f
    movss   xmm2, xmm0                  # along Z
    movss   xmm5, xmm3
    xorps   xmm0, xmm0
    xorps   xmm3, xmm3
    jmp     34f
33: movss   xmm1, xmm0                  # along Y
    movss   xmm4, xmm3
    xorps   xmm0, xmm0
    xorps   xmm3, xmm3
34: call    fd_arrow
    inc     r12d
    jmp     3b

.Lfd_wind:                              # three arrows along +X
    xor     r12d, r12d
4:  cmp     r12d, 3
    jae     .Lfd_obj
    lea     eax, [r12-1]
    cvtsi2ss xmm1, eax
    mulss   xmm1, [rip+gz_a+16]         # rows 0.4 apart
    movss   xmm4, xmm1
    movss   xmm0, [rip+gz_a+28]         # from -1 to 1.5
    xorps   xmm0, [rip+fq_sign]
    movss   xmm3, [rip+gz_a+12]
    xorps   xmm2, xmm2
    xorps   xmm5, xmm5
    call    fd_arrow
    inc     r12d
    jmp     4b

.Lfd_vortex:                            # its axis, rings round it, a turn
    xorps   xmm0, xmm0
    movss   xmm1, [rip+gz_a+28]
    xorps   xmm1, [rip+fq_sign]
    xorps   xmm2, xmm2
    xorps   xmm3, xmm3
    movss   xmm4, [rip+gz_a+28]
    xorps   xmm5, xmm5
    call    fd_arrow
    movss   xmm0, [rip+gz_a+20]
    movss   xmm1, [rip+gz_a+16]
    xorps   xmm1, [rip+fq_sign]
    mov     edi, 0
    call    fd_circle
    movss   xmm0, [rip+gz_a]
    movss   xmm1, [rip+gz_a+16]
    mov     edi, 0
    call    fd_circle
    movss   xmm0, [rip+gz_a+20]         # the way it turns: a tangent arrow
    xorps   xmm1, xmm1
    movss   xmm2, [rip+gz_a+24]
    xorps   xmm2, [rip+fq_sign]
    movss   xmm3, [rip+gz_a+20]
    xorps   xmm4, xmm4
    movss   xmm5, [rip+gz_a+24]
    xorps   xmm6, xmm6
    comiss  xmm6, [r13+FF_STR]
    jbe     5f
    movss   xmm6, xmm2
    movss   xmm2, xmm5
    movss   xmm5, xmm6
5:  call    fd_arrow
    jmp     .Lfd_obj

.Lfd_turb:                              # a wavy line along X
    xor     r12d, r12d
6:  cmp     r12d, 8
    jae     .Lfd_obj
    cvtsi2ss xmm0, r12d
    mulss   xmm0, [rip+gz_a+24]         # x: -1 + 0.25 i
    subss   xmm0, [rip+gz_a+28]
    mov     eax, r12d
    and     eax, 1
    lea     eax, [rax+rax-1]
    cvtsi2ss xmm1, eax
    mulss   xmm1, [rip+gz_a+8]          # y: +- 0.18
    xorps   xmm2, xmm2
    movss   xmm3, xmm0
    addss   xmm3, [rip+gz_a+24]
    movss   xmm4, xmm1
    xorps   xmm4, [rip+fq_sign]
    xorps   xmm5, xmm5
    call    fd_seg
    inc     r12d
    jmp     6b

.Lfd_zone:                              # its box (or sphere), down
    movss   xmm0, [r13+FF_RAD]
    cmp     dword ptr [r13+FF_LAW], 0
    je      7f
    xorps   xmm1, xmm1
    mov     edi, 0
    call    fd_circle
    movss   xmm0, [r13+FF_RAD]
    xorps   xmm1, xmm1
    mov     edi, 1
    call    fd_circle
    movss   xmm0, [r13+FF_RAD]
    xorps   xmm1, xmm1
    mov     edi, 2
    call    fd_circle
    jmp     8f
7:  call    fd_box                      # (xmm0 = half size)
8:  xorps   xmm0, xmm0                  # down: -Y
    movss   xmm1, [rip+gz_a+32]
    xorps   xmm2, xmm2
    xorps   xmm3, xmm3
    movss   xmm4, [rip+gz_a+28]
    xorps   xmm4, [rip+fq_sign]
    xorps   xmm5, xmm5
    call    fd_arrow
    jmp     .Lfd_obj

.Lfd_out:
    call    fl_overlay                  # View > Force Field Arrows / Lines
    pop     r13
    pop     r12
    pop     rbx
    ret

# fd_box(xmm0=half size, icon sizes along each axis) - its 12 edges
fd_box:
    push    rbx
    sub     rsp, 16
    movss   [rsp], xmm0
    xor     ebx, ebx                    # edge: axis (ebx / 4), corner (ebx & 3)
1:  cmp     ebx, 12
    jae     9f
    mov     eax, ebx
    and     eax, 3
    movss   xmm6, [rsp]                 # the two other axes' signs
    movss   xmm7, [rsp]
    test    eax, 1
    jz      2f
    xorps   xmm6, [rip+fq_sign]
2:  test    eax, 2
    jz      3f
    xorps   xmm7, [rip+fq_sign]
3:  movss   xmm8, [rsp]                 # along the edge: -h .. h
    movss   xmm9, xmm8
    xorps   xmm9, [rip+fq_sign]
    mov     eax, ebx
    shr     eax, 2
    cmp     eax, 1
    jb      4f
    je      5f
    movss   xmm0, xmm6                  # along Z
    movss   xmm1, xmm7
    movss   xmm2, xmm9
    movss   xmm3, xmm6
    movss   xmm4, xmm7
    movss   xmm5, xmm8
    jmp     6f
4:  movss   xmm0, xmm9                  # along X
    movss   xmm1, xmm6
    movss   xmm2, xmm7
    movss   xmm3, xmm8
    movss   xmm4, xmm6
    movss   xmm5, xmm7
    jmp     6f
5:  movss   xmm0, xmm6                  # along Y
    movss   xmm1, xmm9
    movss   xmm2, xmm7
    movss   xmm3, xmm6
    movss   xmm4, xmm8
    movss   xmm5, xmm7
6:  call    fd_seg
    inc     ebx
    jmp     1b
9:  add     rsp, 16
    pop     rbx
    ret

# ---- the overlay (A5): the pull as arrows on a grid, or streamlines --------------
# fo_world - the fd_* drawing in world space (centre 0, X Y Z, size 1)
fo_world:
    xorps   xmm0, xmm0
    movaps  [rip+fd_c], xmm0
    movaps  xmm0, [rip+fo_ex]
    movaps  [rip+fd_x], xmm0
    movaps  xmm0, [rip+fo_ey]
    movaps  [rip+fd_y], xmm0
    movaps  xmm0, [rip+fo_ez]
    movaps  [rip+fd_z], xmm0
    mov     eax, [rip+fq_one]
    mov     [rip+fd_k], eax
    ret

# fo_pull(xmm0 = a point) -> xmm0 = the fields' pull there (no gravity:
#   fl_prep'd with none), xmm1 = its size
fo_pull:
    sub     rsp, 24
    movups  [rsp], xmm0
    mov     rdi, rsp
    xor     esi, esi
    mov     edx, 1
    xor     ecx, ecx
    call    fl_accel
    movaps  xmm1, xmm0
    dpps    xmm1, xmm1, 0x71
    sqrtss  xmm1, xmm1
    add     rsp, 24
    ret

# fo_point(ebx = ix, r12d = iy, r13d = iz) -> fo_p = the grid's point
fo_point:
    cvtsi2ss xmm0, ebx
    cvtsi2ss xmm1, r12d
    cvtsi2ss xmm2, r13d
    unpcklps xmm0, xmm1
    movlhps xmm0, xmm2                  # i
    mulps   xmm0, [rip+fo_two4]
    divps   xmm0, [rip+fo_nm1]          # 2 i / (n - 1) - 1
    subps   xmm0, [rip+fo_one4]
    mulps   xmm0, [rip+fo_h]
    addps   xmm0, [rip+fo_c]
    andps   xmm0, [rip+fq_xyz]
    movaps  [rip+fo_p], xmm0
    ret

# fl_overlay - (fl_draw) the fields' pull where it is asked for
fl_overlay:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12
    push    r13
    push    r14
    and     rsp, -16
    sub     rsp, 32
    xor     eax, eax
    mov     [rip+fo_na], eax
    mov     [rip+fo_nl], eax
    mov     [rip+fo_max], eax
    mov     eax, [rip+fl_show_a]
    or      eax, [rip+fl_show_l]
    jz      .Lfo_out
    call    fl_time
    lea     rdi, [rip+fo_zero4]
    call    fl_prep
    cmp     dword ptr [rip+fl_n], 0
    je      .Lfo_out
    call    fo_world
    mov     dword ptr [rip+fd_col], 0x4fb0e0
    cmp     dword ptr [rip+fl_show_a], 0
    je      .Lfo_lines
    # the grid: round the fields (their centres, their reach up to 10 m)
    movaps  xmm6, [rip+fo_big4]
    movaps  xmm7, [rip+fo_nbig4]
    xor     ebx, ebx
1:  cmp     ebx, [rip+fl_n]
    jae     2f
    imul    rax, rbx, FT_SZ
    lea     rcx, [rip+fl_tab]
    add     rax, rcx
    movss   xmm1, [rax+FT_RAD]
    minss   xmm1, [rip+fo_ten]
    shufps  xmm1, xmm1, 0
    movaps  xmm0, [rax+FT_C]
    movaps  xmm2, xmm0
    subps   xmm2, xmm1
    minps   xmm6, xmm2
    addps   xmm0, xmm1
    maxps   xmm7, xmm0
    inc     ebx
    jmp     1b
2:  movaps  xmm0, xmm6
    addps   xmm0, xmm7
    mulps   xmm0, [rip+fo_half4]
    andps   xmm0, [rip+fq_xyz]
    movaps  [rip+fo_c], xmm0
    subps   xmm7, xmm6
    mulps   xmm7, [rip+fo_half4]
    addps   xmm7, [rip+fo_extra4]
    maxps   xmm7, [rip+fo_minh4]
    minps   xmm7, [rip+fo_maxh4]
    andps   xmm7, [rip+fq_xyz]
    movaps  [rip+fo_h], xmm7
    movss   xmm0, [rip+fo_h]            # a cell: the smaller of x, z
    minss   xmm0, [rip+fo_h+8]
    addss   xmm0, xmm0
    divss   xmm0, [rip+fo_nm1]
    mulss   xmm0, [rip+fo_k]
    movss   [rip+fo_cell], xmm0
    xor     r14d, r14d                  # pass 1: the pulls, the largest
    xor     ebx, ebx
3:  xor     r12d, r12d
31: xor     r13d, r13d
32: call    fo_point
    movaps  xmm0, [rip+fo_p]
    call    fo_pull
    imul    rax, r14, 16
    lea     rcx, [rip+fo_acc]
    movaps  [rcx+rax], xmm0
    maxss   xmm1, [rip+fo_max]
    movss   [rip+fo_max], xmm1
    inc     r14d
    inc     r13d
    cmp     r13d, FO_NX
    jb      32b
    inc     r12d
    cmp     r12d, FO_NY
    jb      31b
    inc     ebx
    cmp     ebx, FO_NX
    jb      3b
    movss   xmm0, [rip+fo_max]
    comiss  xmm0, [rip+fo_eps]
    jbe     .Lfo_lines
    xor     r14d, r14d                  # pass 2: an arrow each, sqrt-scaled
    xor     ebx, ebx
4:  xor     r12d, r12d
41: xor     r13d, r13d
42: imul    rax, r14, 16
    lea     rcx, [rip+fo_acc]
    movaps  xmm0, [rcx+rax]
    movaps  xmm1, xmm0
    dpps    xmm1, xmm1, 0x71
    sqrtss  xmm1, xmm1                  # its size
    movss   xmm2, [rip+fo_max]
    mulss   xmm2, [rip+fo_tiny]
    comiss  xmm1, xmm2
    jbe     43f
    movss   xmm2, xmm1                  # length: cell sqrt(s / max)
    divss   xmm2, [rip+fo_max]
    sqrtss  xmm2, xmm2
    mulss   xmm2, [rip+fo_cell]
    divss   xmm2, xmm1
    shufps  xmm2, xmm2, 0
    mulps   xmm0, xmm2
    movaps  [rsp], xmm0
    call    fo_point
    movaps  xmm3, [rip+fo_p]
    addps   xmm3, [rsp]
    movaps  [rip+fo_q], xmm3
    movss   xmm0, [rip+fo_p]
    movss   xmm1, [rip+fo_p+4]
    movss   xmm2, [rip+fo_p+8]
    movss   xmm3, [rip+fo_q]
    movss   xmm4, [rip+fo_q+4]
    movss   xmm5, [rip+fo_q+8]
    call    fd_arrow
    inc     dword ptr [rip+fo_na]
43: inc     r14d
    inc     r13d
    cmp     r13d, FO_NX
    jb      42b
    inc     r12d
    cmp     r12d, FO_NY
    jb      41b
    inc     ebx
    cmp     ebx, FO_NX
    jb      4b

.Lfo_lines:                             # streamlines from the selected objects
    cmp     dword ptr [rip+fl_show_l], 0
    je      .Lfo_out
    xor     ebx, ebx
5:  cmp     ebx, [rip+obj_count]
    jae     .Lfo_out
    mov     edi, ebx
    call    obj_at
    inc     ebx
    test    dword ptr [rax+OB_FLAGS], OBF_SELECTED
    jz      5b
    test    dword ptr [rax+OB_FLAGS], OBF_HIDDEN
    jnz     5b
    movups  xmm0, [rax+OB_LOC]
    andps   xmm0, [rip+fq_xyz]
    movaps  [rsp], xmm0                 # its place
    movss   xmm0, [rax+OB_SCALE]        # the seeds' ring: its size
    maxss   xmm0, [rip+fq_one]
    mulss   xmm0, [rip+fo_seed_r]
    movss   [rsp+16], xmm0
    xor     r12d, r12d                  # seed: two rings of 8 in XZ
6:  cmp     r12d, FO_SEEDS
    jae     5b
    mov     eax, r12d
    and     eax, 7
    cvtsi2ss xmm0, eax
    mulss   xmm0, [rip+fq_2pi]
    mulss   xmm0, [rip+fo_eighth]
    call    sincos
    mulss   xmm0, [rsp+16]              # (r sin, h, r cos)
    mulss   xmm1, [rsp+16]
    movss   xmm2, [rsp+16]
    mulss   xmm2, [rip+fo_ring_y]
    cmp     r12d, 8
    jb      61f
    xorps   xmm2, [rip+fq_sign]
61: unpcklps xmm0, xmm2
    movlhps xmm0, xmm1
    addps   xmm0, [rsp]
    andps   xmm0, [rip+fq_xyz]
    movaps  [rip+fo_p], xmm0
    xor     r13d, r13d
7:  cmp     r13d, FO_STEPS
    jae     8f
    movaps  xmm0, [rip+fo_p]            # RK2: half a step along it, then
    call    fo_pull                     #  a step along it there
    comiss  xmm1, [rip+fo_eps]
    jbe     8f
    shufps  xmm1, xmm1, 0
    divps   xmm0, xmm1
    mulps   xmm0, [rip+fo_hstep4]
    addps   xmm0, [rip+fo_p]
    call    fo_pull
    comiss  xmm1, [rip+fo_eps]
    jbe     8f
    shufps  xmm1, xmm1, 0
    divps   xmm0, xmm1
    mulps   xmm0, [rip+fo_step4]
    addps   xmm0, [rip+fo_p]
    andps   xmm0, [rip+fq_xyz]
    movaps  [rip+fo_q], xmm0
    movss   xmm0, [rip+fo_p]
    movss   xmm1, [rip+fo_p+4]
    movss   xmm2, [rip+fo_p+8]
    movss   xmm3, [rip+fo_q]
    movss   xmm4, [rip+fo_q+4]
    movss   xmm5, [rip+fo_q+8]
    call    fd_seg
    inc     dword ptr [rip+fo_nl]
    movaps  xmm0, [rip+fo_q]
    movaps  [rip+fo_p], xmm0
    inc     r13d
    jmp     7b
8:  inc     r12d
    jmp     6b
.Lfo_out:
    lea     rsp, [rbp-32]
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret

# fl_info(edi=what) -> xmm0: 0 force fields in the scene, 1 the overlay's
#   arrows (last drawn), 2 its line segments, 3 the largest pull it showed
fl_info:
    xorps   xmm0, xmm0
    cmp     edi, 1
    jne     1f
    cvtsi2ss xmm0, dword ptr [rip+fo_na]
    ret
1:  cmp     edi, 2
    jne     2f
    cvtsi2ss xmm0, dword ptr [rip+fo_nl]
    ret
2:  cmp     edi, 3
    jne     3f
    movss   xmm0, [rip+fo_max]
    ret
3:  test    edi, edi
    jnz     9f
    push    rbx
    push    r12
    sub     rsp, 8
    xor     ebx, ebx
    xor     r12d, r12d
4:  cmp     ebx, [rip+obj_count]
    jae     5f
    mov     edi, ebx
    call    obj_at
    inc     ebx
    cmp     dword ptr [rax+OB_TYPE], OT_FIELD
    jne     4b
    inc     r12d
    jmp     4b
5:  cvtsi2ss xmm0, r12d
    add     rsp, 8
    pop     r12
    pop     rbx
9:  ret

.section .rodata
.align 16
fo_ex:          .float 1, 0, 0, 0
fo_ey:          .float 0, 1, 0, 0
fo_ez:          .float 0, 0, 1, 0
fo_big4:        .float 1e30, 1e30, 1e30, 0
fo_nbig4:       .float -1e30, -1e30, -1e30, 0
fo_half4:       .float 0.5, 0.5, 0.5, 0
fo_two4:        .float 2, 2, 2, 0
fo_one4:        .float 1, 1, 1, 0
fo_nm1:         .float 8, 4, 8, 1               # (n - 1 per axis)
fo_extra4:      .float 3, 3, 3, 0
fo_minh4:       .float 4, 2, 4, 0
fo_maxh4:       .float 60, 30, 60, 0
fo_step4:       .float 0.25, 0.25, 0.25, 0
fo_hstep4:      .float 0.125, 0.125, 0.125, 0
.align 4
fo_ten:         .float 10.0
fo_tiny:        .float 0.001
fo_eighth:      .float 0.125
fo_ring_y:      .float 0.3

.section .note.GNU-stack,"",@progbits
