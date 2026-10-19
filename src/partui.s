# =============================================================================
#  BeeModel - the Particles tab of the Properties area (P6). For the active
#  object: its particle systems (the one picked by number, its name), Add (a
#  preset or an empty system) and Remove; then sections that fold:
#    - Emission: from where (faces, volume, vertices, point, events, a fill),
#      at a rate or all at once, how many, from and until which frame.
#    - Motion: lifetime, speed, spread, gravity, drag (and how random).
#    - Look: points, sprites or objects; size (at the end too), the colour
#      and the colour it ends with.
#    - Collisions: on, bounce, friction, what a hit does.
#    - Liquid (closed at first): on, viscosity, vorticity, tension, substeps,
#      iterations, the surface.
#    - Cache: frames and memory, Bake, Free (sim.bake particles liquid).
#  The values come from the record each frame into pu_rec; a change writes
#  pu_rec back into the owned record (after the widget's own undo step).
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"
.include "widgets.inc"

.globl part_props

.section .bss
.align 16
pu_rec:         .skip PS_SZ             # the system's values, as shown
pu_c1:          .skip 16                # its colours (linear, the swatches)
pu_c2:          .skip 16
.align 4
pu_sel:         .skip 4                 # the system picked (1 ..)
pu_n:           .skip 4                 # systems on the object
pu_add:         .skip 4                 # (the Add list: what was picked)
pu_coll:        .skip 4                 # (toggles: bit 0 of their words)
pu_ramp:        .skip 4
pu_liq:         .skip 4
pu_surf:        .skip 4
pu_render:      .skip 4
pu_text:        .skip 96

.section .rodata
s_c_from:       .asciz "From"
s_c_mode:       .asciz "Emits"
s_c_draw:       .asciz "Drawn as"
s_c_hit:        .asciz "On a hit"
s_none:         .asciz "No particle systems: add one (a preset, or an empty system)."
s_noobj:        .asciz "Select an object to emit particles from."
s_of:           .asciz " of "
s_sys:          .asciz "System "
s_colon:        .asciz ": "
s_alive:        .asciz " particles now"
s_cache:        .asciz "Cached: "
s_frames:       .asciz " + "
s_fr:           .asciz " frames, "
s_mb:           .asciz " MB"
s_baked:        .asciz " (baked)"
l_faces:        .asciz "Faces"
l_volume:       .asciz "Volume"
l_verts:        .asciz "Vertices"
l_point:        .asciz "Point"
l_events:       .asciz "Events"
l_fill:         .asciz "Fill"
l_rate:         .asciz "At a rate"
l_burst:        .asciz "All at once"
l_points:       .asciz "Points"
l_sprites:      .asciz "Sprites"
l_objects:      .asciz "Objects"
l_bounce:       .asciz "Bounces"
l_die:          .asciz "Dies"
l_stick:        .asciz "Sticks"
l_split:        .asciz "Splits"
l_addsys:       .asciz "Add System..."
l_rain:         .asciz "Rain"
l_snow:         .asciz "Snow"
l_sparks:       .asciz "Sparks"
l_confetti:     .asciz "Confetti"
l_fountain:     .asciz "Fountain"
l_tank:         .asciz "Water Tank"
l_empty:        .asciz "Empty"
k_rain:         .asciz "rain"
k_snow:         .asciz "snow"
k_sparks:       .asciz "sparks"
k_confetti:     .asciz "confetti"
k_fountain:     .asciz "fountain"
k_tank:         .asciz "tank"
k_empty:        .asciz ""
k_system:       .asciz "system "
k_bake:         .asciz "particles liquid"
.align 8
pu_froms:       .quad l_faces, l_volume, l_verts, l_point, l_events, l_fill
pu_modes:       .quad l_rate, l_burst
pu_draws:       .quad l_points, l_sprites, l_objects
pu_hits:        .quad l_bounce, l_die, l_stick, l_split
pu_adds:        .quad l_addsys, l_rain, l_snow, l_sparks, l_confetti, l_fountain, l_tank, l_empty
pu_addk:        .quad k_rain, k_snow, k_sparks, k_confetti, k_fountain, k_tank, k_empty

.text
WIDGET wd_pu_add,    WK_ENUM, "particles.add_list", cb=add_cb, aux=pu_adds, n=8, tip="A new particle system on the active object: a preset, or an empty one"
WIDGET wd_pu_sel,    WK_INT, "particles.system", "System", 1.0, 64.0, 0.05, 0, WGF_CLAMP, tip="Which of the object's systems the settings below are"
WIDGET wd_pu_rem,    WK_BUTTON, "particles.remove_btn", "Remove", tip="Remove the system picked"
WIDGET wd_pu_semit,  WK_SECTION, "particles.section.emission", "Emission"
WIDGET wd_pu_smove,  WK_SECTION, "particles.section.motion", "Motion"
WIDGET wd_pu_slook,  WK_SECTION, "particles.section.look", "Look"
WIDGET wd_pu_scoll,  WK_SECTION, "particles.section.collisions", "Collisions", flags=WGF_SHUT
WIDGET wd_pu_sliq,   WK_SECTION, "particles.section.liquid", "Liquid", flags=WGF_SHUT
WIDGET wd_pu_scache, WK_SECTION, "particles.section.cache", "Cache", flags=WGF_SHUT
WIDGET wd_pu_from,   WK_ENUM, "particles.from", cb=val_cb, undo="Particles", aux=pu_froms, n=6, tip="Where they are born: on its faces (by area), inside it, at its vertices, at its origin, from another system's events, or on a lattice filling it (liquids)"
WIDGET wd_pu_mode,   WK_ENUM, "particles.mode", cb=val_cb, undo="Particles", aux=pu_modes, n=2, tip="Born steadily from the start to the end frame, or all at once at the start"
WIDGET wd_pu_rate,   WK_FLOAT, "particles.rate", "A second", 0.0, 10000000.0, 1.0, 0, WGF_CLAMP, cb=val_cb, undo="Particles", tip="How many are born a second"
WIDGET wd_pu_num,    WK_INT, "particles.count", "How many", 0.0, 4194304.0, 1.0, 0, WGF_CLAMP, cb=val_cb, undo="Particles", tip="How many are born at once"
WIDGET wd_pu_start,  WK_FLOAT, "particles.start", "From frame", -100000.0, 100000.0, 0.2, 0, WGF_CLAMP, cb=val_cb, undo="Particles", tip="The frame they start being born"
WIDGET wd_pu_end,    WK_FLOAT, "particles.end", "Until frame", -100000.0, 1000000.0, 0.2, 0, WGF_CLAMP, cb=val_cb, undo="Particles", tip="The frame they stop being born"
WIDGET wd_pu_life,   WK_FLOAT, "particles.life", "Lifetime (s)", 0.0, 100000.0, 0.02, 2, WGF_CLAMP, cb=val_cb, undo="Particles", tip="How long each lives"
WIDGET wd_pu_lifer,  WK_SLIDER, "particles.life_random", "Lifetime random", 0.0, 1.0, 0.01, 2, cb=val_cb, undo="Particles", tip="Some live shorter, by up to this part"
WIDGET wd_pu_speed,  WK_FLOAT, "particles.speed", "Speed (m/s)", -10000.0, 10000.0, 0.05, 2, WGF_CLAMP, cb=val_cb, undo="Particles", tip="How fast they are born, along the surface's normal (or the direction)"
WIDGET wd_pu_speedr, WK_SLIDER, "particles.speed_random", "Speed random", 0.0, 1.0, 0.01, 2, cb=val_cb, undo="Particles", tip="Faster or slower by up to this part"
WIDGET wd_pu_spread, WK_FLOAT, "particles.spread", "Spread (deg)", 0.0, 180.0, 0.5, 1, WGF_CLAMP, cb=val_cb, undo="Particles", tip="A cone round their way: 0 all the same way, 180 every way"
WIDGET wd_pu_grav,   WK_FLOAT, "particles.gravity", "Gravity", -100.0, 100.0, 0.02, 2, WGF_CLAMP, cb=val_cb, undo="Particles", def=1.0, tip="How much gravity pulls them (1: as everything else)"
WIDGET wd_pu_drag,   WK_FLOAT, "particles.drag", "Drag (1/s)", 0.0, 1000.0, 0.02, 2, WGF_CLAMP, cb=val_cb, undo="Particles", tip="How fast the air slows them"
WIDGET wd_pu_draw,   WK_ENUM, "particles.draw", cb=val_cb, undo="Particles", aux=pu_draws, n=3, tip="Drawn as points (a few pixels), sprites (round, their size) or objects (set with particles.set objects A,B)"
WIDGET wd_pu_size,   WK_FLOAT, "particles.size", "Size (m)", 0.0, 1000.0, 0.002, 3, WGF_CLAMP, cb=val_cb, undo="Particles", tip="How big each is (a liquid: its spacing)"
WIDGET wd_pu_sizer,  WK_SLIDER, "particles.size_random", "Size random", 0.0, 1.0, 0.01, 2, cb=val_cb, undo="Particles", tip="Bigger or smaller by up to this part"
WIDGET wd_pu_sizee,  WK_FLOAT, "particles.size_end", "Size at the end", 0.0, 100.0, 0.02, 2, WGF_CLAMP, cb=val_cb, undo="Particles", def=1.0, tip="Its size times this at the end of its life"
WIDGET wd_pu_col,    WK_COLOR, "particles.color", cb=val_cb, undo="Particles", tip="Their colour"
WIDGET wd_pu_ramp,   WK_TOGGLE, "particles.ramp", "Changes to", cb=val_cb, undo="Particles", tip="Their colour changes over their life to this one"
WIDGET wd_pu_col2,   WK_COLOR, "particles.color_end", cb=val_cb, undo="Particles", tip="The colour they end with"
WIDGET wd_pu_render, WK_TOGGLE, "particles.render", "In renders", cb=val_cb, undo="Particles", tip="Rendered (as balls, or the objects) - off: only in the viewport"
WIDGET wd_pu_coll,   WK_TOGGLE, "particles.collide", "Collide", cb=val_cb, undo="Particles", tip="They hit the ground, landscapes, rigid bodies and cloth colliders"
WIDGET wd_pu_bounce, WK_SLIDER, "particles.bounce", "Bounce", 0.0, 1.0, 0.01, 2, cb=val_cb, undo="Particles", tip="How much of their speed into a surface comes back"
WIDGET wd_pu_fric,   WK_SLIDER, "particles.friction", "Friction", 0.0, 1.0, 0.01, 2, cb=val_cb, undo="Particles", tip="How much of their speed along it is lost"
WIDGET wd_pu_hit,    WK_ENUM, "particles.on_hit", cb=val_cb, undo="Particles", aux=pu_hits, n=4, tip="What a hit does"
WIDGET wd_pu_liq,    WK_TOGGLE, "particles.liquid", "Liquid", cb=val_cb, undo="Particles", tip="They flow as a liquid (position-based fluids): their size is the spacing"
WIDGET wd_pu_visc,   WK_FLOAT, "particles.viscosity", "Viscosity", 0.0, 1.0, 0.005, 3, WGF_CLAMP, cb=val_cb, undo="Particles", tip="Water 0.02, oil 0.2, honey 0.6"
WIDGET wd_pu_vort,   WK_FLOAT, "particles.vorticity", "Vorticity", 0.0, 100.0, 0.01, 2, WGF_CLAMP, cb=val_cb, undo="Particles", tip="Keeps its swirls alive"
WIDGET wd_pu_tens,   WK_FLOAT, "particles.tension", "Surface tension", 0.0, 10.0, 0.01, 2, WGF_CLAMP, cb=val_cb, undo="Particles", tip="Holds drops together"
WIDGET wd_pu_lsub,   WK_INT, "particles.substeps", "Substeps", 1.0, 32.0, 0.05, 0, WGF_CLAMP, cb=val_cb, undo="Particles", tip="Steps a frame: more for tall water"
WIDGET wd_pu_liter,  WK_INT, "particles.iterations", "Iterations", 1.0, 50.0, 0.05, 0, WGF_CLAMP, cb=val_cb, undo="Particles", tip="Solver passes a substep"
WIDGET wd_pu_surf,   WK_TOGGLE, "particles.surface", "Surface", cb=val_cb, undo="Particles", tip="Meshed into a surface each frame (its object shows it)"
WIDGET wd_pu_bake,   WK_BUTTON, "particles.bake", "Bake", aux=op_pu_bake, tip="Simulate the frame range and keep every frame of the particles (saved with the file)"
WIDGET wd_pu_free,   WK_BUTTON, "particles.free", "Free", aux=op_pu_free, tip="Forget the particles' cache and bake"

OPERATOR op_pu_bake, "particles.bake", "Bake Particles", do_pu_bake, flags=OPF_AI_SAFE, doc="Bake the particles and liquids (sim.bake particles liquid)"
OPERATOR op_pu_free, "particles.free", "Free Particles Cache", do_pu_free, flags=OPF_AI_SAFE, doc="Free the particles' and liquids' cache and bake (sim.free particles liquid)"

do_pu_bake:
    lea     rdi, [rip+op_sim_bake]
    jmp     pu_sim
do_pu_free:
    lea     rdi, [rip+op_sim_free]
pu_sim:
    push    rbx
    push    qword ptr [rip+op_arg]
    sub     rsp, 8
    lea     rax, [rip+k_bake]
    mov     [rip+op_arg], rax
    call    run_op
    add     rsp, 8
    pop     qword ptr [rip+op_arg]
    pop     rbx
    ret

# pu_obj -> rax = the active object (0: none)
pu_obj:
    sub     rsp, 8
    mov     edi, [rip+active_obj]
    call    obj_get
    add     rsp, 8
    ret

# val_cb - pu_rec (and the toggles, the colours) into the system picked
val_cb:
    push    rbx
    call    pu_obj
    test    rax, rax
    jz      9f
    mov     edi, [rax+OB_UID]
    mov     esi, [rip+pu_sel]
    dec     esi
    call    ps_nth_own
    test    rax, rax
    jz      9f
    mov     rbx, rax
    mov     eax, [rip+pu_coll]          # the toggles
    and     dword ptr [rip+pu_rec+PS_COLL], ~1
    and     eax, 1
    or      [rip+pu_rec+PS_COLL], eax
    mov     eax, [rip+pu_ramp]
    and     dword ptr [rip+pu_rec+PS_RAMP], ~1
    and     eax, 1
    or      [rip+pu_rec+PS_RAMP], eax
    mov     eax, [rip+pu_liq]
    and     dword ptr [rip+pu_rec+PS_LIQ], ~1
    and     eax, 1
    or      [rip+pu_rec+PS_LIQ], eax
    mov     eax, [rip+pu_surf]
    and     dword ptr [rip+pu_rec+PS_SURF], ~1
    and     eax, 1
    or      [rip+pu_rec+PS_SURF], eax
    or      dword ptr [rip+pu_rec+PS_RFLAGS], 1
    cmp     dword ptr [rip+pu_render], 0
    je      1f
    and     dword ptr [rip+pu_rec+PS_RFLAGS], ~1
1:  lea     rdi, [rip+pu_c1]            # the colours
    call    cpk_rgb_of
    mov     [rip+pu_rec+PS_COLOR], eax
    lea     rdi, [rip+pu_c2]
    call    cpk_rgb_of
    mov     [rip+pu_rec+PS_COLOR2], eax
    lea     rsi, [rip+pu_rec+4]         # the rest (its uid stays)
    lea     rdi, [rbx+4]
    mov     ecx, PS_SZ-4
    rep     movsb
    mov     dword ptr [rip+dirty], 1
9:  pop     rbx
    ret

# add_cb - the Add list: a preset (or an empty system) on the object
add_cb:
    mov     eax, [rip+pu_add]
    mov     dword ptr [rip+pu_add], 0
    test    eax, eax
    jz      9f
    push    rbx
    lea     rcx, [rip+pu_addk]
    mov     rax, [rcx+rax*8-8]
    push    qword ptr [rip+op_arg]
    sub     rsp, 8
    mov     [rip+op_arg], rax
    lea     rdi, [rip+op_ps_add]
    call    run_op
    add     rsp, 8
    pop     qword ptr [rip+op_arg]
    call    pu_obj                      # (the new one picked)
    test    rax, rax
    jz      8f
    mov     edi, [rax+OB_UID]
    call    ps_count
    mov     [rip+pu_sel], eax
8:  mov     dword ptr [rip+dirty], 1
    pop     rbx
9:  ret

# pu_cap(rdi=desc, r8=ptr, rdx=caption) - caption left, the field right
pu_cap:
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

# pu_section(rdi=desc) -> eax = 1 when open (r12d past it)
pu_section:
    mov     esi, [rip+pnl_x]
    sub     esi, 6
    mov     ecx, [rip+pnl_w]
    add     ecx, 12
    mov     edx, r12d
    xor     r8d, r8d
    xor     r9d, r9d
    sub     rsp, 8
    call    wg
    add     rsp, 8
    add     r12d, 28
    ret

# pu_line(rdx=text: fmt_buf) - a hint line from fmt_buf
pu_line:
    lea     rdx, [rip+fmt_buf]
    lea     rdi, [rip+pu_text]
    mov     rsi, rdx
    mov     ecx, 95
1:  mov     al, [rsi]
    mov     [rdi], al
    test    al, al
    jz      2f
    inc     rsi
    inc     rdi
    dec     ecx
    jnz     1b
    mov     byte ptr [rdi], 0
2:  lea     rdx, [rip+pu_text]
    jmp     pnl_hint

# part_props(edi=y) -> eax = y below: the Particles page (pnl_begin done
#   here)
part_props:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r12d, edi
    call    pnl_begin
    call    pu_obj
    test    rax, rax
    jnz     1f
    lea     rdx, [rip+s_noobj]
    call    pnl_hint
    jmp     .Lpu_out
1:  mov     rbx, rax                    # the object, its systems
    mov     edi, [rbx+OB_UID]
    call    ps_count
    mov     [rip+pu_n], eax
    mov     dword ptr [rip+pu_add], 0
    lea     rdi, [rip+wd_pu_add]
    lea     r8, [rip+pu_add]
    call    pnl_full
    cmp     dword ptr [rip+pu_n], 0
    jne     2f
    lea     rdx, [rip+s_none]
    call    pnl_hint
    jmp     .Lpu_out
2:  mov     eax, [rip+pu_sel]           # the one picked (1 .. n)
    cmp     eax, 1
    jge     21f
    mov     eax, 1
21: cmp     eax, [rip+pu_n]
    jle     22f
    mov     eax, [rip+pu_n]
22: mov     [rip+pu_sel], eax
    lea     rdi, [rip+wd_pu_sel]
    lea     r8, [rip+pu_sel]
    call    pnl_left
    lea     rdi, [rip+wd_pu_rem]
    xor     r8d, r8d
    call    pnl_right
    add     r12d, WG_H+4
    test    eax, eax
    jz      23f
    call    fmt_reset                   # Remove: particles.remove system n
    lea     rdi, [rip+k_system]
    call    fmt_str
    mov     edi, [rip+pu_sel]
    call    fmt_int
    lea     rax, [rip+fmt_buf]
    lea     rdi, [rip+pu_text]
    mov     rsi, rax
    mov     ecx, 95
    rep     movsb
    push    qword ptr [rip+op_arg]
    push    qword ptr [rip+op_arg]
    lea     rax, [rip+pu_text]
    mov     [rip+op_arg], rax
    lea     rdi, [rip+op_ps_remove]
    call    run_op
    pop     rax
    pop     qword ptr [rip+op_arg]
    mov     dword ptr [rip+dirty], 1
    jmp     .Lpu_out
23: mov     edi, [rbx+OB_UID]           # its values
    mov     esi, [rip+pu_sel]
    dec     esi
    call    ps_nth
    test    rax, rax
    jz      .Lpu_out
    mov     r13, rax
    lea     rdi, [rip+pu_rec]
    mov     rsi, r13
    mov     ecx, PS_SZ
    rep     movsb
    mov     eax, [r13+PS_COLL]
    and     eax, 1
    mov     [rip+pu_coll], eax
    mov     eax, [r13+PS_RAMP]
    and     eax, 1
    mov     [rip+pu_ramp], eax
    mov     eax, [r13+PS_LIQ]
    and     eax, 1
    mov     [rip+pu_liq], eax
    mov     eax, [r13+PS_SURF]
    and     eax, 1
    mov     [rip+pu_surf], eax
    mov     eax, [r13+PS_RFLAGS]
    not     eax
    and     eax, 1
    mov     [rip+pu_render], eax
    mov     eax, [r13+PS_COLOR]
    lea     rdi, [rip+pu_c1]
    call    cpk_put
    mov     eax, [r13+PS_COLOR2]
    lea     rdi, [rip+pu_c2]
    call    cpk_put
    call    fmt_reset                   # "System 1 of 2: Rain"
    lea     rdi, [rip+s_sys]
    call    fmt_str
    mov     edi, [rip+pu_sel]
    call    fmt_int
    lea     rdi, [rip+s_of]
    call    fmt_str
    mov     edi, [rip+pu_n]
    call    fmt_int
    lea     rdi, [rip+s_colon]
    call    fmt_str
    lea     rdi, [r13+PS_NAME]
    call    fmt_str
    call    pu_line
    add     r12d, 4

    lea     rdi, [rip+wd_pu_semit]      # ---- emission
    call    pu_section
    test    eax, eax
    jz      .Lpu_move
    lea     rdi, [rip+wd_pu_from]
    lea     r8, [rip+pu_rec+PS_FROM]
    lea     rdx, [rip+s_c_from]
    call    pu_cap
    lea     rdi, [rip+wd_pu_mode]
    lea     r8, [rip+pu_rec+PS_MODE]
    lea     rdx, [rip+s_c_mode]
    call    pu_cap
    cmp     dword ptr [rip+pu_rec+PS_MODE], 0
    jne     3f
    lea     rdi, [rip+wd_pu_rate]
    lea     r8, [rip+pu_rec+PS_RATE]
    call    pnl_full
    lea     rdi, [rip+wd_pu_start]
    lea     r8, [rip+pu_rec+PS_START]
    call    pnl_full
    lea     rdi, [rip+wd_pu_end]
    lea     r8, [rip+pu_rec+PS_END]
    call    pnl_full
    jmp     .Lpu_move
3:  lea     rdi, [rip+wd_pu_num]
    lea     r8, [rip+pu_rec+PS_NUM]
    call    pnl_full
    lea     rdi, [rip+wd_pu_start]
    lea     r8, [rip+pu_rec+PS_START]
    call    pnl_full

.Lpu_move:
    lea     rdi, [rip+wd_pu_smove]      # ---- motion
    call    pu_section
    test    eax, eax
    jz      .Lpu_look
    lea     rdi, [rip+wd_pu_life]
    lea     r8, [rip+pu_rec+PS_LIFE]
    call    pnl_full
    lea     rdi, [rip+wd_pu_lifer]
    lea     r8, [rip+pu_rec+PS_LIFER]
    call    pnl_full
    lea     rdi, [rip+wd_pu_speed]
    lea     r8, [rip+pu_rec+PS_SPEED]
    call    pnl_full
    lea     rdi, [rip+wd_pu_speedr]
    lea     r8, [rip+pu_rec+PS_SPEEDR]
    call    pnl_full
    lea     rdi, [rip+wd_pu_spread]
    lea     r8, [rip+pu_rec+PS_SPREAD]
    call    pnl_full
    lea     rdi, [rip+wd_pu_grav]
    lea     r8, [rip+pu_rec+PS_GRAV]
    call    pnl_full
    lea     rdi, [rip+wd_pu_drag]
    lea     r8, [rip+pu_rec+PS_DRAG]
    call    pnl_full

.Lpu_look:
    lea     rdi, [rip+wd_pu_slook]      # ---- look
    call    pu_section
    test    eax, eax
    jz      .Lpu_coll
    lea     rdi, [rip+wd_pu_draw]
    lea     r8, [rip+pu_rec+PS_DRAW]
    lea     rdx, [rip+s_c_draw]
    call    pu_cap
    lea     rdi, [rip+wd_pu_size]
    lea     r8, [rip+pu_rec+PS_SIZE]
    call    pnl_full
    lea     rdi, [rip+wd_pu_sizer]
    lea     r8, [rip+pu_rec+PS_SIZER]
    call    pnl_full
    lea     rdi, [rip+wd_pu_sizee]
    lea     r8, [rip+pu_rec+PS_SIZEEND]
    call    pnl_full
    lea     rdi, [rip+wd_pu_col]
    lea     r8, [rip+pu_c1]
    call    pnl_full
    lea     rdi, [rip+wd_pu_ramp]
    lea     r8, [rip+pu_ramp]
    call    pnl_left
    cmp     dword ptr [rip+pu_ramp], 0
    je      4f
    lea     rdi, [rip+wd_pu_col2]
    lea     r8, [rip+pu_c2]
    call    pnl_right
4:  add     r12d, WG_H+4
    lea     rdi, [rip+wd_pu_render]
    lea     r8, [rip+pu_render]
    call    pnl_full

.Lpu_coll:
    lea     rdi, [rip+wd_pu_scoll]      # ---- collisions
    call    pu_section
    test    eax, eax
    jz      .Lpu_liq
    lea     rdi, [rip+wd_pu_coll]
    lea     r8, [rip+pu_coll]
    call    pnl_full
    cmp     dword ptr [rip+pu_coll], 0
    je      .Lpu_liq
    lea     rdi, [rip+wd_pu_bounce]
    lea     r8, [rip+pu_rec+PS_BOUNCE]
    call    pnl_full
    lea     rdi, [rip+wd_pu_fric]
    lea     r8, [rip+pu_rec+PS_FRIC]
    call    pnl_full
    lea     rdi, [rip+wd_pu_hit]
    lea     r8, [rip+pu_rec+PS_ONHIT]
    lea     rdx, [rip+s_c_hit]
    call    pu_cap

.Lpu_liq:
    lea     rdi, [rip+wd_pu_sliq]       # ---- liquid
    call    pu_section
    test    eax, eax
    jz      .Lpu_cache
    lea     rdi, [rip+wd_pu_liq]
    lea     r8, [rip+pu_liq]
    call    pnl_full
    cmp     dword ptr [rip+pu_liq], 0
    je      .Lpu_cache
    lea     rdi, [rip+wd_pu_visc]
    lea     r8, [rip+pu_rec+PS_VISC]
    call    pnl_full
    lea     rdi, [rip+wd_pu_vort]
    lea     r8, [rip+pu_rec+PS_VORT]
    call    pnl_full
    lea     rdi, [rip+wd_pu_tens]
    lea     r8, [rip+pu_rec+PS_TENS]
    call    pnl_full
    lea     rdi, [rip+wd_pu_lsub]
    lea     r8, [rip+pu_rec+PS_LSUB]
    call    pnl_full
    lea     rdi, [rip+wd_pu_liter]
    lea     r8, [rip+pu_rec+PS_LITER]
    call    pnl_full
    lea     rdi, [rip+wd_pu_surf]
    lea     r8, [rip+pu_surf]
    call    pnl_full

.Lpu_cache:
    lea     rdi, [rip+wd_pu_scache]     # ---- cache
    call    pu_section
    test    eax, eax
    jz      .Lpu_out
    call    fmt_reset                   # "Cached: 120 + 0 frames, 3.2 MB"
    lea     rdi, [rip+s_cache]
    call    fmt_str
    mov     edi, 7
    call    sc_info
    cvttss2si edi, xmm0
    call    fmt_int
    lea     rdi, [rip+s_frames]
    call    fmt_str
    mov     edi, 8
    call    sc_info
    cvttss2si edi, xmm0
    call    fmt_int
    lea     rdi, [rip+s_fr]
    call    fmt_str
    mov     edi, 2
    call    sc_info
    call    fmt_fix1
    lea     rdi, [rip+s_mb]
    call    fmt_str
    mov     edi, 9
    call    sc_info
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    jbe     5f
    lea     rdi, [rip+s_baked]
    call    fmt_str
5:  call    pu_line
    lea     rdi, [rip+wd_pu_bake]
    xor     r8d, r8d
    call    pnl_left
    lea     rdi, [rip+wd_pu_free]
    xor     r8d, r8d
    call    pnl_right
    add     r12d, WG_H+4
.Lpu_out:
    add     r12d, 6
    mov     eax, r12d
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.section .note.GNU-stack,"",@progbits
