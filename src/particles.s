# =============================================================================
#  BeeModel - particle systems (stage P1): the core.
#
#  A particle system belongs to an emitter object (any object; an object can
#  have several). It emits from the faces (by area), the volume (inside the
#  closed mesh), the vertices or the object's origin; at a rate between two
#  frames, or all at once; each particle with a lifetime, a speed along the
#  normal or a direction of its own (object axes), in a cone of spread, a
#  size and a colour, each a little random when asked (a hash of the
#  system's seed and the particle's id, so the same on any number of
#  threads).
#
#  The settings are records by the emitter's uid in one block, reference
#  counted and copied on write like the force fields' (undo.s ST_PSYS),
#  kept in .bee files as a PSYS chunk.
#
#  The particles live in pooled blocks of 4096 (structure of arrays:
#  position, velocity, age, lifetime, size, colour, id, flags), 1024 blocks,
#  so 4 million at most. A step (one a frame, from the scene's start): every
#  block in parallel moves its particles (gravity, the force fields, drag:
#  x += v dt + a dt^2 / 2, then v += a dt - exact for a steady pull) and
#  drops the dead (in order); empty blocks go back to the pool; then each
#  system emits what was born during the step, each new particle moved on
#  from the moment it was born.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

.globl ps_cur
.globl ps_ref
.globl ps_unref
.globl ps_reset
.globl ps_write
.globl ps_read
.globl ps_copy
.globl ps_nth
.globl ps_count
.globl ps_add
.globl ps_parse
.globl pt_frame
.globl pt_reset
.globl pt_info
.globl pt_ns
.globl pt_sr
.globl pt_bn
.globl pt_pool
.globl sr_blk
.globl pt_draw
.globl pt_render
.globl pt_iblock
.globl pt_sphere
.globl pt_stamp
.globl pc_cast
.globl pc_any
.globl pc_gnd
.globl pc_gy

.equ PB_REFS,   0                       # the settings block
.equ PB_N,      4
.equ PB_BYTES,  8
.equ PB_HDR,    32
.equ PB_MAX,    64                      # systems in a scene
.equ PB_SIZE,   PB_HDR+PB_MAX*PS_SZ
.equ MAP_ANON_PRIV, 0x22
.equ MAP_NORES, 0x4022
.equ MADV_DONTNEED, 4
.equ AN_START,  24                      # (anim.s)
.equ AN_FPS,    32

# the pool: blocks of BLK particles, each array BLK floats
.equ BLK,       4096
.equ BLKSH,     12
.equ NBLK,      1024
.equ AR,        BLK*4
.equ A_X,       0
.equ A_Y,       AR
.equ A_Z,       2*AR
.equ A_VX,      3*AR
.equ A_VY,      4*AR
.equ A_VZ,      5*AR
.equ A_AGE,     6*AR
.equ A_LIFE,    7*AR
.equ A_SIZE,    8*AR
.equ A_COL,     9*AR
.equ A_ID,      10*AR
.equ A_FLAG,    11*AR
.equ NARR,      12
.equ BLK_BYTES, NARR*AR
.equ POOL_BYTES, NBLK*BLK_BYTES

# a running system
.equ SR_UID,    0
.equ SR_K,      4                       # which of its object's systems
.equ SR_NB,     8                       # blocks
.equ SR_N,      12                      # particles alive
.equ SR_NEXT,   16                      # the next id to be born
.equ SR_SRC,    20                      # where from, this step
.equ SR_MESH,   24                      # its object's mesh this step
.equ SR_MAT,    32                      # its object's matrix this step (3x4)
.equ SR_CDF,    80                      # faces: the areas summed (floats)
.equ SR_CDFN,   88                      #  triangles in it
.equ SR_CDFB,   92                      #  bytes mapped (/4096)
.equ SR_CDFK,   96                      #  what it was made for
.equ SR_REC,    104                     # its settings this step (or 0: off)
.equ SR_EN,     112                     # born this step: how many,
.equ SR_EID,    116                     #  the first one's id,
.equ SR_ELB,    120                     #  the last block before (-1: none),
.equ SR_EC,     124                     #  its count,
.equ SR_ER,     128                     #  its room,
.equ SR_ENB,    132                     #  blocks before
.equ SR_ACC,    144                     # gravity x its factor
.equ SR_GADJ,   160                     # gravity x (its factor - 1)
.equ SR_TS,     176                     # emitting from (s, double)
.equ SR_RATE,   184                     #  at (double)
.equ SR_T1,     192                     # the step's end (s, double)
.equ SR_GBIT,   200                     # its collision group's bit
.equ SR_DAMP,   204                     # 1 / (1 + drag dt)
.equ SR_SEED,   208
.equ SR_TOT,    212                     # faces: all of the area
.equ SR_SI,     216                     # its index
                                        # (220 .. 243: drawing, below)
.equ SR_LISTEN, 256                     # events to keep: 1 hits, 2 deaths
.equ SR_L0,     260                     # its blocks in pt_list this step: first,
.equ SR_LN,     264                     #  how many
.equ SR_NH,     268                     # this step's hits,
.equ SR_ND,     272                     #  deaths
.equ SR_EMODE,  276                     # being born from: 0 its source, 1 hits,
                                        #  2 births, 3 its own hits (split), 4 deaths
.equ SR_EVP,    280                     #  so many an event
.equ SR_ENEXT,  284                     #  the next id born of events
.equ SR_EVH,    288                     # its hits (event records), deaths
.equ SR_EVD,    296
.equ SR_EVS,    304                     # the system whose events it is born of
.equ SR_EVA,    312                     #  the events used now
.equ SR_SZ,     448
.equ EV_SZ,     48                      # an event: place (w: kind), velocity,
                                        #  the surface's normal
.equ EV_CAP,    2*BLK*NBLK              # (a system's events a step, at most)

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
.align 64
pt_sr:          .skip SR_SZ*PB_MAX
.align 16
pt_g:           .skip 16                # the world's gravity this step
.align 8
ps_cur:         .skip 8
pt_pool:        .skip 8
pt_hash:        .skip 8
pt_dtd:         .skip 8                 # the step (s, double)
pt_t0:          .skip 8                 # this step's start, end (s, double)
pt_t1:          .skip 8
.align 4
pt_bn:          .skip 4*NBLK            # each block's count
pt_bsys:        .skip 4*NBLK            #  and system
pt_freel:       .skip 4*NBLK            # blocks free (a stack)
pt_list:        .skip 4*NBLK            # this step's blocks
sr_blk:         .skip 4*NBLK*PB_MAX     # each system's blocks
pt_nfree:       .skip 4
pt_nlist:       .skip 4
pt_ns:          .skip 4                 # running systems
pt_on:          .skip 4
pt_now:         .skip 4                 # steps done
pt_busy:        .skip 4
pt_dt:          .skip 4                 # the step (s)
pt_fields:      .skip 4                 # force fields this step
pt_msf:         .skip 4                 # the last frame's time (ms)
pt_mss:         .skip 4                 #  and step's
pt_used:        .skip 4                 # blocks ever used (given back on reset)
ev_bh:          .skip 4*NBLK            # each listed block's hits this step,
ev_bd:          .skip 4*NBLK            #  deaths
.align 8
pt_stage:       .skip 8                 # events by listed block (2 x BLK each)
.align 16
pt_rec:         .skip PS_SZ             # (a record being made)
pt_name:        .skip 32

.section .rodata
.align 16
pq_xyz:         .long -1, -1, -1, 0
pq_w1:          .float 0, 0, 0, 1.0
pq_half4:       .float 0.5, 0.5, 0.5, 0.5
pq_sgn:         .long 0x80000000, 0x80000000, 0x80000000, 0x80000000
pq_tiny4:       .float 1e-20, 1e-20, 1e-20, 1e-20
pq_ex:          .float 1.0, 0, 0, 0
pq_ey:          .float 0, 1.0, 0, 0
.align 8
pd_one:         .double 1.0
pd_half:        .double 0.5
.align 4
pq_one:         .float 1.0
pq_two:         .float 2.0
pq_half:        .float 0.5
pq_24:          .float 24.0
pq_2pi:         .float 6.28318531
pq_deg:         .float 0.017453293
pq_u24:         .float 5.9604645e-8         # 2^-24
pq_tiny:        .float 1.0e-12
pq_k:           .float 0.001                # ms per microsecond
pq_bigf:        .float 1.0e9
pq_jit:         .float 0.00137

# the defaults (a new system)
.align 16
ps_defs:        .long 0, 0, 0, 0                # uid flags from mode
                .float 100.0                    # rate
                .long 1000                      # a burst's count
                .float 1.0, 1000000.0           # start end (frames)
                .float 3.0, 0.0                 # life, random
                .float 2.0, 0.0                 # speed, random
                .float 0.0, 1.0, 0.0            # direction
                .long 0                         # along the normal
                .float 0.0                      # spread
                .float 0.05, 0.0                # size, random
                .float 0.0, 1.0                 # drag, gravity
                .long 0x9fc8ff, 0, 0, 0         # colour seed group max
                .long 0, 0, 0
                .ascii "Particles"
                .skip 7
                .long 1, 0x9fc8ff, 0            # sprites, the end colour, no ramp
                .float 1.0                      # size at the end
                .long 0, 0, 0, 0, 0, 0, 0, 0    # objects
                .long 0, 0, 0                   # how many, align, render
                .float 2.0                      # points: pixels
                .long 0                         # collides: no
                .float 0.3, 0.1                 # bounce, friction
                .long 0, 2, 1, 3                # bounces, splits in 2; events: hits, 3 each
                .float 0.0                      # inherit
                .skip 16                        # the events' system
                .long 0                         # not a liquid
                .float 0.02, 0.0, 0.0           # viscosity, vorticity, tension
                .long 8, 2                      # substeps, iterations
                .float 0, 0, 0, 0, 0, 0         # the domain
                .long 0                         #  (off)
                .float 1000.0                   # density
                .skip PS_SZ-296

k_from:         .asciz "from"
k_faces:        .asciz "faces"
k_volume:       .asciz "volume"
k_verts:        .asciz "verts"
k_point:        .asciz "point"
k_rate:         .asciz "rate"
k_burst:        .asciz "burst"
k_start:        .asciz "start"
k_end:          .asciz "end"
k_life:         .asciz "life"
k_lifer:        .asciz "life_random"
k_speed:        .asciz "speed"
k_speedr:       .asciz "speed_random"
k_normal:       .asciz "normal"
k_dir:          .asciz "direction"
k_spread:       .asciz "spread"
k_size:         .asciz "size"
k_sizer:        .asciz "size_random"
k_drag:         .asciz "drag"
k_gravity:      .asciz "gravity"
k_color:        .asciz "color"
k_colour:       .asciz "colour"
k_seed:         .asciz "seed"
k_group:        .asciz "group"
k_max:          .asciz "max"
k_name:         .asciz "name"
k_on:           .asciz "on"
k_off:          .asciz "off"
k_system:       .asciz "system"
k_draw:         .asciz "draw"
k_points:       .asciz "points"
k_sprites:      .asciz "sprites"
k_objects:      .asciz "objects"
k_color_end:    .asciz "color_end"
k_colour_end:   .asciz "colour_end"
k_size_end:     .asciz "size_end"
k_align:        .asciz "align"
k_random:       .asciz "random"
k_velocity:     .asciz "velocity"
k_render:       .asciz "render"
k_px:           .asciz "point_px"
k_events:       .asciz "events"
k_collide:      .asciz "collide"
k_bounce:       .asciz "bounce"
k_friction:     .asciz "friction"
k_on_hit:       .asciz "on_hit"
k_die:          .asciz "die"
k_stick:        .asciz "stick"
k_split:        .asciz "split"
k_born:         .asciz "born"
k_hit:          .asciz "hit"
k_died:         .asciz "died"
k_per:          .asciz "per"
k_inherit:      .asciz "inherit"
k_fill:         .asciz "fill"
k_liquid:       .asciz "liquid"
k_viscosity:    .asciz "viscosity"
k_water:        .asciz "water"
k_oil:          .asciz "oil"
k_honey:        .asciz "honey"
k_vorticity:    .asciz "vorticity"
k_tension:      .asciz "tension"
k_substeps:     .asciz "substeps"
k_iterations:   .asciz "iterations"
k_domain:       .asciz "domain"
k_density:      .asciz "density"
s_bad:          .asciz "  particles: not understood: "
s_noobj:        .asciz "  particles: select the object to emit from first"
s_nosys:        .asciz "  particles: no such system on "
s_full:         .asciz "  particles: a scene has at most 64 systems"
s_added:        .asciz "  particles on "
s_removed:      .asciz "  particles removed from "
.align 8
kw_from:        .quad k_faces, k_volume, k_verts, k_point, k_events, k_fill, 0
kw_visc:        .quad k_water, k_oil, k_honey, 0
pq_viscs:       .float 0.02, 0.2, 0.6
kw_onhit:       .quad k_bounce, k_die, k_stick, k_split, 0
kw_ev:          .quad k_born, k_hit, k_died, 0
kw_draw:        .quad k_points, k_sprites, k_objects, 0
kw_align:       .quad k_random, k_velocity, 0
kw_onoff:       .quad k_off, k_on, 0
# particles.set words: (word, offset, kind, list); kinds: 0 float, 1 whole,
#   2 one of list, 5 on, 6 off, 7 colour, 8 rate, 9 burst, 10 normal,
#   11 direction (3 numbers), 12 a name, 13 the end colour, 14 objects by
#   name (A,B,C), 15 render on/off, 16 collide on/off, 17 events
#   born|hit|died NAME (from them), 18 split n
pp_tab:         .quad k_from
                .long PS_FROM, 2
                .quad kw_from
                .quad k_rate
                .long PS_RATE, 8
                .quad 0
                .quad k_burst
                .long PS_NUM, 9
                .quad 0
                .quad k_start
                .long PS_START, 0
                .quad 0
                .quad k_end
                .long PS_END, 0
                .quad 0
                .quad k_life
                .long PS_LIFE, 0
                .quad 0
                .quad k_lifer
                .long PS_LIFER, 0
                .quad 0
                .quad k_speed
                .long PS_SPEED, 0
                .quad 0
                .quad k_speedr
                .long PS_SPEEDR, 0
                .quad 0
                .quad k_normal
                .long PS_VMODE, 10
                .quad 0
                .quad k_dir
                .long PS_DIR, 11
                .quad 0
                .quad k_spread
                .long PS_SPREAD, 0
                .quad 0
                .quad k_size
                .long PS_SIZE, 0
                .quad 0
                .quad k_sizer
                .long PS_SIZER, 0
                .quad 0
                .quad k_drag
                .long PS_DRAG, 0
                .quad 0
                .quad k_gravity
                .long PS_GRAV, 0
                .quad 0
                .quad k_color
                .long PS_COLOR, 7
                .quad 0
                .quad k_colour
                .long PS_COLOR, 7
                .quad 0
                .quad k_seed
                .long PS_SEED, 1
                .quad 0
                .quad k_group
                .long PS_GROUP, 1
                .quad 0
                .quad k_max
                .long PS_MAX, 1
                .quad 0
                .quad k_name
                .long PS_NAME, 12
                .quad 0
                .quad k_draw
                .long PS_DRAW, 2
                .quad kw_draw
                .quad k_color_end
                .long PS_COLOR2, 13
                .quad 0
                .quad k_colour_end
                .long PS_COLOR2, 13
                .quad 0
                .quad k_size_end
                .long PS_SIZEEND, 0
                .quad 0
                .quad k_objects
                .long PS_OBJS, 14
                .quad 0
                .quad k_align
                .long PS_ALIGN, 2
                .quad kw_align
                .quad k_render
                .long PS_RFLAGS, 15
                .quad kw_onoff
                .quad k_px
                .long PS_PX, 0
                .quad 0
                .quad k_collide
                .long PS_COLL, 16
                .quad kw_onoff
                .quad k_bounce
                .long PS_BOUNCE, 0
                .quad 0
                .quad k_friction
                .long PS_FRIC, 0
                .quad 0
                .quad k_on_hit
                .long PS_ONHIT, 2
                .quad kw_onhit
                .quad k_split
                .long PS_SPLITN, 18
                .quad 0
                .quad k_events
                .long PS_EVKIND, 17
                .quad kw_ev
                .quad k_per
                .long PS_EVPER, 1
                .quad 0
                .quad k_inherit
                .long PS_INHERIT, 0
                .quad 0
                .quad k_liquid
                .long PS_LIQ, 16
                .quad kw_onoff
                .quad k_viscosity
                .long PS_VISC, 19
                .quad kw_visc
                .quad k_vorticity
                .long PS_VORT, 0
                .quad 0
                .quad k_tension
                .long PS_TENS, 0
                .quad 0
                .quad k_substeps
                .long PS_LSUB, 1
                .quad 0
                .quad k_iterations
                .long PS_LITER, 1
                .quad 0
                .quad k_domain
                .long PS_DOMAIN, 20
                .quad 0
                .quad k_density
                .long PS_DENS, 0
                .quad 0
                .quad k_on
                .long 0, 5
                .quad 0
                .quad k_off
                .long 0, 6
                .quad 0
                .quad 0

.text
OPERATOR op_ps_add,    "particles.add",    "Particle System", do_ps_add, flags=OPF_AI_SAFE|OPF_UNDO, doc="Add a particle system to the active object: particles.add [from faces|volume|verts|point] [rate n | burst n] [start f] [end f] [life s] [life_random 0..1] [speed m/s] [speed_random 0..1] [normal | direction x y z] [spread deg] [size m] [size_random 0..1] [drag k] [gravity k] [color RRGGBB] [seed n] [group 0..15] [max n] [name text] [on|off]"
OPERATOR op_ps_set,    "particles.set",    "Particle Settings", do_ps_set, flags=OPF_AI_SAFE|OPF_UNDO, doc="A particle system's settings on the active object: particles.set [system n] then the words particles.add takes"
OPERATOR op_ps_remove, "particles.remove", "Remove Particle System", do_ps_remove, flags=OPF_AI_SAFE|OPF_UNDO, doc="Remove a particle system from the active object: particles.remove [system n] (the first when not said)"

# =============================================================================
#  The settings block
# =============================================================================
ps_ref:
    test    rdi, rdi
    jz      1f
    lock inc dword ptr [rdi+PB_REFS]
1:  ret
ps_unref:
    test    rdi, rdi
    jz      1f
    lock dec dword ptr [rdi+PB_REFS]
    jnz     1f
    mov     rsi, [rdi+PB_BYTES]
    mov     eax, SYS_MUNMAP
    syscall
1:  ret
ps_reset:
    mov     rdi, [rip+ps_cur]
    mov     qword ptr [rip+ps_cur], 0
    jmp     ps_unref

ps_alloc:                               # -> rax = an empty block, or 0
    mov     esi, PB_SIZE
    xor     edi, edi
    mov     edx, PROT_RW
    mov     r10d, MAP_ANON_PRIV
    mov     r8d, -1
    xor     r9d, r9d
    mov     eax, SYS_MMAP
    syscall
    cmp     rax, -4096
    jbe     1f
    xor     eax, eax
    ret
1:  mov     dword ptr [rax+PB_REFS], 1
    mov     qword ptr [rax+PB_BYTES], PB_SIZE
    ret

# ps_own -> rax = ps_cur, unshared (made when none), or 0
ps_own:
    push    rbx
    mov     rbx, [rip+ps_cur]
    test    rbx, rbx
    jz      1f
    cmp     dword ptr [rbx+PB_REFS], 1
    jne     1f
    mov     rax, rbx
    pop     rbx
    ret
1:  call    ps_alloc
    test    rax, rax
    jz      9f
    test    rbx, rbx
    jz      2f
    mov     ecx, [rbx+PB_N]
    mov     [rax+PB_N], ecx
    imul    ecx, ecx, PS_SZ
    lea     rsi, [rbx+PB_HDR]
    lea     rdi, [rax+PB_HDR]
    rep     movsb
2:  mov     [rip+ps_cur], rax
    push    rax
    mov     rdi, rbx
    call    ps_unref
    pop     rax
9:  pop     rbx
    ret

# ps_nth(edi=uid, esi=k) -> rax = its object's k-th system (read only), or 0
ps_nth:
    mov     rax, [rip+ps_cur]
    test    rax, rax
    jz      8f
    mov     ecx, [rax+PB_N]
    lea     rax, [rax+PB_HDR]
1:  test    ecx, ecx
    jz      8f
    cmp     [rax+PS_UID], edi
    jne     2f
    test    esi, esi
    jz      9f
    dec     esi
2:  add     rax, PS_SZ
    dec     ecx
    jmp     1b
8:  xor     eax, eax
9:  ret

# ps_count(edi=uid) -> eax = its object's systems
ps_count:
    xor     eax, eax
    mov     rdx, [rip+ps_cur]
    test    rdx, rdx
    jz      9f
    mov     ecx, [rdx+PB_N]
    lea     rdx, [rdx+PB_HDR]
1:  test    ecx, ecx
    jz      9f
    cmp     [rdx+PS_UID], edi
    jne     2f
    inc     eax
2:  add     rdx, PS_SZ
    dec     ecx
    jmp     1b
9:  ret

# ps_nth_own(edi=uid, esi=k) -> rax = that system, writable, or 0
ps_nth_own:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     ebx, edi
    mov     r12d, esi
    call    ps_nth
    test    rax, rax
    jz      9f
    call    ps_own
    test    rax, rax
    jz      9f
    mov     edi, ebx
    mov     esi, r12d
    call    ps_nth
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# ps_new(edi=uid) -> rax = a new system with the defaults (writable), or 0
ps_new:
    push    rbx
    mov     ebx, edi
    call    ps_own
    test    rax, rax
    jz      9f
    mov     edx, [rax+PB_N]
    cmp     edx, PB_MAX
    jae     8f
    inc     dword ptr [rax+PB_N]
    imul    edx, edx, PS_SZ
    lea     rdi, [rax+PB_HDR+rdx]
    push    rdi
    lea     rsi, [rip+ps_defs]
    mov     ecx, PS_SZ
    rep     movsb
    pop     rax
    mov     [rax+PS_UID], ebx
    pop     rbx
    ret
8:  xor     eax, eax
9:  pop     rbx
    ret

# ps_del(edi=uid, esi=k) -> eax = 1 when there was one
ps_del:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     ebx, edi
    mov     r12d, esi
    call    ps_nth_own
    test    rax, rax
    jz      8f
    mov     rdx, [rip+ps_cur]
    mov     ecx, [rdx+PB_N]
    imul    ecx, ecx, PS_SZ
    lea     rcx, [rdx+PB_HDR+rcx]       # the end
    lea     rsi, [rax+PS_SZ]
    sub     rcx, rsi
    mov     rdi, rax
    rep     movsb
    dec     dword ptr [rdx+PB_N]
    mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# ps_copy(edi=uid, esi=new uid) - a duplicate's systems (object.duplicate)
ps_copy:
    push    rbx
    push    r12
    push    r13
    mov     ebx, edi
    mov     r12d, esi
    call    ps_count
    test    eax, eax
    jz      9f
    xor     r13d, r13d
1:  mov     edi, ebx
    call    ps_count
    cmp     r13d, eax
    jae     9f
    mov     edi, r12d
    call    ps_new
    test    rax, rax
    jz      9f
    push    rax
    push    rax
    mov     edi, ebx                    # (the block may have been copied)
    mov     esi, r13d
    call    ps_nth
    pop     rdi
    pop     rdi
    test    rax, rax
    jz      9f
    lea     rsi, [rax+4]
    add     rdi, 4
    mov     ecx, PS_SZ-4
    rep     movsb
    inc     r13d
    jmp     1b
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# ps_write - the records (formats.s: the PSYS chunk)
ps_write:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, [rip+ps_cur]
    xor     r12d, r12d
    test    rbx, rbx
    jz      1f
    mov     r12d, [rbx+PB_N]
1:  mov     edi, r12d
    call    wb_u32
    mov     edi, PS_SZ                  # (a record's size: newer ones grow)
    call    wb_u32
    test    r12d, r12d
    jz      9f
    lea     rsi, [rbx+PB_HDR]
    imul    edx, r12d, PS_SZ
    call    wb_bytes
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# ps_read(rdi=chunk, esi=size)
ps_read:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rbx, rdi
    mov     r12d, esi
    call    ps_reset
    cmp     r12d, 8
    jb      9f
    mov     r13d, [rbx]
    cmp     r13d, PB_MAX
    jbe     1f
    mov     r13d, PB_MAX
1:  mov     r14d, [rbx+4]               # a record's size in the file
    test    r14d, r14d
    jz      9f
    mov     eax, r14d
    imul    eax, r13d
    add     eax, 8
    cmp     eax, r12d
    ja      9f
    call    ps_alloc
    test    rax, rax
    jz      9f
    mov     [rip+ps_cur], rax
    mov     [rax+PB_N], r13d
    lea     r15, [rax+PB_HDR]
    lea     rbx, [rbx+8]
2:  test    r13d, r13d
    jz      9f
    mov     rdi, r15                    # the defaults, then what it has
    lea     rsi, [rip+ps_defs]
    mov     ecx, PS_SZ
    rep     movsb
    mov     rdi, r15
    mov     rsi, rbx
    mov     ecx, r14d
    cmp     ecx, PS_SZ
    jbe     3f
    mov     ecx, PS_SZ
3:  rep     movsb
    add     r15, PS_SZ
    add     rbx, r14
    dec     r13d
    jmp     2b
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  The words
# =============================================================================
# pp_word(rdi=list, 0 ended) -> eax = im_word's place in it, or -1
pp_word:
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

# world_box(rdi=object, rsi=out: min, max (6 floats)) -> eax = 1: its mesh's
#   bounds' corners in the world, their box
world_box:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12
    push    r13
    push    r14
    and     rsp, -16
    sub     rsp, 96
    mov     rbx, rdi
    mov     r12, rsi
    call    obj_eval
    test    rax, rax
    jz      8f
    mov     r13, rax
    mov     rdi, rbx
    lea     rsi, [rsp]
    call    obj_matrix
    movaps  xmm6, [rip+pq_bigw]
    movaps  xmm7, xmm6
    xorps   xmm7, [rip+pq_sgn]
    xor     r14d, r14d                  # the eight corners
1:  cmp     r14d, 8
    jae     2f
    xor     ecx, ecx
11: lea     rax, [r13+ME_BMIN]
    bt      r14d, ecx
    jnc     12f
    lea     rax, [r13+ME_BMAX]
12: mov     eax, [rax+rcx*4]
    mov     [rsp+48+rcx*4], eax
    inc     ecx
    cmp     ecx, 3
    jb      11b
    movups  xmm0, [rsp+48]
    lea     rdi, [rsp]
    call    m_pt
    minps   xmm6, xmm0
    maxps   xmm7, xmm0
    inc     r14d
    jmp     1b
2:  movlps  [r12], xmm6
    movhlps xmm0, xmm6
    movss   [r12+8], xmm0
    movlps  [r12+12], xmm7
    movhlps xmm0, xmm7
    movss   [r12+20], xmm0
    mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  lea     rsp, [rbp-32]
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret

# pp_hex(rdi=text) -> eax = its value (RRGGBB, # or 0x before it), edx = 1
#   when it was one
pp_hex:
    xor     eax, eax
    xor     edx, edx
    cmp     byte ptr [rdi], '#'
    jne     1f
    inc     rdi
1:  cmp     word ptr [rdi], 0x7830      # "0x"
    jne     2f
    add     rdi, 2
2:  movzx   ecx, byte ptr [rdi]
    test    ecx, ecx
    jz      9f
    inc     rdi
    sub     ecx, '0'
    cmp     ecx, 9
    jbe     3f
    or      ecx, 0x20                   # (a letter, either case)
    sub     ecx, 'a'-'0'
    cmp     ecx, 5
    ja      8f
    add     ecx, 10
3:  shl     eax, 4
    or      eax, ecx
    mov     edx, 1
    jmp     2b
8:  xor     edx, edx
9:  and     eax, 0xffffff
    ret

# ps_parse(rdi=record (writable), rsi=text or 0) -> eax = 1 (0: a word it did
#   not understand, said in the console)
ps_parse:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rbx, rdi
    mov     r12, rsi
    test    r12, r12
    jz      .Lpp_ok
.Lpp_next:
    mov     rsi, r12
    call    im_next_word
    mov     r12, rsi
    test    eax, eax
    jz      .Lpp_ok
    xor     r13d, r13d
1:  imul    rax, r13, 24
    lea     r14, [rip+pp_tab]
    add     r14, rax
    mov     rsi, [r14]
    test    rsi, rsi
    jz      .Lpp_bad
    lea     rdi, [rip+im_word]
    call    str_eq
    test    eax, eax
    jnz     2f
    inc     r13d
    jmp     1b
2:  mov     eax, [r14+12]
    cmp     eax, 5
    jne     3f
    and     dword ptr [rbx+PS_FLAGS], ~1
    jmp     .Lpp_next
3:  cmp     eax, 6
    jne     31f
    or      dword ptr [rbx+PS_FLAGS], 1
    jmp     .Lpp_next
31: cmp     eax, 10
    jne     32f
    mov     dword ptr [rbx+PS_VMODE], 0
    jmp     .Lpp_next
32: cmp     eax, 11
    je      .Lpp_dir
    mov     rsi, r12                    # its value
    call    im_next_word
    mov     r12, rsi
    test    eax, eax
    jz      .Lpp_bad
    mov     ecx, [r14+12]
    cmp     ecx, 2
    je      .Lpp_enum
    cmp     ecx, 7
    je      .Lpp_col
    cmp     ecx, 12
    je      .Lpp_name
    cmp     ecx, 13
    je      .Lpp_col2
    cmp     ecx, 14
    je      .Lpp_objs
    cmp     ecx, 15
    je      .Lpp_render
    cmp     ecx, 16
    je      .Lpp_coll
    cmp     ecx, 17
    je      .Lpp_events
    cmp     ecx, 18
    je      .Lpp_split
    cmp     ecx, 19
    je      .Lpp_visc
    cmp     ecx, 20
    je      .Lpp_domain
    lea     rsi, [rip+im_word]          # a number
    lea     rdx, [rsi+rax]
    call    parse_float
    test    eax, eax
    jz      .Lpp_bad
    mov     ecx, [r14+8]
    mov     eax, [r14+12]
    cmp     eax, 8
    jne     4f
    mov     dword ptr [rbx+PS_MODE], 0  # rate: at a rate
    jmp     6f
4:  cmp     eax, 9
    jne     5f
    mov     dword ptr [rbx+PS_MODE], 1  # burst: all at once
    jmp     51f
5:  cmp     eax, 1
    jne     6f
51: xorps   xmm1, xmm1
    maxss   xmm0, xmm1
    cvttss2si eax, xmm0
    mov     [rbx+rcx], eax
    jmp     .Lpp_next
6:  movss   [rbx+rcx], xmm0
    jmp     .Lpp_next
.Lpp_enum:
    mov     rdi, [r14+16]
    call    pp_word
    test    eax, eax
    js      .Lpp_bad
    mov     ecx, [r14+8]
    mov     [rbx+rcx], eax
    jmp     .Lpp_next
.Lpp_col:
    lea     rdi, [rip+im_word]
    call    pp_hex
    test    edx, edx
    jz      .Lpp_bad
    mov     [rbx+PS_COLOR], eax
    jmp     .Lpp_next
.Lpp_col2:                              # the end colour: a ramp to it
    lea     rdi, [rip+im_word]
    call    pp_hex
    test    edx, edx
    jz      .Lpp_bad
    mov     [rbx+PS_COLOR2], eax
    or      dword ptr [rbx+PS_RAMP], 1
    jmp     .Lpp_next
.Lpp_render:                            # render on / off
    mov     rdi, [r14+16]
    call    pp_word
    test    eax, eax
    js      .Lpp_bad
    and     dword ptr [rbx+PS_RFLAGS], ~1
    test    eax, eax
    jnz     .Lpp_next
    or      dword ptr [rbx+PS_RFLAGS], 1
    jmp     .Lpp_next
.Lpp_coll:                              # collide / liquid on / off: bit 0
    mov     rdi, [r14+16]
    call    pp_word
    test    eax, eax
    js      .Lpp_bad
    mov     ecx, [r14+8]
    and     dword ptr [rbx+rcx], ~1
    or      [rbx+rcx], eax
    jmp     .Lpp_next
.Lpp_visc:                              # viscosity water|oil|honey|k
    push    rax
    push    rax
    mov     rdi, [r14+16]
    call    pp_word
    mov     ecx, eax
    pop     rax
    pop     rax
    test    ecx, ecx
    js      1f
    lea     rax, [rip+pq_viscs]
    mov     eax, [rax+rcx*4]
    mov     [rbx+PS_VISC], eax
    jmp     .Lpp_next
1:  lea     rsi, [rip+im_word]
    lea     rdx, [rsi+rax]
    call    parse_float
    test    eax, eax
    jz      .Lpp_bad
    movss   [rbx+PS_VISC], xmm0
    jmp     .Lpp_next
.Lpp_domain:                            # domain off | x0 y0 z0 x1 y1 z1 | Name
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_off]
    push    rax
    push    rax
    call    str_eq
    mov     ecx, eax
    pop     rax
    pop     rax
    test    ecx, ecx
    jz      1f
    and     dword ptr [rbx+PS_DOMON], ~1
    jmp     .Lpp_next
1:  lea     rsi, [rip+im_word]          # a number: six of them
    lea     rdx, [rsi+rax]
    call    parse_float
    test    eax, eax
    jz      3f
    movss   [rbx+PS_DOMAIN], xmm0
    mov     r15d, 1
2:  mov     rsi, r12
    call    im_next_word
    mov     r12, rsi
    test    eax, eax
    jz      .Lpp_bad
    lea     rsi, [rip+im_word]
    lea     rdx, [rsi+rax]
    call    parse_float
    test    eax, eax
    jz      .Lpp_bad
    movss   [rbx+PS_DOMAIN+r15*4], xmm0
    inc     r15d
    cmp     r15d, 6
    jb      2b
    or      dword ptr [rbx+PS_DOMON], 1
    jmp     .Lpp_next
3:  lea     rdi, [rip+im_word]          # an object: its bounds in the world
    call    obj_find
    test    eax, eax
    jz      .Lpp_bad
    mov     edi, eax
    call    obj_get
    mov     rdi, rax
    lea     rsi, [rbx+PS_DOMAIN]
    call    world_box
    test    eax, eax
    jz      .Lpp_bad
    or      dword ptr [rbx+PS_DOMON], 1
    jmp     .Lpp_next
.Lpp_split:                             # split n: on a hit, into n
    lea     rsi, [rip+im_word]
    lea     rdx, [rsi+rax]
    call    parse_float
    test    eax, eax
    jz      .Lpp_bad
    cvttss2si eax, xmm0
    cmp     eax, 1
    jge     1f
    mov     eax, 1
1:  cmp     eax, 64
    jle     2f
    mov     eax, 64
2:  mov     [rbx+PS_SPLITN], eax
    mov     dword ptr [rbx+PS_ONHIT], 3
    or      dword ptr [rbx+PS_COLL], 1
    jmp     .Lpp_next
.Lpp_events:                            # events hit Rain: from another's
    mov     rdi, [r14+16]
    call    pp_word
    test    eax, eax
    js      .Lpp_bad
    mov     [rbx+PS_EVKIND], eax
    mov     dword ptr [rbx+PS_FROM], 4
    mov     rsi, r12                    # the system's name
    call    im_next_word
    mov     r12, rsi
    test    eax, eax
    jz      .Lpp_bad
    lea     rsi, [rip+im_word]
    lea     rdi, [rbx+PS_EVNAME]
    mov     ecx, 15
3:  mov     al, [rsi]
    test    al, al
    jz      4f
    mov     [rdi], al
    inc     rsi
    inc     rdi
    dec     ecx
    jnz     3b
4:  mov     byte ptr [rdi], 0
    jmp     .Lpp_next
.Lpp_objs:                              # objects A,B,C: drawn as them
    mov     dword ptr [rbx+PS_NOBJ], 0
    lea     r15, [rip+im_word]
81: cmp     byte ptr [r15], 0
    je      85f
    lea     rdi, [rip+pt_name]          # one name (up to a comma)
    xor     ecx, ecx
82: mov     al, [r15]
    test    al, al
    jz      83f
    inc     r15
    cmp     al, ','
    je      83f
    cmp     ecx, 31
    jae     82b
    mov     [rdi+rcx], al
    inc     ecx
    jmp     82b
83: mov     byte ptr [rdi+rcx], 0
    test    ecx, ecx
    jz      81b
    call    obj_find
    test    eax, eax
    jz      .Lpp_bad
    mov     edi, eax
    call    obj_get
    mov     ecx, [rbx+PS_NOBJ]
    cmp     ecx, 8
    jae     81b
    mov     eax, [rax+OB_UID]
    mov     [rbx+PS_OBJS+rcx*4], eax
    inc     dword ptr [rbx+PS_NOBJ]
    jmp     81b
85: cmp     dword ptr [rbx+PS_NOBJ], 0
    je      .Lpp_bad
    mov     dword ptr [rbx+PS_DRAW], 2
    jmp     .Lpp_next
.Lpp_name:
    lea     rsi, [rip+im_word]
    lea     rdi, [rbx+PS_NAME]
    mov     ecx, 15
7:  mov     al, [rsi]
    test    al, al
    jz      71f
    mov     [rdi], al
    inc     rsi
    inc     rdi
    dec     ecx
    jnz     7b
71: mov     byte ptr [rdi], 0
    jmp     .Lpp_next
.Lpp_dir:                               # direction x y z: along it
    xor     r15d, r15d
8:  mov     rsi, r12
    call    im_next_word
    mov     r12, rsi
    test    eax, eax
    jz      .Lpp_bad
    lea     rsi, [rip+im_word]
    lea     rdx, [rsi+rax]
    call    parse_float
    test    eax, eax
    jz      .Lpp_bad
    movss   [rbx+PS_DIR+r15*4], xmm0
    inc     r15d
    cmp     r15d, 3
    jb      8b
    mov     dword ptr [rbx+PS_VMODE], 1
    jmp     .Lpp_next
.Lpp_ok:
    mov     eax, 1
    jmp     9f
.Lpp_bad:
    lea     rdi, [rip+s_bad]
    lea     rsi, [rip+im_word]
    call    log_pair
    xor     eax, eax
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  The pool
# =============================================================================
# pool_init -> eax = 1 when the pool is there
pool_init:
    cmp     qword ptr [rip+pt_pool], 0
    jne     8f
    xor     edi, edi
    mov     rsi, POOL_BYTES
    mov     edx, PROT_RW
    mov     r10d, MAP_NORES
    mov     r8, -1
    xor     r9d, r9d
    mov     eax, SYS_MMAP
    syscall
    cmp     rax, -4096
    jb      1f
    xor     eax, eax
    ret
1:  mov     [rip+pt_pool], rax
    call    free_all_blocks
    xor     edi, edi                    # the events' staging
    mov     rsi, NBLK*2*BLK*EV_SZ
    mov     edx, PROT_RW
    mov     r10d, MAP_NORES
    mov     r8, -1
    xor     r9d, r9d
    mov     eax, SYS_MMAP
    syscall
    cmp     rax, -4096
    jb      2f
    xor     eax, eax
2:  mov     [rip+pt_stage], rax
8:  mov     eax, 1
    ret

# ev_reserve -> rax = room for a system's events a step (0: none)
ev_reserve:
    xor     edi, edi
    mov     rsi, EV_CAP*EV_SZ
    mov     edx, PROT_RW
    mov     r10d, MAP_NORES
    mov     r8, -1
    xor     r9d, r9d
    mov     eax, SYS_MMAP
    syscall
    cmp     rax, -4096
    jb      1f
    xor     eax, eax
1:  ret

# free_all_blocks - every block free again (popped 0, 1, 2 ...)
free_all_blocks:
    mov     dword ptr [rip+pt_nfree], NBLK
    lea     rdx, [rip+pt_freel]
    xor     ecx, ecx
1:  mov     eax, NBLK-1
    sub     eax, ecx
    mov     [rdx+rcx*4], eax
    inc     ecx
    cmp     ecx, NBLK
    jb      1b
    ret

# blk_get -> eax = a free block (count 0), or -1
blk_get:
    mov     eax, [rip+pt_nfree]
    test    eax, eax
    jz      8f
    dec     eax
    mov     [rip+pt_nfree], eax
    lea     rdx, [rip+pt_freel]
    mov     eax, [rdx+rax*4]
    lea     rdx, [rip+pt_bn]
    mov     dword ptr [rdx+rax*4], 0
    lea     ecx, [rax+1]
    cmp     ecx, [rip+pt_used]
    jbe     9f
    mov     [rip+pt_used], ecx
9:  ret
8:  mov     eax, -1
    ret

# blk_put(edi=block)
blk_put:
    mov     eax, [rip+pt_nfree]
    lea     rdx, [rip+pt_freel]
    mov     [rdx+rax*4], edi
    inc     dword ptr [rip+pt_nfree]
    ret

# sys_blocks(edi=system) -> rax = its block list
sys_blocks:
    mov     eax, edi
    shl     rax, 12                     # x NBLK x 4
    lea     rcx, [rip+sr_blk]
    add     rax, rcx
    ret

# blk_at(edi=block) -> rax = its memory
blk_at:
    mov     eax, edi
    imul    rax, rax, BLK_BYTES
    add     rax, [rip+pt_pool]
    ret

# pt_stop - no particles (the pool kept for the next run)
pt_stop:
    push    rbx
    push    r12
    sub     rsp, 8
    xor     ebx, ebx
1:  cmp     ebx, [rip+pt_ns]            # the faces' areas go
    jae     2f
    imul    r12, rbx, SR_SZ
    lea     rax, [rip+pt_sr]
    add     r12, rax
    mov     rdi, [r12+SR_CDF]
    test    rdi, rdi
    jz      11f
    mov     esi, [r12+SR_CDFB]
    shl     rsi, 12
    mov     eax, SYS_MUNMAP
    syscall
11: mov     rdi, [r12+SR_EVH]           # its events
    test    rdi, rdi
    jz      12f
    mov     rsi, EV_CAP*EV_SZ
    mov     eax, SYS_MUNMAP
    syscall
12: mov     rdi, [r12+SR_EVD]
    test    rdi, rdi
    jz      13f
    mov     rsi, EV_CAP*EV_SZ
    mov     eax, SYS_MUNMAP
    syscall
13: mov     rdi, [r12+SR_FILLP]         # its lattice
    test    rdi, rdi
    jz      14f
    mov     esi, [r12+SR_FILLB]
    mov     eax, SYS_MUNMAP
    syscall
14: inc     ebx
    jmp     1b
2:  lea     rdi, [rip+pt_sr]
    mov     ecx, SR_SZ*PB_MAX
    xor     eax, eax
    rep     stosb
    xor     eax, eax
    mov     [rip+pt_ns], eax
    mov     [rip+pt_on], eax
    mov     [rip+pt_now], eax
    cmp     qword ptr [rip+pt_pool], 0
    je      9f
    call    free_all_blocks
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# pt_reset - a new scene: no particles, the pool's pages given back
pt_reset:
    sub     rsp, 8
    call    pt_stop
    mov     qword ptr [rip+pt_hash], 0
    mov     rdi, [rip+pt_pool]
    test    rdi, rdi
    jz      9f
    mov     eax, [rip+pt_used]
    imul    rsi, rax, BLK_BYTES
    test    rsi, rsi
    jz      9f
    mov     edx, MADV_DONTNEED
    mov     eax, SYS_MADVISE
    syscall
    mov     dword ptr [rip+pt_used], 0
9:  add     rsp, 8
    ret

# pt_build - a running system for each record
pt_build:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    call    pt_stop
    call    lq_reset
    call    pool_init
    test    eax, eax
    jz      9f
    mov     r13, [rip+ps_cur]
    test    r13, r13
    jz      9f
    xor     ebx, ebx
1:  cmp     ebx, [r13+PB_N]
    jae     8f
    imul    r14, rbx, PS_SZ
    lea     r14, [r13+PB_HDR+r14]       # the record
    mov     eax, [rip+pt_ns]
    imul    r12, rax, SR_SZ
    lea     rcx, [rip+pt_sr]
    add     r12, rcx
    mov     [r12+SR_SI], eax
    inc     dword ptr [rip+pt_ns]
    mov     eax, [r14+PS_UID]
    mov     [r12+SR_UID], eax
    xor     ecx, ecx                    # which of its object's
    xor     edx, edx
    lea     rsi, [r13+PB_HDR]
2:  cmp     edx, ebx
    jae     3f
    cmp     [rsi+PS_UID], eax
    jne     21f
    inc     ecx
21: add     rsi, PS_SZ
    inc     edx
    jmp     2b
3:  mov     [r12+SR_K], ecx
    mov     ecx, [r14+PS_SEED]          # the random numbers' seed
    imul    ecx, ecx, -1028477379
    imul    eax, eax, 0x27d4eb2f
    add     eax, ecx
    mov     [r12+SR_SEED], eax
    inc     ebx
    jmp     1b
8:  mov     dword ptr [rip+pt_on], 1
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Frames
# =============================================================================
# pt_key -> rax: the systems' settings, the animation, where the emitters
#   nothing moves are and their meshes, the force fields (what the
#   particles at a frame depend on)
pt_key:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r13, 0x51ED270B27D4EB2F
    mov     r14, [rip+ps_cur]
    test    r14, r14
    jz      9f
    mov     rax, r13
    lea     rdi, [r14+PB_HDR]
    imul    esi, [r14+PB_N], PS_SZ
    call    sc_mix
    call    an_hash
    mov     r13, rax
    xor     ebx, ebx
1:  cmp     ebx, [r14+PB_N]
    jae     8f
    imul    r15, rbx, PS_SZ
    lea     r15, [r14+PB_HDR+r15]
    inc     ebx
    mov     edi, [r15+PS_UID]
    call    obj_by_uid
    test    rax, rax
    jz      1b
    mov     r12, rax
    mov     edi, [r15+PS_UID]
    call    an_moves
    test    eax, eax
    jnz     2f
    mov     rax, r13                    # nothing moves it: where it is
    lea     rdi, [r12+OB_LOC]
    mov     esi, 36
    call    sc_mix
    mov     r13, rax
2:  mov     rax, r13
    lea     rdi, [r12+OB_MESH]          # its mesh and modifiers (pointers)
    mov     esi, 24
    call    sc_mix
    mov     rdi, [r12+OB_MESH]
    call    sc_meshhash
    mov     r13, rax
    jmp     1b
8:  mov     rax, r13
    call    fl_mix
    mov     r13, rax
9:  mov     rax, r13
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# pt_frame(xmm0=frame) - the particles at that frame: none at or before the
#   scene's start; else stepped on from where they are (begun again when
#   going back or something they depend on changed)
pt_frame:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    and     rsp, -16
    sub     rsp, 32
    cmp     dword ptr [rip+pt_busy], 0
    jne     .Lpf_ret
    mov     dword ptr [rip+pt_busy], 1
    movss   [rsp], xmm0
    mov     rbx, [rip+an_cur]
    mov     rax, [rip+ps_cur]
    test    rax, rax
    jz      .Lpf_gone
    cmp     dword ptr [rax+PB_N], 0
    je      .Lpf_gone
    movss   xmm1, [rip+pq_24]           # the step: a frame
    test    rbx, rbx
    jz      1f
    movss   xmm2, [rbx+AN_FPS]
    xorps   xmm3, xmm3
    comiss  xmm2, xmm3
    jbe     1f
    movss   xmm1, xmm2
1:  cvtss2sd xmm2, xmm1
    movsd   xmm3, [rip+pd_one]
    divsd   xmm3, xmm2
    movsd   [rip+pt_dtd], xmm3
    cvtsd2ss xmm3, xmm3
    movss   [rip+pt_dt], xmm3
    movss   xmm0, [rsp]                 # steps to the frame
    roundss xmm0, xmm0, 1
    cvttss2si r12d, xmm0
    xor     eax, eax
    test    rbx, rbx
    jz      2f
    mov     eax, [rbx+AN_START]
2:  sub     r12d, eax
    jle     .Lpf_none
    call    pt_key
    mov     r13, rax
    cmp     dword ptr [rip+pt_on], 0
    je      3f
    cmp     r13, [rip+pt_hash]
    jne     3f
    cmp     r12d, [rip+pt_now]
    jae     4f
3:  call    pt_build
    mov     [rip+pt_hash], r13
    cmp     dword ptr [rip+pt_on], 0
    je      .Lpf_out
4:  call    now_ns
    mov     r14, rax
5:  cmp     [rip+pt_now], r12d
    jae     6f
    call    pt_step
    inc     dword ptr [rip+pt_now]
    jmp     5b
6:  call    now_ns
    sub     rax, r14
    cvtsi2ss xmm0, rax
    mulss   xmm0, [rip+pq_k]
    mulss   xmm0, [rip+pq_k]
    movss   [rip+pt_msf], xmm0
    mov     dword ptr [rip+dirty], 1
    jmp     .Lpf_out
.Lpf_gone:
    cmp     dword ptr [rip+pt_on], 0
    je      .Lpf_out
    call    pt_reset
    mov     dword ptr [rip+dirty], 1
    jmp     .Lpf_out
.Lpf_none:
    cmp     dword ptr [rip+pt_on], 0
    je      .Lpf_out
    call    pt_stop
    mov     dword ptr [rip+dirty], 1
.Lpf_out:
    mov     dword ptr [rip+pt_busy], 0
.Lpf_ret:
    lea     rsp, [rbp-40]
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret

# pt_step - one step: everything moves, the dead go, the newborn come
pt_step:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    and     rsp, -16
    sub     rsp, 32
    call    now_ns
    mov     [rsp], rax
    cvtsi2sd xmm0, dword ptr [rip+pt_now]   # its start and end (s)
    movsd   xmm1, [rip+pt_dtd]
    mulsd   xmm0, xmm1
    movsd   [rip+pt_t0], xmm0
    addsd   xmm0, xmm1
    movsd   [rip+pt_t1], xmm0
    mov     rax, [rip+an_cur]           # the fields at this moment
    xor     ecx, ecx
    test    rax, rax
    jz      1f
    mov     ecx, [rax+AN_START]
1:  add     ecx, [rip+pt_now]
    cvtsi2ss xmm0, ecx
    mulss   xmm0, [rip+pt_dt]
    movss   [rsp+8], xmm0
    call    rb_gravity
    movups  xmm0, [rax]
    andps   xmm0, [rip+pq_xyz]
    movaps  [rip+pt_g], xmm0
    movss   xmm0, [rsp+8]
    mov     rdi, rax
    call    fl_prep
    mov     eax, [rip+fl_n]
    mov     [rip+pt_fields], eax
    call    any_coll                    # the colliders (when any system collides)
    test    eax, eax
    jz      11f
    call    pt_colliders
    jmp     12f
11: mov     dword ptr [rip+pc_any], 0
12: xor     ebx, ebx                    # each system now; its blocks listed
    xor     r13d, r13d
2:  cmp     ebx, [rip+pt_ns]
    jae     3f
    imul    r12, rbx, SR_SZ
    lea     rax, [rip+pt_sr]
    add     r12, rax
    call    sys_prep
    mov     [r12+SR_L0], r13d
    mov     eax, [r12+SR_NB]
    cmp     dword ptr [r12+SR_LIQON], 0 # (a liquid: liquid.s moves it)
    je      20f
    xor     eax, eax
20: mov     [r12+SR_LN], eax
    test    eax, eax
    jz      22f
    mov     edi, ebx
    call    sys_blocks
    xor     ecx, ecx
21: cmp     ecx, [r12+SR_NB]
    jae     22f
    mov     edx, [rax+rcx*4]
    lea     rsi, [rip+pt_list]
    mov     [rsi+r13*4], edx
    lea     rsi, [rip+pt_bsys]
    mov     [rsi+rdx*4], ebx
    inc     r13d
    inc     ecx
    jmp     21b
22: inc     ebx
    jmp     2b
3:  mov     [rip+pt_nlist], r13d
    call    pt_listen
    lea     rdi, [rip+step_job]
    xor     esi, esi
    mov     edx, r13d
    mov     ecx, 1
    call    parallel_for
    xor     ebx, ebx                    # liquids
41: cmp     ebx, [rip+pt_ns]
    jae     42f
    imul    r12, rbx, SR_SZ
    lea     rax, [rip+pt_sr]
    add     r12, rax
    cmp     dword ptr [r12+SR_LIQON], 0
    je      43f
    call    sys_liquid
43: inc     ebx
    jmp     41b
42: xor     ebx, ebx                    # empty blocks back; then the newborn
4:  cmp     ebx, [rip+pt_ns]
    jae     5f
    imul    r12, rbx, SR_SZ
    lea     rax, [rip+pt_sr]
    add     r12, rax
    call    sys_gather
    call    sys_tidy
    xor     esi, esi
    call    sys_emit
    inc     ebx
    jmp     4b
5:  xor     ebx, ebx                    # then what events give birth to
51: cmp     ebx, [rip+pt_ns]
    jae     52f
    imul    r12, rbx, SR_SZ
    lea     rax, [rip+pt_sr]
    add     r12, rax
    mov     esi, 1
    call    sys_emit
    inc     ebx
    jmp     51b
52: call    now_ns
    sub     rax, [rsp]
    cvtsi2ss xmm0, rax
    mulss   xmm0, [rip+pq_k]
    mulss   xmm0, [rip+pq_k]
    movss   [rip+pt_mss], xmm0
    lea     rsp, [rbp-40]
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret

# any_coll -> eax = 1 when a running system collides
any_coll:
    push    rbx
    push    r12
    sub     rsp, 8
    xor     ebx, ebx
1:  cmp     ebx, [rip+pt_ns]
    jae     8f
    imul    r12, rbx, SR_SZ
    lea     rax, [rip+pt_sr]
    add     r12, rax
    inc     ebx
    mov     edi, [r12+SR_UID]
    mov     esi, [r12+SR_K]
    call    ps_nth
    test    rax, rax
    jz      1b
    test    dword ptr [rax+PS_COLL], 1
    jz      1b
    mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# sys_prep(r12=system) - its settings, its object's place and mesh, its
#   pull and drag this step
sys_prep:
    push    rbx
    push    r13
    push    r14
    mov     qword ptr [r12+SR_REC], 0
    mov     qword ptr [r12+SR_MESH], 0
    mov     edi, [r12+SR_UID]
    mov     esi, [r12+SR_K]
    call    ps_nth
    mov     r13, rax                    # its settings (0: gone)
    lea     r14, [rip+ps_defs]
    test    rax, rax
    cmovnz  r14, rax
    movss   xmm0, [r14+PS_GRAV]         # its pull, its drag
    movaps  xmm1, xmm0
    shufps  xmm1, xmm1, 0
    mulps   xmm1, [rip+pt_g]
    movaps  [r12+SR_ACC], xmm1
    subss   xmm0, [rip+pq_one]
    shufps  xmm0, xmm0, 0
    mulps   xmm0, [rip+pt_g]
    movaps  [r12+SR_GADJ], xmm0
    movss   xmm0, [r14+PS_DRAG]
    mulss   xmm0, [rip+pt_dt]
    addss   xmm0, [rip+pq_one]
    movss   xmm1, [rip+pq_one]
    divss   xmm1, xmm0
    movss   [r12+SR_DAMP], xmm1
    mov     ecx, [r14+PS_GROUP]
    and     ecx, 15
    mov     eax, 1
    shl     eax, cl
    mov     [r12+SR_GBIT], eax
    mov     eax, [r14+PS_COLL]          # its collisions
    and     eax, 1
    and     eax, [rip+pc_any]
    mov     [r12+SR_COLLON], eax
    mov     eax, [r14+PS_BOUNCE]
    mov     [r12+SR_BOUNCE], eax
    mov     eax, [r14+PS_FRIC]
    mov     [r12+SR_FRIC], eax
    mov     eax, [r14+PS_ONHIT]
    mov     [r12+SR_ONHIT], eax
    mov     eax, [r14+PS_LIQ]
    and     eax, 1
    mov     [r12+SR_LIQON], eax
    movaps  xmm0, [r12+SR_ACC]
    DOT3    xmm0, xmm0
    mulss   xmm0, [rip+pt_dt]
    mulss   xmm0, [rip+pt_dt]
    mulss   xmm0, [rip+pq_four]
    movss   [r12+SR_REST], xmm0
    test    r13, r13
    jz      9f
    test    dword ptr [r13+PS_FLAGS], 1
    jnz     9f
    mov     edi, [r12+SR_UID]           # its object: where, its mesh
    call    obj_by_uid
    test    rax, rax
    jz      9f
    mov     rbx, rax
    mov     rdi, rax
    lea     rsi, [r12+SR_MAT]
    call    obj_matrix
    mov     eax, [r13+PS_FROM]
    cmp     eax, 3
    je      2f
    cmp     eax, 4
    je      2f
    mov     rdi, rbx
    call    obj_eval
    test    rax, rax
    jz      1f
    cmp     dword ptr [rax+ME_NVERTS], 0
    je      1f
    mov     ecx, [r13+PS_FROM]
    cmp     ecx, 2
    je      11f
    cmp     dword ptr [rax+ME_NTRIS], 0
    je      1f
11: mov     [r12+SR_MESH], rax
    mov     [r12+SR_SRC], ecx
    jmp     3f
1:  mov     eax, 3                      # no mesh to emit from: its origin
2:  mov     [r12+SR_SRC], eax
3:  mov     [r12+SR_REC], r13
    mov     eax, [r13+PS_START]         # emitting from (s)
    movd    xmm0, eax
    mov     rax, [rip+an_cur]
    xor     ecx, ecx
    test    rax, rax
    jz      4f
    mov     ecx, [rax+AN_START]
4:  cvtss2sd xmm0, xmm0
    cvtsi2sd xmm1, ecx
    subsd   xmm0, xmm1
    mulsd   xmm0, [rip+pt_dtd]
    movsd   [r12+SR_TS], xmm0
    cvtss2sd xmm0, [r13+PS_RATE]
    movsd   [r12+SR_RATE], xmm0
    movsd   xmm0, [rip+pt_t1]
    movsd   [r12+SR_T1], xmm0
9:  pop     r14
    pop     r13
    pop     rbx
    ret

# sys_liquid(r12=system) - its particles to liquid.s, moved, back (older)
sys_liquid:
    push    rbx
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    mov     edi, [r12+SR_N]
    test    edi, edi
    jz      9f
    call    lq_room
    test    eax, eax
    jz      9f
    xor     esi, esi                    # gather
    call    lq_copy
    mov     edi, [r12+SR_UID]
    mov     esi, [r12+SR_K]
    call    ps_nth
    test    rax, rax
    jz      9f
    mov     rsi, rax
    mov     edi, [r12+SR_N]
    movss   xmm0, [rip+pt_dt]
    lea     rdx, [r12+SR_ACC]
    lea     rcx, [r12+SR_GADJ]
    mov     r8d, [r12+SR_GBIT]
    call    lq_solve
    mov     esi, 1                      # back
    call    lq_copy
9:  add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     rbx
    ret

# lq_copy(r12=system, esi=0 into lq_x / lq_v, 1 back (and a step older))
lq_copy:
    push    rbx
    push    r13
    push    r14
    push    r15
    push    rbp
    mov     ebp, esi
    mov     edi, [r12+SR_SI]
    call    sys_blocks
    mov     r13, rax
    xor     r14d, r14d                  # block
    xor     r15d, r15d                  # particle
1:  cmp     r14d, [r12+SR_NB]
    jae     9f
    mov     edi, [r13+r14*4]
    inc     r14d
    lea     rax, [rip+pt_bn]
    mov     ecx, [rax+rdi*4]
    call    blk_at
    mov     rbx, rax
    xor     edx, edx
2:  cmp     edx, ecx
    jae     1b
    mov     rax, r15
    shl     rax, 4
    mov     r8, rax
    add     rax, [rip+lq_x]
    add     r8, [rip+lq_v]
    test    ebp, ebp
    jnz     3f
    movss   xmm0, [rbx+A_X+rdx*4]
    movss   xmm1, [rbx+A_Y+rdx*4]
    movss   xmm2, [rbx+A_Z+rdx*4]
    unpcklps xmm0, xmm1
    movlhps xmm0, xmm2
    andps   xmm0, [rip+pq_xyz]
    movaps  [rax], xmm0
    movss   xmm0, [rbx+A_VX+rdx*4]
    movss   xmm1, [rbx+A_VY+rdx*4]
    movss   xmm2, [rbx+A_VZ+rdx*4]
    unpcklps xmm0, xmm1
    movlhps xmm0, xmm2
    andps   xmm0, [rip+pq_xyz]
    movaps  [r8], xmm0
    jmp     4f
3:  movss   xmm0, [rax]
    movss   [rbx+A_X+rdx*4], xmm0
    movss   xmm0, [rax+4]
    movss   [rbx+A_Y+rdx*4], xmm0
    movss   xmm0, [rax+8]
    movss   [rbx+A_Z+rdx*4], xmm0
    movss   xmm0, [r8]
    movss   [rbx+A_VX+rdx*4], xmm0
    movss   xmm0, [r8+4]
    movss   [rbx+A_VY+rdx*4], xmm0
    movss   xmm0, [r8+8]
    movss   [rbx+A_VZ+rdx*4], xmm0
    movss   xmm0, [rbx+A_AGE+rdx*4]
    addss   xmm0, [rip+pt_dt]
    movss   [rbx+A_AGE+rdx*4], xmm0
4:  inc     r15d
    inc     edx
    jmp     2b
9:  pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     rbx
    ret

# sys_tidy(r12=system) - its empty blocks back to the pool, its count
sys_tidy:
    push    rbx
    push    r13
    push    r14
    mov     edi, [r12+SR_SI]
    call    sys_blocks
    mov     r13, rax
    xor     ebx, ebx                    # read
    xor     r14d, r14d                  # kept
    xor     r8d, r8d                    # alive
1:  cmp     ebx, [r12+SR_NB]
    jae     3f
    mov     edi, [r13+rbx*4]
    inc     ebx
    lea     rax, [rip+pt_bn]
    mov     eax, [rax+rdi*4]
    test    eax, eax
    jz      2f
    add     r8d, eax
    mov     [r13+r14*4], edi
    inc     r14d
    jmp     1b
2:  push    r8
    push    r8
    call    blk_put
    pop     r8
    pop     r8
    jmp     1b
3:  mov     [r12+SR_NB], r14d
    mov     [r12+SR_N], r8d
    pop     r14
    pop     r13
    pop     rbx
    ret

# =============================================================================
#  Being born
# =============================================================================
# sys_emit(r12=system, esi=0 from its source, 1 from events: another's, or
#   its own hits when it splits) - the particles born during this step: how
#   many, their places in its blocks, then made in parallel
sys_emit:
    push    rbx
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    test    esi, esi
    jnz     1f
    mov     dword ptr [r12+SR_EN], 0    # (none born yet this step)
1:  mov     r13, [r12+SR_REC]
    test    r13, r13
    jz      .Lse_out
    mov     dword ptr [r12+SR_EMODE], 0
    test    esi, esi
    jnz     .Lse_events
    cmp     dword ptr [r13+PS_FROM], 4  # (born of events only)
    je      .Lse_out
    cmp     dword ptr [r13+PS_FROM], 5  # (a fill: all at once)
    je      .Lse_burst
    cmp     dword ptr [r13+PS_MODE], 0
    jne     .Lse_burst
    movsd   xmm2, [r12+SR_RATE]         # at a rate: ids born before the end
    xorpd   xmm3, xmm3
    comisd  xmm2, xmm3
    jbe     .Lse_out
    movss   xmm0, [r13+PS_END]          #  (or the emitting's end)
    cvtss2sd xmm0, xmm0
    mov     rax, [rip+an_cur]
    xor     ecx, ecx
    test    rax, rax
    jz      1f
    mov     ecx, [rax+AN_START]
1:  cvtsi2sd xmm1, ecx
    subsd   xmm0, xmm1
    mulsd   xmm0, [rip+pt_dtd]
    minsd   xmm0, [r12+SR_T1]
    subsd   xmm0, [r12+SR_TS]
    comisd  xmm0, xmm3
    jbe     .Lse_out
    mulsd   xmm0, xmm2
    roundsd xmm0, xmm0, 2               # ceil
    cvttsd2si rbx, xmm0                 # ids below this are born by now
    mov     eax, 0x7fffffff
    cmp     rbx, rax
    cmova   rbx, rax
    movsd   xmm0, [r12+SR_TS]           # none before the scene's start
    xorpd   xmm1, xmm1
    subsd   xmm1, xmm0
    xor     eax, eax
    comisd  xmm1, xmm3
    jbe     2f
    mulsd   xmm1, xmm2
    roundsd xmm1, xmm1, 2
    cvttsd2si rax, xmm1
2:  mov     r14d, [r12+SR_NEXT]
    cmp     r14d, eax
    cmovb   r14d, eax                   # the first
    mov     [r12+SR_NEXT], ebx
    sub     ebx, r14d
    jle     .Lse_out
    jmp     .Lse_have
.Lse_burst:                             # all at once (at the start, or the
    cmp     dword ptr [r12+SR_NEXT], 0  #  scene's start if before it)
    jne     .Lse_out
    movsd   xmm0, [r12+SR_TS]
    xorpd   xmm1, xmm1
    maxsd   xmm0, xmm1
    comisd  xmm0, [r12+SR_T1]
    jae     .Lse_out
    mov     ebx, [r13+PS_NUM]
    cmp     dword ptr [r12+SR_SRC], 5   # a fill: the lattice's points inside
    jne     1f
    call    fill_build
    mov     ebx, eax
1:  test    ebx, ebx
    jz      .Lse_out
    mov     [r12+SR_NEXT], ebx
    xor     r14d, r14d
    jmp     .Lse_have
.Lse_events:
    mov     eax, [r12+SR_ENEXT]         # (their ids: apart from the others)
    lea     r14d, [rax+0x40000000]
    cmp     dword ptr [r13+PS_FROM], 4
    je      .Lse_other
    test    dword ptr [r13+PS_COLL], 1  # its own hits: it splits
    jz      .Lse_out
    cmp     dword ptr [r13+PS_ONHIT], 3
    jne     .Lse_out
    mov     ecx, [r13+PS_SPLITN]
    mov     ebx, [r12+SR_NH]
    mov     rax, [r12+SR_EVH]
    mov     edx, 3
    jmp     .Lse_count
.Lse_other:                             # another system's births, hits, deaths
    mov     rsi, [r12+SR_EVS]
    test    rsi, rsi
    jz      .Lse_out
    mov     ecx, [r13+PS_EVPER]
    mov     eax, [r13+PS_EVKIND]
    cmp     eax, 1
    je      1f
    cmp     eax, 2
    je      2f
    mov     ebx, [rsi+SR_EN]            # born: its newborn this step
    xor     eax, eax
    mov     edx, 2
    jmp     .Lse_count
1:  mov     ebx, [rsi+SR_NH]
    mov     rax, [rsi+SR_EVH]
    mov     edx, 1
    jmp     .Lse_count
2:  mov     ebx, [rsi+SR_ND]
    mov     rax, [rsi+SR_EVD]
    mov     edx, 4
.Lse_count:                             # ebx events x ecx each
    cmp     ecx, 1
    jge     3f
    mov     ecx, 1
3:  mov     [r12+SR_EVA], rax
    mov     [r12+SR_EMODE], edx
    mov     [r12+SR_EVP], ecx
    imul    ebx, ecx
    test    ebx, ebx
    jz      .Lse_out
    add     [r12+SR_ENEXT], ebx
.Lse_have:                              # ebx born, ids from r14d
    mov     eax, [r13+PS_MAX]           # at most so many at once
    test    eax, eax
    jz      3f
    sub     eax, [r12+SR_N]
    jle     .Lse_out
    cmp     ebx, eax
    cmova   ebx, eax
3:  mov     [r12+SR_EID], r14d
    cmp     dword ptr [r12+SR_SRC], 0   # faces: their areas
    jne     4f
    call    sys_cdf
4:  mov     edi, [r12+SR_SI]            # their places: the last block's room,
    call    sys_blocks                  #  then new blocks
    mov     r15, rax
    mov     ecx, [r12+SR_NB]
    mov     [r12+SR_ENB], ecx
    mov     dword ptr [r12+SR_ELB], -1
    xor     edx, edx                    # room
    xor     r8d, r8d
    test    ecx, ecx
    jz      5f
    mov     edi, [r15+rcx*4-4]
    mov     [r12+SR_ELB], edi
    lea     rax, [rip+pt_bn]
    mov     r8d, [rax+rdi*4]
    mov     edx, BLK
    sub     edx, r8d
5:  mov     [r12+SR_EC], r8d
    mov     [r12+SR_ER], edx
    mov     eax, ebx                    # into the last block
    cmp     eax, edx
    cmova   eax, edx
    test    eax, eax
    jz      51f
    mov     edi, [r12+SR_ELB]
    lea     rcx, [rip+pt_bn]
    add     [rcx+rdi*4], eax
51: mov     r14d, ebx                   # the rest: new blocks
    sub     r14d, eax
    mov     r13d, eax                   # (placed so far)
6:  test    r14d, r14d
    jz      7f
    call    blk_get
    test    eax, eax
    js      7f                          # the pool is full: fewer
    mov     ecx, [r12+SR_NB]
    mov     [r15+rcx*4], eax
    inc     dword ptr [r12+SR_NB]
    lea     rcx, [rip+pt_bsys]
    mov     edx, [r12+SR_SI]
    mov     [rcx+rax*4], edx
    mov     edx, r14d
    cmp     edx, BLK
    jbe     61f
    mov     edx, BLK
61: lea     rcx, [rip+pt_bn]
    mov     [rcx+rax*4], edx
    add     r13d, edx
    sub     r14d, edx
    jmp     6b
7:  mov     [r12+SR_EN], r13d
    add     [r12+SR_N], r13d
    test    r13d, r13d
    jz      .Lse_out
    lea     rdi, [rip+emit_job]
    mov     rsi, r12
    mov     edx, r13d
    mov     ecx, 2048
    call    parallel_for
.Lse_out:
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     rbx
    ret

# m_pt(rdi=3x4 matrix (aligned), xmm0=point) -> xmm0 = M p (w 0)
m_pt:
    andps   xmm0, [rip+pq_xyz]
    orps    xmm0, [rip+pq_w1]
    jmp     1f
# m_vec(rdi=matrix, xmm0=vector) -> xmm0 = M v without the move (w 0)
m_vec:
    andps   xmm0, [rip+pq_xyz]
1:  movaps  xmm1, xmm0
    dpps    xmm1, [rdi], 0xF1
    movaps  xmm2, xmm0
    dpps    xmm2, [rdi+16], 0xF2
    movaps  xmm3, xmm0
    dpps    xmm3, [rdi+32], 0xF4
    orps    xmm1, xmm2
    orps    xmm1, xmm3
    movaps  xmm0, xmm1
    ret

# unit(xmm0) -> xmm0 / |xmm0| (w 0)
unit:
    andps   xmm0, [rip+pq_xyz]
    movaps  xmm1, xmm0
    DOT3    xmm1, xmm1
    maxss   xmm1, [rip+pq_tiny]
    sqrtss  xmm1, xmm1
    shufps  xmm1, xmm1, 0
    divps   xmm0, xmm1
    ret

# ld3(rax=3 floats) -> xmm0 (w 0)
.macro LD3 x, p, t
    movsd   \x, [\p]
    movss   \t, [\p+8]
    movlhps \x, \t
.endm

# prand(edi=id, esi=which, r12=system) -> xmm0 in [0, 1): a hash (leaf:
#   eax, ecx)
prand:
    mov     eax, edi
    imul    eax, eax, -1640531535
    imul    ecx, esi, -2048144777
    add     eax, ecx
    add     eax, [r12+SR_SEED]
    mov     ecx, eax
    shr     ecx, 16
    xor     eax, ecx
    imul    eax, eax, 0x7feb352d
    mov     ecx, eax
    shr     ecx, 15
    xor     eax, ecx
    imul    eax, eax, -2073254261
    mov     ecx, eax
    shr     ecx, 16
    xor     eax, ecx
    shr     eax, 8
    cvtsi2ss xmm0, eax
    mulss   xmm0, [rip+pq_u24]
    ret

# sys_cdf(r12=system) - its faces' areas summed (in the world), made again
#   when its mesh or place changed
sys_cdf:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r13
    push    r14
    push    r15
    and     rsp, -16
    sub     rsp, 32
    mov     r13, [r12+SR_MESH]
    mov     rax, r13                    # what it is for
    mov     ecx, [r13+ME_VER]
    xor     rax, rcx
    mov     rcx, 0x9E3779B97F4A7C15
    imul    rax, rcx
    lea     rdi, [r12+SR_MAT]
    mov     esi, 48
    call    sc_mix
    cmp     qword ptr [r12+SR_CDF], 0
    je      1f
    cmp     rax, [r12+SR_CDFK]
    je      9f
1:  mov     [r12+SR_CDFK], rax
    mov     ebx, [r13+ME_NTRIS]
    lea     rax, [rbx*4+4095]
    shr     rax, 12
    cmp     eax, [r12+SR_CDFB]
    jbe     2f
    push    rax
    push    rax
    mov     rdi, [r12+SR_CDF]           # more room
    test    rdi, rdi
    jz      11f
    mov     esi, [r12+SR_CDFB]
    shl     rsi, 12
    mov     eax, SYS_MUNMAP
    syscall
11: mov     qword ptr [r12+SR_CDF], 0
    mov     dword ptr [r12+SR_CDFB], 0
    pop     rsi
    pop     rsi
    mov     r14, rsi
    shl     rsi, 12
    xor     edi, edi
    mov     edx, PROT_RW
    mov     r10d, MAP_ANON_PRIV
    mov     r8, -1
    xor     r9d, r9d
    mov     eax, SYS_MMAP
    syscall
    cmp     rax, -4096
    jae     8f
    mov     [r12+SR_CDF], rax
    mov     [r12+SR_CDFB], r14d
2:  mov     [r12+SR_CDFN], ebx
    mov     r14, [r12+SR_CDF]
    mov     r15, [r13+ME_TRIS]
    mov     r13, [r13+ME_POS]
    lea     rdi, [r12+SR_MAT]
    xorps   xmm6, xmm6                  # the sum
    xor     ecx, ecx
3:  cmp     ecx, ebx
    jae     4f
    mov     eax, [r15]
    lea     rax, [rax+rax*2]
    LD3     xmm4, r13+rax*4, xmm5
    mov     eax, [r15+4]
    lea     rax, [rax+rax*2]
    LD3     xmm0, r13+rax*4, xmm5
    subps   xmm0, xmm4
    push    rcx
    push    rcx
    call    m_vec
    movaps  [rsp+16], xmm0
    mov     eax, [r15+8]
    lea     rax, [rax+rax*2]
    LD3     xmm0, r13+rax*4, xmm5
    subps   xmm0, xmm4
    call    m_vec
    movaps  xmm1, [rsp+16]
    CROSS   xmm2, xmm1, xmm0, xmm3
    pop     rcx
    pop     rcx
    DOT3    xmm2, xmm2
    sqrtss  xmm2, xmm2
    mulss   xmm2, [rip+pq_half]
    addss   xmm6, xmm2
    movss   [r14+rcx*4], xmm6
    add     r15, 12
    inc     ecx
    jmp     3b
4:  movss   [r12+SR_TOT], xmm6
    xorps   xmm0, xmm0
    comiss  xmm6, xmm0
    ja      9f
8:  mov     dword ptr [r12+SR_SRC], 3   # nothing to emit from: its origin
9:  lea     rsp, [rbp-32]
    pop     r15
    pop     r14
    pop     r13
    pop     rbx
    pop     rbp
    ret

# inside(r13=mesh, xmm0=point (its object's)) -> eax = 1 when the point is
#   inside it (crossings of a ray along +X, odd)
inside:
    push    rbx
    push    r14
    push    r15
    movaps  xmm8, xmm0                  # p
    movaps  xmm9, xmm0
    shufps  xmm9, xmm9, 0x55            # py
    movaps  xmm10, xmm0
    shufps  xmm10, xmm10, 0xAA          # pz
    mov     r14, [r13+ME_TRIS]
    mov     r15, [r13+ME_POS]
    mov     ebx, [r13+ME_NTRIS]
    xor     r8d, r8d                    # crossings
1:  test    ebx, ebx
    jz      8f
    dec     ebx
    mov     eax, [r14]
    lea     rax, [rax+rax*2]
    lea     rax, [r15+rax*4]
    mov     ecx, [r14+4]
    lea     rcx, [rcx+rcx*2]
    lea     rcx, [r15+rcx*4]
    mov     edx, [r14+8]
    lea     rdx, [rdx+rdx*2]
    lea     rdx, [r15+rdx*4]
    add     r14, 12
    # d1 = (By-Ay)(pz-Az) - (Bz-Az)(py-Ay), for edges AB, BC, CA
    movss   xmm0, [rcx+4]
    subss   xmm0, [rax+4]
    movss   xmm1, xmm10
    subss   xmm1, [rax+8]
    mulss   xmm0, xmm1
    movss   xmm1, [rcx+8]
    subss   xmm1, [rax+8]
    movss   xmm2, xmm9
    subss   xmm2, [rax+4]
    mulss   xmm1, xmm2
    subss   xmm0, xmm1
    movss   xmm3, xmm0                  # d1 (AB): C's weight
    movss   xmm0, [rdx+4]
    subss   xmm0, [rcx+4]
    movss   xmm1, xmm10
    subss   xmm1, [rcx+8]
    mulss   xmm0, xmm1
    movss   xmm1, [rdx+8]
    subss   xmm1, [rcx+8]
    movss   xmm2, xmm9
    subss   xmm2, [rcx+4]
    mulss   xmm1, xmm2
    subss   xmm0, xmm1
    movss   xmm4, xmm0                  # d2 (BC): A's
    movss   xmm0, [rax+4]
    subss   xmm0, [rdx+4]
    movss   xmm1, xmm10
    subss   xmm1, [rdx+8]
    mulss   xmm0, xmm1
    movss   xmm1, [rax+8]
    subss   xmm1, [rdx+8]
    movss   xmm2, xmm9
    subss   xmm2, [rdx+4]
    mulss   xmm1, xmm2
    subss   xmm0, xmm1
    movss   xmm5, xmm0                  # d3 (CA): B's
    xorps   xmm6, xmm6
    xor     r9d, r9d                    # signs
    comiss  xmm3, xmm6
    seta    r9b
    xor     r10d, r10d
    comiss  xmm4, xmm6
    seta    r10b
    add     r9d, r10d
    xor     r10d, r10d
    comiss  xmm5, xmm6
    seta    r10b
    add     r9d, r10d
    cmp     r9d, 3
    je      2f
    test    r9d, r9d
    jnz     1b
    xor     r9d, r9d                    # all not above: all below?
    comiss  xmm3, xmm6
    setb    r9b
    xor     r10d, r10d
    comiss  xmm4, xmm6
    setb    r10b
    add     r9d, r10d
    xor     r10d, r10d
    comiss  xmm5, xmm6
    setb    r10b
    add     r9d, r10d
    cmp     r9d, 3
    jne     1b
2:  movss   xmm6, xmm3                  # x where it crosses
    addss   xmm6, xmm4
    addss   xmm6, xmm5
    mulss   xmm4, [rax]
    mulss   xmm5, [rcx]
    mulss   xmm3, [rdx]
    addss   xmm4, xmm5
    addss   xmm4, xmm3
    divss   xmm4, xmm6
    comiss  xmm4, xmm8
    jbe     1b
    inc     r8d
    jmp     1b
8:  mov     eax, r8d
    and     eax, 1
    pop     r15
    pop     r14
    pop     rbx
    ret

# fill_build(r12=system) -> eax = the points of a lattice (its spacing:
#   the size, in the world) inside its object's mesh, listed at SR_FILLP
fill_build:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r13
    push    r14
    push    r15
    and     rsp, -16
    sub     rsp, 64
    mov     r13, [r12+SR_MESH]
    mov     edi, [r12+SR_UID]
    call    obj_by_uid
    test    rax, rax
    jz      .Lfb_none
    movss   xmm0, [rax+OB_SCALE]        # the spacing in its object's space
    movss   xmm1, [rax+OB_SCALE+4]
    movss   xmm2, [rax+OB_SCALE+8]
    unpcklps xmm0, xmm1
    movlhps xmm0, xmm2
    andps   xmm0, [rip+pq_abs]
    maxps   xmm0, [rip+pq_tiny4]
    mov     rax, [r12+SR_REC]
    movss   xmm1, [rax+PS_SIZE]
    maxss   xmm1, [rip+pq_k]
    shufps  xmm1, xmm1, 0
    divps   xmm1, xmm0
    andps   xmm1, [rip+pq_xyz]
    movaps  [r12+SR_FD], xmm1
    lea     rax, [r13+ME_BMIN]          # points a side, centred in the box
    LD3     xmm2, rax, xmm5
    lea     rax, [r13+ME_BMAX]
    LD3     xmm3, rax, xmm5
    subps   xmm3, xmm2
    movaps  xmm4, xmm3
    divps   xmm4, xmm1
    roundps xmm4, xmm4, 1
    cvtps2dq xmm5, xmm4
    movdqa  [rsp], xmm5
    mulps   xmm4, xmm1
    subps   xmm3, xmm4                  # the room left over: half each side,
    mulps   xmm3, [rip+pq_half4]        #  then half a spacing
    addps   xmm2, xmm3
    movaps  xmm0, xmm1
    mulps   xmm0, [rip+pq_half4]
    addps   xmm2, xmm0
    andps   xmm2, [rip+pq_xyz]
    movaps  [r12+SR_FO], xmm2
    mov     eax, [rsp]
    mov     ecx, [rsp+4]
    mov     edx, [rsp+8]
    test    eax, eax
    jle     .Lfb_none
    test    ecx, ecx
    jle     .Lfb_none
    test    edx, edx
    jle     .Lfb_none
    mov     [r12+SR_FNX], eax
    mov     [r12+SR_FNY], ecx
    imul    rax, rcx
    imul    rax, rdx
    cmp     rax, 4194304
    ja      .Lfb_none
    mov     [rsp+16], eax               # points in the box
    lea     rsi, [rax*4+4095]           # room for their indices
    and     rsi, -4096
    cmp     esi, [r12+SR_FILLB]
    jbe     1f
    push    rsi
    push    rsi
    mov     rdi, [r12+SR_FILLP]
    test    rdi, rdi
    jz      11f
    mov     esi, [r12+SR_FILLB]
    mov     eax, SYS_MUNMAP
    syscall
11: pop     rsi
    pop     rsi
    mov     dword ptr [r12+SR_FILLB], 0
    mov     qword ptr [r12+SR_FILLP], 0
    mov     [rsp+20], esi
    xor     edi, edi
    mov     edx, PROT_RW
    mov     r10d, MAP_NORES
    mov     r8, -1
    xor     r9d, r9d
    mov     eax, SYS_MMAP
    syscall
    cmp     rax, -4096
    jae     .Lfb_none
    mov     [r12+SR_FILLP], rax
    mov     eax, [rsp+20]
    mov     [r12+SR_FILLB], eax
1:  xor     ebx, ebx                    # each point: inside?
    xor     r14d, r14d
    mov     r15, [r12+SR_FILLP]
2:  cmp     ebx, [rsp+16]
    jae     3f
    mov     eax, ebx
    xor     edx, edx
    div     dword ptr [r12+SR_FNX]
    mov     [rsp+32], edx
    xor     edx, edx
    div     dword ptr [r12+SR_FNY]
    mov     [rsp+36], edx
    mov     [rsp+40], eax
    mov     dword ptr [rsp+44], 0
    movdqa  xmm0, [rsp+32]
    cvtdq2ps xmm0, xmm0
    mulps   xmm0, [r12+SR_FD]
    addps   xmm0, [r12+SR_FO]
    call    inside
    test    eax, eax
    jz      21f
    mov     [r15+r14*4], ebx
    inc     r14d
21: inc     ebx
    jmp     2b
3:  mov     eax, r14d
    jmp     9f
.Lfb_none:
    xor     eax, eax
9:  lea     rsp, [rbp-32]
    pop     r15
    pop     r14
    pop     r13
    pop     rbx
    pop     rbp
    ret

# place(edi=id, r12=system, rsi=out: the point, the normal (vec4 each)) -
#   where a new particle starts, from its source
place:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r13
    push    r14
    push    r15
    and     rsp, -16
    sub     rsp, 48
    mov     ebx, edi
    mov     r14, rsi
    mov     r13, [r12+SR_MESH]
    lea     r15, [r12+SR_MAT]
    mov     eax, [r12+SR_SRC]
    cmp     eax, 1
    je      .Lpl_vol
    cmp     eax, 2
    je      .Lpl_vert
    cmp     eax, 3
    je      .Lpl_point
    cmp     eax, 5
    je      .Lpl_fill
    mov     edi, ebx                    # faces: one by its area
    xor     esi, esi
    call    prand
    mulss   xmm0, [r12+SR_TOT]
    mov     rdx, [r12+SR_CDF]
    xor     eax, eax                    # lo
    mov     ecx, [r12+SR_CDFN]          # hi
1:  cmp     eax, ecx
    jae     2f
    lea     r8d, [rax+rcx]
    shr     r8d, 1
    comiss  xmm0, [rdx+r8*4]
    jb      11f
    lea     eax, [r8+1]
    jmp     1b
11: mov     ecx, r8d
    jmp     1b
2:  mov     ecx, [r12+SR_CDFN]
    dec     ecx
    cmp     eax, ecx
    cmova   eax, ecx
    lea     rax, [rax+rax*2]
    mov     rdx, [r13+ME_TRIS]
    lea     rdx, [rdx+rax*4]
    mov     rcx, [r13+ME_POS]
    mov     eax, [rdx]
    lea     rax, [rax+rax*2]
    LD3     xmm4, rcx+rax*4, xmm5
    movaps  [rsp], xmm4                 # A
    mov     eax, [rdx+4]
    lea     rax, [rax+rax*2]
    LD3     xmm0, rcx+rax*4, xmm5
    subps   xmm0, xmm4
    movaps  [rsp+16], xmm0              # B - A
    mov     eax, [rdx+8]
    lea     rax, [rax+rax*2]
    LD3     xmm0, rcx+rax*4, xmm5
    subps   xmm0, xmm4
    movaps  [rsp+32], xmm0              # C - A
    mov     edi, ebx
    mov     esi, 1
    call    prand
    sqrtss  xmm0, xmm0
    movss   xmm7, xmm0                  # s
    mov     edi, ebx
    mov     esi, 2
    call    prand
    movss   xmm1, xmm7                  # b2 = s r2, b1 = s - b2
    mulss   xmm1, xmm0
    movss   xmm2, xmm7
    subss   xmm2, xmm1
    shufps  xmm1, xmm1, 0
    shufps  xmm2, xmm2, 0
    mulps   xmm2, [rsp+16]
    mulps   xmm1, [rsp+32]
    addps   xmm2, xmm1
    movaps  xmm0, [rsp]
    addps   xmm0, xmm2
    mov     rdi, r15
    call    m_pt
    movaps  [r14], xmm0
    movaps  xmm0, [rsp+16]
    call    m_vec
    movaps  [rsp+16], xmm0
    movaps  xmm0, [rsp+32]
    call    m_vec
    movaps  xmm1, [rsp+16]
    CROSS   xmm2, xmm1, xmm0, xmm3
    movaps  xmm0, xmm2
    call    unit
    movaps  [r14+16], xmm0
    jmp     .Lpl_out
.Lpl_vert:                              # a vertex, its normal (or outwards)
    mov     edi, ebx
    xor     esi, esi
    call    prand
    cvtsi2ss xmm1, dword ptr [r13+ME_NVERTS]
    mulss   xmm0, xmm1
    cvttss2si eax, xmm0
    mov     ecx, [r13+ME_NVERTS]
    dec     ecx
    cmp     eax, ecx
    cmova   eax, ecx
    lea     rax, [rax+rax*2]
    shl     rax, 2
    mov     [rsp+40], rax
    mov     rcx, [r13+ME_POS]
    LD3     xmm0, rcx+rax, xmm5
    movaps  [rsp], xmm0
    mov     rdi, r15
    call    m_pt
    movaps  [r14], xmm0
    mov     rcx, [r13+ME_PNRM]
    test    rcx, rcx
    jz      3f
    mov     rax, [rsp+40]
    LD3     xmm0, rcx+rax, xmm5
    jmp     4f
3:  call    centre
    movaps  xmm1, xmm0
    movaps  xmm0, [rsp]
    subps   xmm0, xmm1
4:  mov     rdi, r15
    call    m_vec
    call    unit
    movaps  [r14+16], xmm0
    jmp     .Lpl_out
.Lpl_vol:                               # inside: tried at random in its box
    mov     dword ptr [rsp+44], 0
5:  mov     edi, ebx
    mov     esi, [rsp+44]
    lea     esi, [rsi+rsi*2+16]
    call    prand
    movss   [rsp+16], xmm0
    mov     edi, ebx
    mov     esi, [rsp+44]
    lea     esi, [rsi+rsi*2+17]
    call    prand
    movss   [rsp+20], xmm0
    mov     edi, ebx
    mov     esi, [rsp+44]
    lea     esi, [rsi+rsi*2+18]
    call    prand
    movss   [rsp+24], xmm0
    mov     dword ptr [rsp+28], 0
    lea     rax, [r13+ME_BMIN]
    LD3     xmm1, rax, xmm5
    lea     rax, [r13+ME_BMAX]
    LD3     xmm2, rax, xmm5
    subps   xmm2, xmm1
    mulps   xmm2, [rsp+16]
    addps   xmm1, xmm2
    movaps  [rsp], xmm1
    movaps  xmm0, xmm1
    call    inside
    test    eax, eax
    jnz     6f
    inc     dword ptr [rsp+44]
    cmp     dword ptr [rsp+44], 32
    jb      5b
6:  movaps  xmm0, [rsp]
    mov     rdi, r15
    call    m_pt
    movaps  [r14], xmm0
    call    centre
    movaps  xmm1, xmm0
    movaps  xmm0, [rsp]
    subps   xmm0, xmm1
    mov     rdi, r15
    call    m_vec
    call    unit
    movaps  [r14+16], xmm0
    jmp     .Lpl_out
.Lpl_fill:                              # a fill: its lattice point (a hair off)
    mov     rax, [r12+SR_FILLP]
    mov     eax, [rax+rbx*4]
    xor     edx, edx
    div     dword ptr [r12+SR_FNX]
    mov     [rsp], edx                  # x
    xor     edx, edx
    div     dword ptr [r12+SR_FNY]
    mov     [rsp+4], edx                # y
    mov     [rsp+8], eax                # z
    mov     dword ptr [rsp+12], 0
    movdqa  xmm0, [rsp]
    cvtdq2ps xmm0, xmm0
    movaps  [rsp+16], xmm0
    xor     ecx, ecx                    # the jitter: 1% of the spacing
51: mov     [rsp+40], ecx
    mov     edi, ebx
    lea     esi, [rcx+12]
    call    prand
    subss   xmm0, [rip+pq_half]
    mulss   xmm0, [rip+pq_jit2]
    mov     ecx, [rsp+40]
    addss   xmm0, [rsp+16+rcx*4]
    movss   [rsp+16+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      51b
    movaps  xmm0, [rsp+16]
    mulps   xmm0, [r12+SR_FD]
    addps   xmm0, [r12+SR_FO]
    mov     rdi, r15
    call    m_pt
    movaps  [r14], xmm0
    movaps  [r14+16], xmm1
    movaps  xmm0, [rip+pq_ey]
    movaps  [r14+16], xmm0
    jmp     .Lpl_out
.Lpl_point:                             # its origin, its +Y
    movss   xmm0, [r15+12]
    movss   xmm1, [r15+28]
    movss   xmm2, [r15+44]
    unpcklps xmm0, xmm1
    movlhps xmm0, xmm2
    andps   xmm0, [rip+pq_xyz]
    movaps  [r14], xmm0
    movaps  xmm0, [rip+pq_ey]
    mov     rdi, r15
    call    m_vec
    call    unit
    movaps  [r14+16], xmm0
.Lpl_out:
    lea     rsp, [rbp-32]
    pop     r15
    pop     r14
    pop     r13
    pop     rbx
    pop     rbp
    ret

# centre(r13=mesh) -> xmm0 = the middle of its bounds
centre:
    lea     rax, [r13+ME_BMIN]
    LD3     xmm0, rax, xmm5
    lea     rax, [r13+ME_BMAX]
    LD3     xmm1, rax, xmm5
    addps   xmm0, xmm1
    mulps   xmm0, [rip+pq_half4]
    ret

# emit_job(rdi=system, esi=begin, edx=end) - particles begin..end of this
#   step's newborn: where, how fast, how long, moved on from their birth
emit_job:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    and     rsp, -16
    sub     rsp, 128        # [0] p [16] n [32] dir [48] u [64] w [80] id, slot
                            # [96] the event's velocity
    mov     r12, rdi
    mov     r13d, esi
    mov     r14d, edx
    mov     r15, [r12+SR_REC]
.Lej_loop:
    cmp     r13d, r14d
    jae     .Lej_out
    mov     eax, r13d                   # its block and place in it
    cmp     eax, [r12+SR_ER]
    jae     1f
    mov     edi, [r12+SR_ELB]
    add     eax, [r12+SR_EC]
    jmp     2f
1:  sub     eax, [r12+SR_ER]
    mov     ecx, eax
    shr     ecx, BLKSH
    and     eax, BLK-1
    add     ecx, [r12+SR_ENB]
    mov     edx, [r12+SR_SI]
    shl     rdx, 12
    lea     rsi, [rip+sr_blk]
    add     rdx, rsi
    mov     edi, [rdx+rcx*4]
2:  mov     [rsp+84], eax
    call    blk_at
    mov     ecx, [rsp+84]
    lea     rbx, [rax+rcx*4]            # its slot (arrays at + A_*)
    mov     eax, [r12+SR_EID]
    add     eax, r13d
    mov     [rsp+80], eax
    cmp     dword ptr [r12+SR_EMODE], 0
    jne     20f
    mov     edi, eax
    lea     rsi, [rsp]
    call    place
    xorps   xmm0, xmm0
    movaps  [rsp+96], xmm0
    jmp     21f
20: mov     edi, r13d                   # born of an event: there
    lea     rsi, [rsp]
    call    ev_place
21: movaps  xmm0, [rsp+16]              # the way: its normal, or the direction
    mov     eax, [r12+SR_EMODE]
    cmp     eax, 3                      #  (a split: on along the bounce)
    je      23f
    cmp     dword ptr [r15+PS_VMODE], 0
    je      22f
    lea     rax, [r15+PS_DIR]
    LD3     xmm0, rax, xmm5
    lea     rdi, [r12+SR_MAT]
    call    m_vec
    jmp     3f
22: cmp     eax, 2                      # births, deaths: along their velocity
    je      23f
    cmp     eax, 4
    jne     3f
23: movaps  xmm1, [rsp+96]
    DOT3    xmm1, xmm1
    comiss  xmm1, [rip+pq_tiny]
    jbe     3f
    movaps  xmm0, [rsp+96]
3:  call    unit
    movaps  [rsp+32], xmm0
    movss   xmm0, [r15+PS_SPREAD]       # in a cone round it
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    jbe     5f
    movaps  xmm0, [rsp+32]              # u: square to it, w = dir x u
    movaps  xmm1, [rip+pq_ex]
    movss   xmm3, xmm0
    andps   xmm3, [rip+pq_abs]
    comiss  xmm3, [rip+pq_09]
    jbe     4f
    movaps  xmm1, [rip+pq_ey]
4:  CROSS   xmm2, xmm0, xmm1, xmm3
    movaps  xmm0, xmm2
    call    unit
    movaps  [rsp+48], xmm0
    movaps  xmm1, [rsp+32]
    CROSS   xmm2, xmm1, xmm0, xmm3
    movaps  [rsp+64], xmm2
    mov     edi, [rsp+80]               # cos t from 1 down to cos(spread)
    mov     esi, 3
    call    prand
    movss   [rsp+88], xmm0
    movss   xmm0, [r15+PS_SPREAD]
    mulss   xmm0, [rip+pq_deg]
    call    sincos
    movss   xmm0, [rip+pq_one]
    subss   xmm0, xmm1                  # 1 - cos s
    mulss   xmm0, [rsp+88]
    movss   xmm1, [rip+pq_one]
    subss   xmm1, xmm0                  # cos t
    movss   [rsp+88], xmm1
    mulss   xmm1, xmm1
    movss   xmm2, [rip+pq_one]
    subss   xmm2, xmm1
    xorps   xmm3, xmm3
    maxss   xmm2, xmm3
    sqrtss  xmm2, xmm2
    movss   [rsp+92], xmm2              # sin t
    mov     edi, [rsp+80]
    mov     esi, 4
    call    prand
    mulss   xmm0, [rip+pq_2pi]
    call    sincos                      # sin p, cos p
    mulss   xmm0, [rsp+92]
    mulss   xmm1, [rsp+92]
    shufps  xmm0, xmm0, 0
    shufps  xmm1, xmm1, 0
    mulps   xmm0, [rsp+64]
    mulps   xmm1, [rsp+48]
    addps   xmm0, xmm1
    movss   xmm1, [rsp+88]
    shufps  xmm1, xmm1, 0
    mulps   xmm1, [rsp+32]
    addps   xmm0, xmm1
    movaps  [rsp+32], xmm0
5:  mov     edi, [rsp+80]               # its speed
    mov     esi, 5
    call    prand
    addss   xmm0, xmm0
    subss   xmm0, [rip+pq_one]
    mulss   xmm0, [r15+PS_SPEEDR]
    addss   xmm0, [rip+pq_one]
    cmp     dword ptr [r12+SR_EMODE], 3
    jne     51f
    movaps  xmm1, [rsp+96]              # a split: as fast as the bounce
    DOT3    xmm1, xmm1
    sqrtss  xmm1, xmm1
    mulss   xmm0, xmm1
    jmp     52f
51: mulss   xmm0, [r15+PS_SPEED]
52: shufps  xmm0, xmm0, 0
    mulps   xmm0, [rsp+32]
    andps   xmm0, [rip+pq_xyz]
    mov     eax, [r12+SR_EMODE]         # events: some of the other's velocity
    cmp     eax, 3
    je      53f
    test    eax, eax
    jz      53f
    movss   xmm1, [r15+PS_INHERIT]
    shufps  xmm1, xmm1, 0
    mulps   xmm1, [rsp+96]
    addps   xmm0, xmm1
    andps   xmm0, [rip+pq_xyz]
53: movaps  [rsp+32], xmm0              # v
    movsd   xmm1, [r12+SR_T1]           # born when: moved on since
    cmp     dword ptr [r12+SR_EMODE], 0 #  (of an event: at the step's end)
    je      54f
    xorpd   xmm2, xmm2
    xorpd   xmm1, xmm1
    jmp     7f
54: cmp     dword ptr [r15+PS_MODE], 0
    jne     6f
    cvtsi2sd xmm2, dword ptr [rsp+80]
    divsd   xmm2, [r12+SR_RATE]
    addsd   xmm2, [r12+SR_TS]
    jmp     7f
6:  movsd   xmm2, [r12+SR_TS]
    xorpd   xmm3, xmm3
    maxsd   xmm2, xmm3
7:  subsd   xmm1, xmm2
    xorpd   xmm3, xmm3
    maxsd   xmm1, xmm3
    cvtsd2ss xmm1, xmm1                 # tau
    movss   [rbx+A_AGE], xmm1
    movss   [rsp+88], xmm1
    movaps  xmm2, [r12+SR_ACC]          # the pull: gravity, or the fields'
    cmp     dword ptr [rip+pt_fields], 0
    je      71f
    lea     rdi, [rsp]
    lea     rsi, [rsp+32]
    mov     edx, [r12+SR_GBIT]
    xor     ecx, ecx
    call    fl_accel
    addps   xmm0, [r12+SR_GADJ]
    movaps  xmm2, xmm0
    movaps  xmm0, [rsp+32]
71: movss   xmm1, [rsp+88]
    shufps  xmm1, xmm1, 0
                                        # x = p + v tau + a tau^2 / 2
    mulps   xmm2, xmm1
    movaps  xmm3, xmm2
    mulps   xmm3, xmm1
    mulps   xmm3, [rip+pq_half4]
    movaps  xmm4, xmm0
    mulps   xmm4, xmm1
    addps   xmm4, xmm3
    addps   xmm4, [rsp]
    addps   xmm0, xmm2                  # v + a tau
    movss   [rbx+A_X], xmm4
    shufps  xmm4, xmm4, 0x39
    movss   [rbx+A_Y], xmm4
    shufps  xmm4, xmm4, 0x39
    movss   [rbx+A_Z], xmm4
    movss   [rbx+A_VX], xmm0
    shufps  xmm0, xmm0, 0x39
    movss   [rbx+A_VY], xmm0
    shufps  xmm0, xmm0, 0x39
    movss   [rbx+A_VZ], xmm0
    mov     edi, [rsp+80]               # how long, how big
    mov     esi, 6
    call    prand
    mulss   xmm0, [r15+PS_LIFER]
    movss   xmm1, [rip+pq_one]
    subss   xmm1, xmm0
    mulss   xmm1, [r15+PS_LIFE]
    movss   [rbx+A_LIFE], xmm1
    mov     edi, [rsp+80]
    mov     esi, 7
    call    prand
    addss   xmm0, xmm0
    subss   xmm0, [rip+pq_one]
    mulss   xmm0, [r15+PS_SIZER]
    addss   xmm0, [rip+pq_one]
    mulss   xmm0, [r15+PS_SIZE]
    movss   [rbx+A_SIZE], xmm0
    mov     eax, [r15+PS_COLOR]
    mov     [rbx+A_COL], eax
    mov     eax, [rsp+80]
    mov     [rbx+A_ID], eax
    mov     dword ptr [rbx+A_FLAG], 0
    inc     r13d
    jmp     .Lej_loop
.Lej_out:
    lea     rsp, [rbp-40]
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret

# =============================================================================
#  Moving
# =============================================================================
# step_job(ctx, esi=begin, edx=end) - pt_list's blocks begin..end: each
#   particle moved by the pull (gravity, or the fields' at it), slowed by its
#   drag, aged; when its system collides, its path cast against the
#   colliders (bounce, die, stick, split; the hits kept as events); the dead
#   dropped (the rest kept in order, their deaths kept as events)
step_job:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    and     rsp, -16
    sub     rsp, 192    # [0] p [16] v [32] a [48] block [52] n4 [56] i [60] its
                        #  place in the list [64] p1 [80] the hit [96] normal
                        #  [112] t
    mov     r12d, esi
    mov     r13d, edx
.Lsj_blk:
    cmp     r12d, r13d
    jae     .Lsj_out
    lea     rax, [rip+pt_list]
    mov     edi, [rax+r12*4]
    mov     [rsp+48], edi
    mov     [rsp+60], r12d
    lea     rax, [rip+ev_bh]            # no events yet
    mov     dword ptr [rax+r12*4], 0
    lea     rax, [rip+ev_bd]
    mov     dword ptr [rax+r12*4], 0
    inc     r12d
    lea     rax, [rip+pt_bsys]
    mov     eax, [rax+rdi*4]
    imul    r14, rax, SR_SZ
    lea     rax, [rip+pt_sr]
    add     r14, rax                    # its system
    lea     rax, [rip+pt_bn]
    mov     r15d, [rax+rdi*4]           # its count
    call    blk_at
    mov     rbx, rax
    lea     ecx, [r15+3]                # the lanes past the end: never dead
    and     ecx, -4
    mov     eax, r15d
1:  cmp     eax, ecx
    jae     2f
    xor     edx, edx
    mov     [rbx+A_X+rax*4], edx
    mov     [rbx+A_Y+rax*4], edx
    mov     [rbx+A_Z+rax*4], edx
    mov     [rbx+A_VX+rax*4], edx
    mov     [rbx+A_VY+rax*4], edx
    mov     [rbx+A_VZ+rax*4], edx
    mov     [rbx+A_AGE+rax*4], edx
    mov     [rbx+A_FLAG+rax*4], edx
    mov     edx, [rip+pq_bigf]
    mov     [rbx+A_LIFE+rax*4], edx
    inc     eax
    jmp     1b
2:  mov     [rsp+52], ecx
    movss   xmm8, [rip+pt_dt]
    shufps  xmm8, xmm8, 0               # dt
    movss   xmm13, [r14+SR_DAMP]
    shufps  xmm13, xmm13, 0
    xor     r9d, r9d                    # any dead
    cmp     dword ptr [rip+pt_fields], 0
    jne     .Lsj_one
    cmp     dword ptr [r14+SR_COLLON], 0
    jne     .Lsj_one
    movaps  xmm9, xmm8                  # dt^2 / 2
    mulps   xmm9, xmm8
    mulps   xmm9, [rip+pq_half4]
    movaps  xmm0, [r14+SR_ACC]
    movaps  xmm10, xmm0
    shufps  xmm10, xmm10, 0x00
    movaps  xmm11, xmm0
    shufps  xmm11, xmm11, 0x55
    movaps  xmm12, xmm0
    shufps  xmm12, xmm12, 0xAA
    movaps  xmm3, xmm10                 # a dt
    mulps   xmm3, xmm8
    movaps  xmm4, xmm11
    mulps   xmm4, xmm8
    movaps  xmm5, xmm12
    mulps   xmm5, xmm8
    mulps   xmm10, xmm9                 # a dt^2 / 2
    mulps   xmm11, xmm9
    mulps   xmm12, xmm9
    xor     eax, eax
.Lsj_four:                              # four at a time
    cmp     eax, ecx
    jae     .Lsj_dead
.macro AXIS p, v, ah, ad
    movaps  xmm0, [rbx+\p+rax*4]
    movaps  xmm1, [rbx+\v+rax*4]
    movaps  xmm2, xmm1
    mulps   xmm2, xmm8
    addps   xmm0, xmm2
    addps   xmm0, \ah
    addps   xmm1, \ad
    mulps   xmm1, xmm13
    movaps  [rbx+\p+rax*4], xmm0
    movaps  [rbx+\v+rax*4], xmm1
.endm
    AXIS    A_X, A_VX, xmm10, xmm3
    AXIS    A_Y, A_VY, xmm11, xmm4
    AXIS    A_Z, A_VZ, xmm12, xmm5
    movaps  xmm0, [rbx+A_AGE+rax*4]
    addps   xmm0, xmm8
    movaps  [rbx+A_AGE+rax*4], xmm0
    cmpnltps xmm0, [rbx+A_LIFE+rax*4]
    movmskps edx, xmm0
    or      r9d, edx
    add     eax, 4
    jmp     .Lsj_four
.Lsj_one:                               # one at a time: the fields, the colliders
    mov     dword ptr [rsp+56], 0
    mov     [rsp+120], r9d
3:  mov     eax, [rsp+56]
    cmp     eax, r15d
    jae     .Lsj_done1
    movss   xmm0, [rbx+A_AGE+rax*4]     # older
    addss   xmm0, [rip+pt_dt]
    movss   [rbx+A_AGE+rax*4], xmm0
    test    dword ptr [rbx+A_FLAG+rax*4], 1 # stuck: stays
    jnz     .Lsj_age
    movss   xmm0, [rbx+A_X+rax*4]
    movss   xmm1, [rbx+A_Y+rax*4]
    movss   xmm2, [rbx+A_Z+rax*4]
    unpcklps xmm0, xmm1
    movlhps xmm0, xmm2
    andps   xmm0, [rip+pq_xyz]
    movaps  [rsp], xmm0
    movss   xmm0, [rbx+A_VX+rax*4]
    movss   xmm1, [rbx+A_VY+rax*4]
    movss   xmm2, [rbx+A_VZ+rax*4]
    unpcklps xmm0, xmm1
    movlhps xmm0, xmm2
    andps   xmm0, [rip+pq_xyz]
    movaps  [rsp+16], xmm0
    movaps  xmm0, [r14+SR_ACC]
    cmp     dword ptr [rip+pt_fields], 0
    je      31f
    lea     rdi, [rsp]
    lea     rsi, [rsp+16]
    mov     edx, [r14+SR_GBIT]
    xor     ecx, ecx
    call    fl_accel
    addps   xmm0, [r14+SR_GADJ]
31: movss   xmm8, [rip+pt_dt]
    shufps  xmm8, xmm8, 0
    movaps  xmm1, xmm0                  # x += v dt + a dt^2 / 2
    mulps   xmm1, xmm8
    movaps  xmm2, xmm1                  #  (a dt)
    mulps   xmm1, xmm8
    mulps   xmm1, [rip+pq_half4]
    movaps  xmm3, [rsp+16]
    mulps   xmm3, xmm8
    addps   xmm1, xmm3
    addps   xmm1, [rsp]
    movaps  xmm3, [rsp+16]              # v = (v + a dt) / (1 + drag dt)
    addps   xmm3, xmm2
    movss   xmm4, [r14+SR_DAMP]
    shufps  xmm4, xmm4, 0
    mulps   xmm3, xmm4
    andps   xmm1, [rip+pq_xyz]
    andps   xmm3, [rip+pq_xyz]
    movaps  [rsp+64], xmm1
    movaps  [rsp+16], xmm3
    cmp     dword ptr [r14+SR_COLLON], 0
    je      .Lsj_store
    lea     rdi, [rsp]                  # its path: does it hit something?
    call    pc_cast
    test    eax, eax
    jz      .Lsj_store
    movaps  xmm0, [rsp+96]              # back off the surface a little
    mulps   xmm0, [rip+pq_eps4]
    addps   xmm0, [rsp+80]
    movaps  [rsp+64], xmm0
    movaps  xmm0, [rsp+16]              # v . n < 0: bounce, rub
    movaps  xmm1, xmm0
    DOT3    xmm1, [rsp+96]
    xorps   xmm2, xmm2
    comiss  xmm1, xmm2
    jae     4f
    shufps  xmm1, xmm1, 0
    mulps   xmm1, [rsp+96]              # the normal part
    subps   xmm0, xmm1                  # along the surface
    movss   xmm2, [rip+pq_one]
    subss   xmm2, [r14+SR_FRIC]
    shufps  xmm2, xmm2, 0
    mulps   xmm0, xmm2
    movss   xmm2, [r14+SR_BOUNCE]
    shufps  xmm2, xmm2, 0
    mulps   xmm1, xmm2
    movaps  xmm2, xmm1                  # too slow to leave: it rests there
    DOT3    xmm2, xmm2
    comiss  xmm2, [r14+SR_REST]
    jae     43f
    xorps   xmm1, xmm1
43: subps   xmm0, xmm1
    andps   xmm0, [rip+pq_xyz]
    movaps  [rsp+16], xmm0
4:  mov     eax, [rsp+56]
    mov     ecx, [r14+SR_ONHIT]
    cmp     ecx, 2
    jne     41f
    or      dword ptr [rbx+A_FLAG+rax*4], 1     # sticks
    xorps   xmm0, xmm0
    movaps  [rsp+16], xmm0
    jmp     42f
41: test    ecx, ecx                    # dies (or splits)
    jz      42f
    mov     edx, [rbx+A_LIFE+rax*4]
    mov     [rbx+A_AGE+rax*4], edx
    mov     dword ptr [rsp+120], 1
42: mov     r8d, [rsp+60]               # the hit: counted, kept as an event
    lea     r11, [rip+ev_bh]
    mov     ecx, [r11+r8*4]
    inc     dword ptr [r11+r8*4]
    test    dword ptr [r14+SR_LISTEN], 1
    jz      .Lsj_store
    imul    r8, r8, 2*BLK*EV_SZ
    add     r8, [rip+pt_stage]
    imul    rcx, rcx, EV_SZ
    add     r8, rcx
    movaps  xmm0, [rsp+80]
    movaps  [r8], xmm0
    mov     dword ptr [r8+12], 1
    movaps  xmm0, [rsp+16]
    movaps  [r8+16], xmm0
    mov     ecx, [rbx+A_ID+rax*4]
    mov     [r8+28], ecx
    movaps  xmm0, [rsp+96]
    movaps  [r8+32], xmm0
.Lsj_store:
    mov     eax, [rsp+56]
    movaps  xmm1, [rsp+64]
    movaps  xmm3, [rsp+16]
    movss   [rbx+A_X+rax*4], xmm1
    shufps  xmm1, xmm1, 0x39
    movss   [rbx+A_Y+rax*4], xmm1
    shufps  xmm1, xmm1, 0x39
    movss   [rbx+A_Z+rax*4], xmm1
    movss   [rbx+A_VX+rax*4], xmm3
    shufps  xmm3, xmm3, 0x39
    movss   [rbx+A_VY+rax*4], xmm3
    shufps  xmm3, xmm3, 0x39
    movss   [rbx+A_VZ+rax*4], xmm3
.Lsj_age:
    mov     eax, [rsp+56]
    movss   xmm0, [rbx+A_AGE+rax*4]
    comiss  xmm0, [rbx+A_LIFE+rax*4]
    jb      5f
    mov     dword ptr [rsp+120], 1
5:  inc     dword ptr [rsp+56]
    jmp     3b
.Lsj_done1:
    mov     r9d, [rsp+120]
.Lsj_dead:                              # the dead out, the rest in order
    test    r9d, r9d
    jz      .Lsj_blk
    xor     eax, eax                    # read
    xor     edx, edx                    # kept
5:  cmp     eax, r15d
    jae     7f
    movss   xmm0, [rbx+A_AGE+rax*4]
    comiss  xmm0, [rbx+A_LIFE+rax*4]
    jae     6f
    cmp     eax, edx
    je      51f
    xor     ecx, ecx
52: imul    r8, rcx, AR                 # each array
    lea     r8, [rbx+r8]
    mov     r10d, [r8+rax*4]
    mov     [r8+rdx*4], r10d
    inc     ecx
    cmp     ecx, NARR
    jb      52b
51: inc     edx
    inc     eax
    jmp     5b
6:  test    dword ptr [r14+SR_LISTEN], 2    # a death: an event
    jz      61f
    mov     r8d, [rsp+60]
    lea     r11, [rip+ev_bd]
    mov     ecx, [r11+r8*4]
    inc     dword ptr [r11+r8*4]
    imul    r8, r8, 2*BLK*EV_SZ
    add     r8, [rip+pt_stage]
    add     r8, BLK*EV_SZ
    imul    rcx, rcx, EV_SZ
    add     r8, rcx
    mov     r10d, [rbx+A_X+rax*4]
    mov     [r8], r10d
    mov     r10d, [rbx+A_Y+rax*4]
    mov     [r8+4], r10d
    mov     r10d, [rbx+A_Z+rax*4]
    mov     [r8+8], r10d
    mov     dword ptr [r8+12], 2
    mov     r10d, [rbx+A_VX+rax*4]
    mov     [r8+16], r10d
    mov     r10d, [rbx+A_VY+rax*4]
    mov     [r8+20], r10d
    mov     r10d, [rbx+A_VZ+rax*4]
    mov     [r8+24], r10d
    mov     r10d, [rbx+A_ID+rax*4]
    mov     [r8+28], r10d
    xorps   xmm0, xmm0
    movaps  [r8+32], xmm0
61: inc     eax
    jmp     5b
7:  mov     edi, [rsp+48]
    lea     rax, [rip+pt_bn]
    mov     [rax+rdi*4], edx
    jmp     .Lsj_blk
.Lsj_out:
    lea     rsp, [rbp-40]
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret

# =============================================================================
#  Asking
# =============================================================================
# pt_info(edi=what, esi=particle) -> xmm0: 0 particles alive, 1 systems
#   running, 2 the last frame's time (ms), 3 the last step's (ms), 4 blocks
#   in use, 5 steps done; for particle i (in the systems' order): 6..8 its
#   place, 9..11 its velocity, 12 its age, 13 its lifetime, 14 its size, 15
#   its id, 16 its colour; 17 the last viewport draw (ms), 18 the
#   particles it drew; 19 hits so far (all systems); 20 system i's
#   particles born of events so far, 21 its hits so far, 22 its particles;
#   the liquid solver: 23 its last frame (ms), 24 the most neighbours, 25
#   a particle's mass, 26 the kernel's size, 27 the densest (rho / rho0)
pt_info:
    xorps   xmm0, xmm0
    cmp     edi, 0
    jne     1f
    xor     eax, eax
    xor     ecx, ecx
    lea     rdx, [rip+pt_sr]
10: cmp     ecx, [rip+pt_ns]
    jae     11f
    add     eax, [rdx+SR_N]
    add     rdx, SR_SZ
    inc     ecx
    jmp     10b
11: cvtsi2ss xmm0, eax
    ret
1:  cmp     edi, 1
    jne     2f
    cvtsi2ss xmm0, dword ptr [rip+pt_ns]
    ret
2:  cmp     edi, 2
    jne     3f
    movss   xmm0, [rip+pt_msf]
    ret
3:  cmp     edi, 3
    jne     4f
    movss   xmm0, [rip+pt_mss]
    ret
4:  cmp     edi, 4
    jne     5f
    cmp     qword ptr [rip+pt_pool], 0
    je      49f
    mov     eax, NBLK
    sub     eax, [rip+pt_nfree]
    cvtsi2ss xmm0, eax
49: ret
5:  cmp     edi, 5
    jne     6f
    cvtsi2ss xmm0, dword ptr [rip+pt_now]
    ret
6:  cmp     edi, 17
    jne     61f
    movss   xmm0, [rip+pd_ms]
    ret
61: cmp     edi, 18
    jne     62f
    cvtsi2ss xmm0, dword ptr [rip+pd_n]
    ret
62: cmp     edi, 19
    jne     63f
    xor     eax, eax
    xor     ecx, ecx
    lea     rdx, [rip+pt_sr]
621:cmp     ecx, [rip+pt_ns]
    jae     622f
    add     eax, [rdx+SR_HITS]
    add     rdx, SR_SZ
    inc     ecx
    jmp     621b
622:cvtsi2ss xmm0, eax
    ret
63: cmp     edi, 20
    jne     64f
    cmp     esi, [rip+pt_ns]
    jae     9f
    imul    rax, rsi, SR_SZ
    lea     rdx, [rip+pt_sr]
    cvtsi2ss xmm0, dword ptr [rdx+rax+SR_ENEXT]
    ret
64: cmp     edi, 23                     # 23.. the liquid solver's
    jb      640f
    sub     edi, 23
    jmp     lq_info
640:cmp     edi, 21
    jb      65f
    cmp     edi, 22
    ja      9f
    cmp     esi, [rip+pt_ns]
    jae     9f
    imul    rax, rsi, SR_SZ
    lea     rdx, [rip+pt_sr]
    add     rdx, rax
    mov     eax, [rdx+SR_HITS]
    cmp     edi, 21
    je      641f
    mov     eax, [rdx+SR_N]
641:cvtsi2ss xmm0, eax
    ret
65: cmp     edi, 16
    ja      9f
    test    esi, esi
    js      9f
    push    rbx
    push    r12
    push    r13
    mov     r12d, edi
    mov     r13d, esi
    xor     ebx, ebx                    # the system, the block it is in
7:  cmp     ebx, [rip+pt_ns]
    jae     8f
    mov     edi, ebx
    call    sys_blocks
    imul    rdx, rbx, SR_SZ
    lea     rcx, [rip+pt_sr]
    mov     r8d, [rcx+rdx+SR_NB]
    xor     ecx, ecx
71: cmp     ecx, r8d
    jae     72f
    mov     edi, [rax+rcx*4]
    lea     rdx, [rip+pt_bn]
    mov     edx, [rdx+rdi*4]
    cmp     r13d, edx
    jb      73f
    sub     r13d, edx
    inc     ecx
    jmp     71b
72: inc     ebx
    jmp     7b
73: call    blk_at
    lea     rcx, [rip+pi_offs]
    mov     edx, r12d
    sub     edx, 6
    mov     edx, [rcx+rdx*4]
    add     rax, rdx
    cmp     r12d, 15
    jae     74f
    movss   xmm0, [rax+r13*4]
    jmp     8f
74: mov     eax, [rax+r13*4]
    cvtsi2ss xmm0, rax
8:  pop     r13
    pop     r12
    pop     rbx
9:  ret

.section .rodata
.align 4
pi_offs:        .long A_X, A_Y, A_Z, A_VX, A_VY, A_VZ, A_AGE, A_LIFE, A_SIZE, A_ID, A_COL
.align 16
pq_abs:         .long 0x7fffffff, 0x7fffffff, 0x7fffffff, 0x7fffffff
pq_09:          .float 0.9
.text

# =============================================================================
#  Operators
# =============================================================================
# ps_add(rdi=object, rsi=settings or 0) -> eax = its new system's number
#   (1 ..), or 0
ps_add:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12, rsi
    mov     edi, [rbx+OB_UID]
    call    ps_new
    test    rax, rax
    jz      8f
    mov     rdi, rax
    mov     rsi, r12
    call    ps_parse
    mov     dword ptr [rip+dirty], 1
    mov     edi, [rbx+OB_UID]
    call    ps_count
    jmp     9f
8:  lea     rdi, [rip+s_full]
    call    log_line
    xor     eax, eax
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# which(rsi=text) -> eax = the system it names first ("system n": n - 1,
#   else 0), rsi = the rest
which:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rsi
    xor     r12d, r12d
    mov     rsi, rbx
    call    im_next_word
    test    eax, eax
    jz      9f
    push    rsi
    push    rsi
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_system]
    call    str_eq
    pop     rsi
    pop     rsi
    test    eax, eax
    jz      9f
    call    im_next_word
    mov     rbx, rsi
    test    eax, eax
    jz      9f
    lea     rsi, [rip+im_word]
    lea     rdx, [rsi+rax]
    call    parse_float
    test    eax, eax
    jz      9f
    cvttss2si r12d, xmm0
    dec     r12d
    xor     eax, eax
    test    r12d, r12d
    cmovs   r12d, eax
9:  mov     eax, r12d
    mov     rsi, rbx
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# active -> rax = the active object, or 0 (said in the console)
active:
    sub     rsp, 8
    mov     edi, [rip+active_obj]
    call    obj_get
    test    rax, rax
    jnz     9f
    lea     rdi, [rip+s_noobj]
    call    log_line
    xor     eax, eax
9:  add     rsp, 8
    ret

# particles.add [settings]
do_ps_add:
    push    rbx
    call    active
    test    rax, rax
    jz      9f
    mov     rbx, rax
    mov     rdi, rax
    mov     rsi, [rip+op_arg]
    call    ps_add
    test    eax, eax
    jz      9f
    cmp     dword ptr [rip+op_quiet], 0
    jne     9f
    lea     rdi, [rip+s_added]
    mov     rsi, rbx
    call    log_pair
9:  pop     rbx
    ret

# particles.set [system n] settings
do_ps_set:
    push    rbx
    push    r12
    push    r13
    call    active
    test    rax, rax
    jz      9f
    mov     rbx, rax
    mov     rsi, [rip+op_arg]
    call    which
    mov     r12, rsi
    mov     edi, [rbx+OB_UID]
    mov     esi, eax
    call    ps_nth_own
    test    rax, rax
    jz      8f
    mov     rdi, rax
    mov     rsi, r12
    call    ps_parse
    mov     dword ptr [rip+dirty], 1
    jmp     9f
8:  lea     rdi, [rip+s_nosys]
    mov     rsi, rbx
    call    log_pair
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# particles.remove [system n]
do_ps_remove:
    push    rbx
    call    active
    test    rax, rax
    jz      9f
    mov     rbx, rax
    mov     rsi, [rip+op_arg]
    call    which
    mov     edi, [rbx+OB_UID]
    mov     esi, eax
    call    ps_del
    lea     rdi, [rip+s_removed]
    test    eax, eax
    jnz     1f
    lea     rdi, [rip+s_nosys]
1:  mov     rsi, rbx
    call    log_pair
    mov     dword ptr [rip+dirty], 1
9:  pop     rbx
    ret


# =============================================================================
#  Drawing (stage P2)
#
#  Points and sprites: every particle projected in parallel (by block) into
#  a buffer of 64-bit keys a pixel - the depth (1/z, nearest smallest) over
#  the colour - by an atomic minimum, so the picture is the same on any
#  number of threads; then the rows composited over the rasterizer's
#  colour and depth. Objects: an instance block of the particles (pt_iblock,
#  also what renders see) drawn by inst.s.
# =============================================================================
.equ SR_DMODE,  220                     # (drawing) how: 0 points, 1 sprites,
.equ SR_DC1,    224                     #  2 objects, -1 not; the colours,
.equ SR_DC2,    228
.equ SR_DRAMP,  232                     #  a ramp,
.equ SR_DSE,    236                     #  the size at the end,
.equ SR_DPX,    240                     #  points' pixels
.section .bss
.align 16
pd_eye:         .skip 16
pd_right:       .skip 16
pd_up:          .skip 16
pd_fwd:         .skip 16
.align 8
pd_buf:         .skip 8                 # the keys
pd_ib:          .skip 8*PB_MAX          # each system's instance block
pd_ibk:         .skip 8*PB_MAX          #  made for (steps, key)
pd_icol:        .skip 8*PB_MAX          #  its particles' colours (u32)
pd_icap:        .skip 4*PB_MAX          #  room for them
pt_sphere:      .skip 8                 # a sphere (an icosahedron, radius 1)
.align 4
pd_ms:          .skip 4                 # the last draw (ms)
pd_n:           .skip 4                 #  particles drawn
pd_w:           .skip 4
pd_h:           .skip 4
pd_cx:          .skip 4
pd_cy:          .skip 4
pd_f:           .skip 4
pd_any:         .skip 4

.section .rodata
.align 16
pq_bigw:        .float 1e30, 1e30, 1e30, 0
pq_jit2:        .float 0.02
pq_inf4:        .long -1, -1, -1, -1
pq_c255:        .float 255.0
pq_shade0:      .float 0.55
pq_shade1:      .float 0.45
pq_rmax:        .float 48.0
pq_rmin:        .float 0.75
pq_px1:         .float 1.0
pq_px8:         .float 8.0
# an icosahedron: 12 corners (radius 1), 20 faces
pq_ico_a:       .float 0.0, 0.0
ico_v:          .float -0.52573111,  0.85065081, 0
                .float  0.52573111,  0.85065081, 0
                .float -0.52573111, -0.85065081, 0
                .float  0.52573111, -0.85065081, 0
                .float 0, -0.52573111,  0.85065081
                .float 0,  0.52573111,  0.85065081
                .float 0, -0.52573111, -0.85065081
                .float 0,  0.52573111, -0.85065081
                .float  0.85065081, 0, -0.52573111
                .float  0.85065081, 0,  0.52573111
                .float -0.85065081, 0, -0.52573111
                .float -0.85065081, 0,  0.52573111
ico_f:          .long 0, 11, 5,  0, 5, 1,  0, 1, 7,  0, 7, 10,  0, 10, 11
                .long 1, 5, 9,  5, 11, 4,  11, 10, 2,  10, 7, 6,  7, 1, 8
                .long 3, 9, 4,  3, 4, 2,  3, 2, 6,  3, 6, 8,  3, 8, 9
                .long 4, 9, 5,  2, 4, 11,  6, 2, 10,  8, 6, 7,  9, 8, 1
.text

# ramp(eax=colour at birth, edx=at the end, xmm0=t 0..1) -> eax (leaf)
ramp:
    xor     r8d, r8d
    mov     ecx, 16
1:  mov     r9d, eax
    shr     r9d, cl
    and     r9d, 255
    mov     r10d, edx
    shr     r10d, cl
    and     r10d, 255
    sub     r10d, r9d
    cvtsi2ss xmm1, r10d
    mulss   xmm1, xmm0
    cvtss2si r10d, xmm1
    add     r9d, r10d
    shl     r9d, cl
    or      r8d, r9d
    sub     ecx, 8
    jns     1b
    mov     eax, r8d
    ret

# shade(eax=colour, xmm0=k 0..1) -> eax = colour x k (leaf)
shade:
    xor     r8d, r8d
    mov     ecx, 16
1:  mov     r9d, eax
    shr     r9d, cl
    and     r9d, 255
    cvtsi2ss xmm1, r9d
    mulss   xmm1, xmm0
    cvttss2si r9d, xmm1
    shl     r9d, cl
    or      r8d, r9d
    sub     ecx, 8
    jns     1b
    mov     eax, r8d
    ret

# pd_put(r8d=x, r9d=y (viewport), r11=key) - the nearest wins (leaf: rax,
#   r10)
pd_put:
    cmp     r8d, [rip+pd_w]
    jae     9f
    cmp     r9d, [rip+pd_h]
    jae     9f
    mov     r10d, r9d
    imul    r10d, [rip+pd_w]
    add     r10d, r8d
    shl     r10, 3
    add     r10, [rip+pd_buf]
    mov     rax, [r10]
1:  cmp     r11, rax
    jae     9f
    lock cmpxchg [r10], r11
    jnz     1b
9:  ret

# pt_draw - the particles into the viewport being drawn (after the
#   rasterizer and instances: its colour and depth)
pt_draw:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    and     rsp, -16
    sub     rsp, 32
    mov     dword ptr [rip+pd_n], 0
    cmp     dword ptr [rip+pt_ns], 0
    je      .Ldr_out
    cmp     dword ptr [rip+rs_w], 0
    jle     .Ldr_out
    cmp     dword ptr [rip+rs_h], 0
    jle     .Ldr_out
    call    now_ns
    mov     [rsp], rax
    mov     eax, [rip+rs_w]             # the view
    mov     [rip+pd_w], eax
    mov     eax, [rip+rs_h]
    mov     [rip+pd_h], eax
    movss   xmm0, [rip+vp_cx]
    cvtsi2ss xmm1, dword ptr [rip+rs_x0]
    subss   xmm0, xmm1
    movss   [rip+pd_cx], xmm0
    movss   xmm0, [rip+vp_cy]
    cvtsi2ss xmm1, dword ptr [rip+rs_y0]
    subss   xmm0, xmm1
    movss   [rip+pd_cy], xmm0
    mov     eax, [rip+vp_focal]
    mov     [rip+pd_f], eax
    lea     rax, [rip+eye]
    LD3     xmm0, rax, xmm1
    movaps  [rip+pd_eye], xmm0
    lea     rax, [rip+right]
    LD3     xmm0, rax, xmm1
    movaps  [rip+pd_right], xmm0
    lea     rax, [rip+up]
    LD3     xmm0, rax, xmm1
    movaps  [rip+pd_up], xmm0
    lea     rax, [rip+fwd]
    LD3     xmm0, rax, xmm1
    movaps  [rip+pd_fwd], xmm0
    xor     ebx, ebx                    # each system: how it is drawn
    xor     r13d, r13d                  #  (the blocks of points and sprites)
    mov     dword ptr [rip+pd_any], 0
1:  cmp     ebx, [rip+pt_ns]
    jae     3f
    imul    r12, rbx, SR_SZ
    lea     rax, [rip+pt_sr]
    add     r12, rax
    mov     dword ptr [r12+SR_DMODE], -1
    cmp     dword ptr [r12+SR_N], 0
    je      2f
    mov     edi, [r12+SR_UID]
    mov     esi, [r12+SR_K]
    call    ps_nth
    test    rax, rax
    jz      2f
    mov     r14, rax
    mov     eax, [r14+PS_DRAW]
    mov     [r12+SR_DMODE], eax
    mov     eax, [r14+PS_COLOR]
    mov     [r12+SR_DC1], eax
    mov     eax, [r14+PS_COLOR2]
    mov     [r12+SR_DC2], eax
    mov     eax, [r14+PS_RAMP]
    mov     [r12+SR_DRAMP], eax
    mov     eax, [r14+PS_SIZEEND]
    mov     [r12+SR_DSE], eax
    movss   xmm0, [r14+PS_PX]
    maxss   xmm0, [rip+pq_px1]
    minss   xmm0, [rip+pq_px8]
    cvttss2si eax, xmm0
    mov     [r12+SR_DPX], eax
    mov     eax, [r12+SR_N]
    add     [rip+pd_n], eax
    cmp     dword ptr [r14+PS_DRAW], 2
    jne     11f
    mov     edi, ebx                    # objects: instances
    call    pt_iblock
    test    rax, rax
    jz      2f
    mov     rdi, rax
    mov     esi, [r12+SR_DC1]
    call    inst_draw_ib
    jmp     2f
11: mov     dword ptr [rip+pd_any], 1
    mov     edi, ebx
    call    sys_blocks
    xor     ecx, ecx
12: cmp     ecx, [r12+SR_NB]
    jae     2f
    mov     edx, [rax+rcx*4]
    lea     rsi, [rip+pt_list]
    mov     [rsi+r13*4], edx
    lea     rsi, [rip+pt_bsys]
    mov     [rsi+rdx*4], ebx
    inc     r13d
    inc     ecx
    jmp     12b
2:  inc     ebx
    jmp     1b
3:  cmp     dword ptr [rip+pd_any], 0
    je      .Ldr_time
    mov     eax, [rip+pd_w]             # the keys: none yet
    imul    eax, [rip+pd_h]
    lea     rdi, [rip+frame_arena]
    lea     rsi, [rax*8+64]
    mov     [rsp+8], eax
    call    arena_alloc
    test    rax, rax
    jz      .Ldr_time
    add     rax, 15
    and     rax, -16
    mov     [rip+pd_buf], rax
    lea     rdi, [rip+dj_clear]
    xor     esi, esi
    mov     edx, [rip+pd_h]
    mov     ecx, 8
    call    parallel_for
    lea     rdi, [rip+dj_splat]         # the particles
    xor     esi, esi
    mov     edx, r13d
    mov     ecx, 1
    call    parallel_for
    lea     rdi, [rip+dj_comp]          # over the picture
    xor     esi, esi
    mov     edx, [rip+pd_h]
    mov     ecx, 8
    call    parallel_for
.Ldr_time:
    call    now_ns
    sub     rax, [rsp]
    cvtsi2ss xmm0, rax
    mulss   xmm0, [rip+pq_k]
    mulss   xmm0, [rip+pq_k]
    movss   [rip+pd_ms], xmm0
.Ldr_out:
    lea     rsp, [rbp-40]
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret

# dj_clear(ctx, esi=first row, edx=end) - no keys in those rows
dj_clear:
    mov     eax, edx
    sub     eax, esi
    imul    eax, [rip+pd_w]
    mov     ecx, eax
    mov     eax, esi
    imul    eax, [rip+pd_w]
    mov     rdi, [rip+pd_buf]
    lea     rdi, [rdi+rax*8]
    mov     rax, -1
    rep     stosq
    ret

# dj_comp(ctx, esi=first row, edx=end) - the nearest particle at each pixel,
#   when nearer than what is drawn there
dj_comp:
    push    rbx
    push    r12
    push    r13
    mov     r12d, esi
    mov     r13d, edx
    mov     r9, [rip+rs_depth]
    mov     r10, [rip+fb_ptr]
1:  cmp     r12d, r13d
    jae     9f
    mov     eax, r12d
    imul    eax, [rip+pd_w]
    mov     r11, [rip+pd_buf]
    lea     r11, [r11+rax*8]            # the row's keys
    lea     rbx, [r9+rax*4]             # its depth
    mov     eax, [rip+rs_y0]
    add     eax, r12d
    imul    eax, [rip+fb_w]
    add     eax, [rip+rs_x0]
    lea     rdi, [r10+rax*4]            # its pixels
    xor     ecx, ecx
2:  cmp     ecx, [rip+pd_w]
    jae     3f
    mov     rax, [r11+rcx*8]
    cmp     rax, -1
    je      21f
    mov     rdx, rax
    shr     rdx, 32
    not     edx                         # 1/z
    movd    xmm0, edx
    comiss  xmm0, [rbx+rcx*4]
    jbe     21f
    movss   [rbx+rcx*4], xmm0
    mov     [rdi+rcx*4], eax
21: inc     ecx
    jmp     2b
3:  inc     r12d
    jmp     1b
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# dj_splat(ctx, esi=begin, edx=end) - pt_list's blocks begin..end: each
#   particle as a point (a few pixels) or a sprite (a shaded disc of its
#   size), its colour along its ramp
dj_splat:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    and     rsp, -16
    sub     rsp, 64     # [0] block, [4] n, [8] i, [16] cx cy r iz, [32] colour
    mov     r12d, esi
    mov     r13d, edx
.Lds_blk:
    cmp     r12d, r13d
    jae     .Lds_out
    lea     rax, [rip+pt_list]
    mov     edi, [rax+r12*4]
    inc     r12d
    lea     rax, [rip+pt_bsys]
    mov     eax, [rax+rdi*4]
    imul    r14, rax, SR_SZ
    lea     rax, [rip+pt_sr]
    add     r14, rax
    lea     rax, [rip+pt_bn]
    mov     eax, [rax+rdi*4]
    mov     [rsp+4], eax
    call    blk_at
    mov     rbx, rax
    xor     r15d, r15d
.Lds_one:
    cmp     r15d, [rsp+4]
    jae     .Lds_blk
    movss   xmm0, [rbx+A_X+r15*4]       # to the camera
    movss   xmm1, [rbx+A_Y+r15*4]
    movss   xmm2, [rbx+A_Z+r15*4]
    unpcklps xmm0, xmm1
    movlhps xmm0, xmm2
    subps   xmm0, [rip+pd_eye]
    andps   xmm0, [rip+pq_xyz]
    movaps  xmm3, xmm0
    DOT3    xmm3, [rip+pd_fwd]          # z
    comiss  xmm3, [rip+f_near]
    jb      .Lds_next
    movss   xmm4, [rip+pq_one]
    divss   xmm4, xmm3                  # 1/z
    movaps  xmm1, xmm0
    DOT3    xmm1, [rip+pd_right]
    movaps  xmm2, xmm0
    DOT3    xmm2, [rip+pd_up]
    movss   xmm5, xmm4
    mulss   xmm5, [rip+pd_f]
    mulss   xmm1, xmm5
    addss   xmm1, [rip+pd_cx]           # x
    mulss   xmm2, xmm5
    movss   xmm6, [rip+pd_cy]
    subss   xmm6, xmm2                  # y
    movss   [rsp+16], xmm1
    movss   [rsp+20], xmm6
    movss   [rsp+28], xmm4
    movss   [rsp+36], xmm5              # px a metre there
    movss   xmm0, [rbx+A_AGE+r15*4]     # how far through its life
    divss   xmm0, [rbx+A_LIFE+r15*4]
    xorps   xmm1, xmm1
    maxss   xmm0, xmm1
    minss   xmm0, [rip+pq_one]
    movss   [rsp+40], xmm0
    mov     eax, [r14+SR_DC1]
    test    dword ptr [r14+SR_DRAMP], 1
    jz      1f
    mov     edx, [r14+SR_DC2]
    call    ramp
1:  and     eax, 0xffffff
    mov     [rsp+32], eax
    mov     edx, [rsp+28]               # the key: depth over colour
    not     edx
    shl     rdx, 32
    mov     r11, rdx
    cmp     dword ptr [r14+SR_DMODE], 1
    je      .Lds_sprite
.Lds_point:                             # a square of px pixels
    or      r11, rax
    movss   xmm0, [rsp+16]
    cvttss2si r8d, xmm0
    movss   xmm0, [rsp+20]
    cvttss2si r9d, xmm0
    mov     ecx, [r14+SR_DPX]
    mov     eax, ecx
    shr     eax, 1
    sub     r8d, eax
    sub     r9d, eax
    mov     [rsp+44], r8d
    mov     [rsp+48], ecx
    mov     [rsp+52], ecx
2:  mov     r8d, [rsp+44]
    mov     ecx, [rsp+48]
3:  call    pd_put
    inc     r8d
    dec     ecx
    jnz     3b
    inc     r9d
    dec     dword ptr [rsp+52]
    jnz     2b
    jmp     .Lds_next
.Lds_sprite:                            # a disc: its radius in pixels
    movss   xmm0, [r14+SR_DSE]
    subss   xmm0, [rip+pq_one]
    mulss   xmm0, [rsp+40]
    addss   xmm0, [rip+pq_one]
    mulss   xmm0, [rbx+A_SIZE+r15*4]
    mulss   xmm0, [rip+pq_half]
    mulss   xmm0, [rsp+36]
    minss   xmm0, [rip+pq_rmax]
    comiss  xmm0, [rip+pq_rmin]
    ja      4f
    mov     eax, [rsp+32]               # under a pixel: one
    or      r11, rax
    movss   xmm0, [rsp+16]
    cvttss2si r8d, xmm0
    movss   xmm0, [rsp+20]
    cvttss2si r9d, xmm0
    call    pd_put
    jmp     .Lds_next
4:  movss   [rsp+24], xmm0              # r
    mulss   xmm0, xmm0
    movss   [rsp+56], xmm0              # r^2
    movss   xmm0, [rsp+20]
    subss   xmm0, [rsp+24]
    cvttss2si r9d, xmm0
    movss   xmm0, [rsp+20]
    addss   xmm0, [rsp+24]
    cvttss2si eax, xmm0
    mov     [rsp+52], eax               # the last row
    movss   xmm0, [rsp+16]
    subss   xmm0, [rsp+24]
    cvttss2si eax, xmm0
    mov     [rsp+44], eax               # the first column
    movss   xmm0, [rsp+16]
    addss   xmm0, [rsp+24]
    cvttss2si eax, xmm0
    mov     [rsp+48], eax               # the last
5:  cmp     r9d, [rsp+52]
    jg      .Lds_next
    mov     r8d, [rsp+44]
6:  cmp     r8d, [rsp+48]
    jg      7f
    cvtsi2ss xmm0, r8d                  # in the disc: shaded like a ball
    addss   xmm0, [rip+pq_half]
    subss   xmm0, [rsp+16]
    mulss   xmm0, xmm0
    cvtsi2ss xmm1, r9d
    addss   xmm1, [rip+pq_half]
    subss   xmm1, [rsp+20]
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    comiss  xmm0, [rsp+56]
    ja      61f
    divss   xmm0, [rsp+56]
    movss   xmm1, [rip+pq_one]
    subss   xmm1, xmm0
    sqrtss  xmm1, xmm1
    mulss   xmm1, [rip+pq_shade1]
    addss   xmm1, [rip+pq_shade0]
    movss   xmm0, xmm1
    mov     eax, [rsp+32]
    push    r8
    push    r9
    call    shade
    pop     r9
    pop     r8
    mov     r11d, [rsp+28]
    not     r11d
    shl     r11, 32
    or      r11, rax
    call    pd_put
61: inc     r8d
    jmp     6b
7:  inc     r9d
    jmp     5b
.Lds_next:
    inc     r15d
    jmp     .Lds_one
.Lds_out:
    lea     rsp, [rbp-40]
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret

# =============================================================================
#  As instances (objects mode, and what renders see)
# =============================================================================
# sphere -> rax = a ball of radius 1 (an icosahedron, made once), or 0
sphere:
    mov     rax, [rip+pt_sphere]
    test    rax, rax
    jnz     9f
    push    rbx
    push    r12
    sub     rsp, 24
    mov     edi, 12
    mov     esi, 60
    mov     edx, 20
    call    mesh_new
    test    rax, rax
    jz      8f
    mov     rbx, rax
    xor     r12d, r12d
1:  imul    eax, r12d, 12
    lea     rcx, [rip+ico_v]
    movss   xmm0, [rcx+rax]
    movss   xmm1, [rcx+rax+4]
    movss   xmm2, [rcx+rax+8]
    mov     rdi, rbx
    call    mesh_add_vert
    inc     r12d
    cmp     r12d, 12
    jb      1b
    xor     r12d, r12d
2:  imul    eax, r12d, 12
    lea     rsi, [rip+ico_f]
    add     rsi, rax
    mov     rdi, rbx
    mov     edx, 3
    call    mesh_add_poly
    inc     r12d
    cmp     r12d, 20
    jb      2b
    mov     rdi, rbx
    call    mesh_finish
    mov     [rip+pt_sphere], rbx
    mov     rax, rbx
8:  add     rsp, 24
    pop     r12
    pop     rbx
9:  ret

# pt_iblock(edi=system) -> rax = an instance block of its particles (made
#   again when they moved), rdx = their colours (u32 each), or 0: spheres
#   of their size, or its objects (each picked by the id), turned at random
#   or along the velocity
pt_iblock:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    and     rsp, -16
    sub     rsp, 128
    mov     ebx, edi
    imul    r12, rbx, SR_SZ
    lea     rax, [rip+pt_sr]
    add     r12, rax
    mov     eax, [rip+pt_now]           # made for these steps already?
    shl     rax, 32
    xor     rax, [rip+pt_hash]
    lea     rcx, [rip+pd_ibk]
    lea     rdx, [rip+pd_ib]
    cmp     qword ptr [rdx+rbx*8], 0
    je      1f
    cmp     [rcx+rbx*8], rax
    je      .Lib_have
1:  mov     [rcx+rbx*8], rax
    mov     rdi, [rdx+rbx*8]            # (the old one goes)
    mov     qword ptr [rdx+rbx*8], 0
    call    inst_unref
    mov     edi, [r12+SR_UID]
    mov     esi, [r12+SR_K]
    call    ps_nth
    test    rax, rax
    jz      .Lib_none
    mov     r15, rax                    # its settings
    mov     r13d, [r12+SR_N]
    test    r13d, r13d
    jz      .Lib_none
    mov     edi, r13d
    call    inst_new
    test    rax, rax
    jz      .Lib_none
    lea     rcx, [rip+pd_ib]
    mov     [rcx+rbx*8], rax
    mov     r14, rax                    # the block
    lea     rcx, [rip+pd_icap]          # room for the colours
    cmp     [rcx+rbx*4], r13d
    jae     2f
    lea     rcx, [rip+pd_icol]
    mov     rdi, [rcx+rbx*8]
    test    rdi, rdi
    jz      11f
    lea     rcx, [rip+pd_icap]
    mov     esi, [rcx+rbx*4]
    shl     rsi, 2
    mov     eax, SYS_MUNMAP
    syscall
11: lea     esi, [r13+r13*1]            # (twice: room to grow)
    lea     rcx, [rip+pd_icap]
    mov     [rcx+rbx*4], esi
    shl     rsi, 2
    xor     edi, edi
    mov     edx, PROT_RW
    mov     r10d, MAP_ANON_PRIV
    mov     r8, -1
    xor     r9d, r9d
    mov     eax, SYS_MMAP
    syscall
    cmp     rax, -4096
    jb      12f
    xor     eax, eax
    lea     rcx, [rip+pd_icap]
    mov     [rcx+rbx*4], eax
12: lea     rcx, [rip+pd_icol]
    mov     [rcx+rbx*8], rax
    test    rax, rax
    jz      .Lib_none
2:  mov     dword ptr [rsp+64], 0       # the prototypes: its objects, or a ball
    cmp     dword ptr [r15+PS_DRAW], 2
    jne     3f
    xor     ecx, ecx
21: cmp     ecx, [r15+PS_NOBJ]
    jae     3f
    mov     [rsp+68], ecx
    mov     edi, [r15+PS_OBJS+rcx*4]
    call    obj_by_uid
    test    rax, rax
    jz      22f
    mov     rdi, rax
    call    obj_eval
    test    rax, rax
    jz      22f
    cmp     dword ptr [rax+ME_NTRIS], 0
    je      22f
    mov     rdi, r14
    mov     rsi, rax
    call    inst_proto
    test    eax, eax
    js      22f
    mov     ecx, [rsp+64]
    mov     [rsp+72+rcx], al            # (the ids that are there)
    inc     dword ptr [rsp+64]
22: mov     ecx, [rsp+68]
    inc     ecx
    jmp     21b
3:  cmp     dword ptr [rsp+64], 0
    jne     4f
    call    sphere
    test    rax, rax
    jz      .Lib_none
    mov     rdi, r14
    mov     rsi, rax
    call    inst_proto
    mov     byte ptr [rsp+72], 0
    mov     dword ptr [rsp+64], 1
4:  mov     [r14+4], r13d               # (IB_N) every particle
    mov     dword ptr [rsp+80], 0       # instance
    xor     ecx, ecx                    # block in the system's list
    mov     [rsp+84], ecx
.Lib_blk:
    mov     ecx, [rsp+84]
    cmp     ecx, [r12+SR_NB]
    jae     .Lib_have
    inc     dword ptr [rsp+84]
    mov     edi, [r12+SR_SI]
    call    sys_blocks
    mov     ecx, [rsp+84]
    mov     edi, [rax+rcx*4-4]
    lea     rax, [rip+pt_bn]
    mov     eax, [rax+rdi*4]
    mov     [rsp+88], eax
    call    blk_at
    mov     rbx, rax
    xor     r13d, r13d
.Lib_one:
    cmp     r13d, [rsp+88]
    jae     .Lib_blk
    mov     edi, [rbx+A_ID+r13*4]       # its prototype, by its id
    mov     esi, 9
    call    prand
    cvtsi2ss xmm1, dword ptr [rsp+64]
    mulss   xmm0, xmm1
    cvttss2si eax, xmm0
    mov     ecx, [rsp+64]
    dec     ecx
    cmp     eax, ecx
    cmova   eax, ecx
    movzx   eax, byte ptr [rsp+72+rax]
    mov     rdi, r14
    mov     ecx, [rsp+80]
    push    rax
    push    rax
    call    inst_pids
    pop     rdx
    pop     rdx
    mov     ecx, [rsp+80]
    mov     [rax+rcx], dl
    movss   xmm0, [rbx+A_AGE+r13*4]     # its size now (spheres: half of it)
    divss   xmm0, [rbx+A_LIFE+r13*4]
    xorps   xmm1, xmm1
    maxss   xmm0, xmm1
    minss   xmm0, [rip+pq_one]
    movss   [rsp+92], xmm0
    movss   xmm1, [r15+PS_SIZEEND]
    subss   xmm1, [rip+pq_one]
    mulss   xmm1, xmm0
    addss   xmm1, [rip+pq_one]
    mulss   xmm1, [rbx+A_SIZE+r13*4]
    cmp     dword ptr [r15+PS_DRAW], 2
    je      41f
    mulss   xmm1, [rip+pq_half]
41: movss   [rsp+96], xmm1              # the scale
    mov     eax, [r15+PS_COLOR]         # its colour
    test    dword ptr [r15+PS_RAMP], 1
    jz      42f
    mov     edx, [r15+PS_COLOR2]
    movss   xmm0, [rsp+92]
    call    ramp
42: or      eax, 0xff000000
    lea     rcx, [rip+pd_icol]
    mov     edx, [r12+SR_SI]
    mov     rcx, [rcx+rdx*8]
    mov     edx, [rsp+80]
    mov     [rcx+rdx*4], eax
    # its turn: an axis (x) and the two square to it
    cmp     dword ptr [r15+PS_ALIGN], 1
    jne     43f
    movss   xmm0, [rbx+A_VX+r13*4]      # along the velocity: x
    movss   xmm1, [rbx+A_VY+r13*4]
    movss   xmm2, [rbx+A_VZ+r13*4]
    unpcklps xmm0, xmm1
    movlhps xmm0, xmm2
    movaps  xmm1, xmm0
    DOT3    xmm1, xmm1
    comiss  xmm1, [rip+pq_tiny]
    ja      44f
43: mov     edi, [rbx+A_ID+r13*4]       # at random: a direction
    mov     esi, 10
    call    prand
    addss   xmm0, xmm0
    subss   xmm0, [rip+pq_one]          # cos
    movss   [rsp], xmm0
    mov     edi, [rbx+A_ID+r13*4]
    mov     esi, 11
    call    prand
    mulss   xmm0, [rip+pq_2pi]
    call    sincos
    movss   xmm2, [rsp]
    movss   xmm3, xmm2
    mulss   xmm3, xmm3
    movss   xmm4, [rip+pq_one]
    subss   xmm4, xmm3
    xorps   xmm3, xmm3
    maxss   xmm4, xmm3
    sqrtss  xmm4, xmm4
    mulss   xmm0, xmm4
    mulss   xmm1, xmm4
    unpcklps xmm1, xmm0                 # (s cos p, s sin p, c)
    movlhps xmm1, xmm2
    movaps  xmm0, xmm1
44: call    unit
    movaps  [rsp], xmm0                 # x
    movaps  xmm1, [rip+pq_ey]
    movss   xmm2, xmm0
    shufps  xmm2, xmm2, 0x55
    andps   xmm2, [rip+pq_abs]
    comiss  xmm2, [rip+pq_09]
    jbe     45f
    movaps  xmm1, [rip+pq_ex]
45: CROSS   xmm2, xmm0, xmm1, xmm3      # z = x x helper
    movaps  xmm0, xmm2
    call    unit
    movaps  [rsp+32], xmm0
    movaps  xmm1, [rsp]
    CROSS   xmm2, xmm0, xmm1, xmm3      # y = z x x
    movaps  [rsp+16], xmm2
    mov     rdi, r14                    # the matrix: columns x y z x scale,
                                        #  the place
    call    inst_mats
    imul    ecx, [rsp+80], 48
    add     rax, rcx
    movss   xmm5, [rsp+96]
    xor     ecx, ecx
5:  movss   xmm0, [rsp+rcx*4]
    mulss   xmm0, xmm5
    movss   [rax], xmm0
    movss   xmm0, [rsp+16+rcx*4]
    mulss   xmm0, xmm5
    movss   [rax+4], xmm0
    movss   xmm0, [rsp+32+rcx*4]
    mulss   xmm0, xmm5
    movss   [rax+8], xmm0
    imul    edx, ecx, AR
    add     rdx, rbx
    movss   xmm0, [rdx+r13*4]           # (A_X, A_Y, A_Z)
    movss   [rax+12], xmm0
    add     rax, 16
    inc     ecx
    cmp     ecx, 3
    jb      5b
    inc     dword ptr [rsp+80]
    inc     r13d
    jmp     .Lib_one
.Lib_have:
    mov     ebx, [r12+SR_SI]
    lea     rcx, [rip+pd_ib]
    mov     rax, [rcx+rbx*8]
    lea     rcx, [rip+pd_icol]
    mov     rdx, [rcx+rbx*8]
    jmp     9f
.Lib_none:
    xor     eax, eax
    xor     edx, edx
9:  lea     rsp, [rbp-40]
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret

# pt_stamp -> rax: changes when the particles do (live.s)
pt_stamp:
    mov     eax, [rip+pt_now]
    shl     rax, 32
    or      eax, [rip+pt_ns]
    xor     rax, [rip+pt_hash]
    ret

# pt_render(edi=system) -> rax = its instance block for a render, rdx = the
#   particles' colours, ecx = the material (+1) its emitter has, or rax 0
#   (none, or left out of renders)
pt_render:
    push    rbx
    push    r12
    push    r13
    mov     ebx, edi
    cmp     ebx, [rip+pt_ns]
    jae     8f
    imul    r12, rbx, SR_SZ
    lea     rax, [rip+pt_sr]
    add     r12, rax
    mov     edi, [r12+SR_UID]
    mov     esi, [r12+SR_K]
    call    ps_nth
    test    rax, rax
    jz      8f
    test    dword ptr [rax+PS_RFLAGS], 1
    jnz     8f
    mov     edi, ebx
    call    pt_iblock
    test    rax, rax
    jz      8f
    push    rax
    push    rdx
    mov     edi, [r12+SR_UID]
    mov     esi, [r12+SR_K]
    call    ps_nth
    mov     edi, [r12+SR_UID]
    cmp     dword ptr [rax+PS_DRAW], 2  # (objects: the first one's material)
    jne     2f
    cmp     dword ptr [rax+PS_NOBJ], 0
    je      2f
    mov     edi, [rax+PS_OBJS]
2:  call    obj_by_uid
    xor     ecx, ecx
    test    rax, rax
    jz      1f
    mov     rdi, rax
    call    mat_of
    lea     ecx, [rax+1]
1:  pop     rdx
    pop     rax
    jmp     9f
8:  xor     eax, eax
9:  pop     r13
    pop     r12
    pop     rbx
    ret


# =============================================================================
#  Collisions and events (stage P3)
#
#  The colliders, gathered once a step (kept while nothing about them
#  changes): the Ground (a plane at its height), landscapes (their heights,
#  la_wheight), and the triangles of rigid bodies and cloth colliders in the
#  world, in a bounding-volume tree (split at the middle of the centres'
#  box, four to a leaf). A colliding particle's path this step (the segment
#  from where it was to where it would be) is cast against all of them; the
#  first hit is where it stops.
# =============================================================================
.equ SR_COLLON, 320                     # (this step) it collides,
.equ SR_BOUNCE, 324                     #  its bounce,
.equ SR_FRIC,   328                     #  friction,
.equ SR_ONHIT,  332                     #  what a hit does
.equ SR_HITS,   336                     # hits so far
.equ SR_REST,   340                     # a bounce slower than this rests
                                        #  (squared: twice its pull in a step)
.equ SR_LIQON,  344                     # a liquid (liquid.s moves it)
.equ SR_FILLP,  352                     # fill: the lattice's points inside (u32)
.equ SR_FILLB,  360                     #  bytes mapped for them
.equ SR_FNX,    364                     #  points along x, y
.equ SR_FNY,    368
.equ SR_FO,     384                     #  the first point (its object's space)
.equ SR_FD,     400                     #  the spacing there
.equ CT_SZ,     64                      # a collider triangle: a, e1, e2, n
.equ CN_SZ,     32                      # a tree node: min (w: left / first),
                                        #  max (w: right / count; bit 31 leaf)
.equ PC_MAXO,   256                     # objects with triangles
.equ PC_MAXL,   8                       # landscapes
.equ PC_STACK,  64

.section .bss
.align 8
pc_tri:         .skip 8                 # the triangles
pc_ix:          .skip 8                 #  in the tree's order (u32)
pc_cen:         .skip 8                 #  their centres (vec4, building)
pc_node:        .skip 8
pc_cap:         .skip 8                 # bytes mapped for each (triangles x)
pc_key:         .skip 8
pc_objs:        .skip 8*PC_MAXO
pc_land:        .skip 8*PC_MAXL
.align 4
pc_ntri:        .skip 4
pc_nn:          .skip 4
pc_no:          .skip 4
pc_nl:          .skip 4
pc_gnd:         .skip 4                 # a ground,
pc_gy:          .skip 4                 #  at this height
pc_any:         .skip 4                 # any colliders

.section .rodata
.align 16
pq_eps4:        .float 0.001, 0.001, 0.001, 0
pq_big4:        .float 1e30, 1e30, 1e30, 1e30
pq_one4:        .float 1.0, 1.0, 1.0, 1.0
pq_third4:      .float 0.33333334, 0.33333334, 0.33333334, 0
pq_nbig4:       .float -1e30, -1e30, -1e30, -1e30
.align 4
pq_dx:          .float 0.05
pq_four:        .float 4.0
pq_ev:          .float 0.002
pq_mtiny:       .float 1.0e-9
.text

# pc_add(rdi=object) - one more object with triangles (not twice)
pc_add:
    mov     ecx, [rip+pc_no]
    cmp     ecx, PC_MAXO
    jae     9f
    xor     eax, eax
    lea     rdx, [rip+pc_objs]
1:  cmp     eax, ecx
    jae     2f
    cmp     [rdx+rax*8], rdi
    je      9f
    inc     eax
    jmp     1b
2:  mov     [rdx+rcx*8], rdi
    inc     dword ptr [rip+pc_no]
9:  ret

# pc_usable(rdi=object or 0) -> eax = 1 when its triangles can be hit: a
#   visible mesh, not the Ground, not water, not a landscape
pc_usable:
    xor     eax, eax
    test    rdi, rdi
    jz      9f
    cmp     dword ptr [rdi+OB_TYPE], OT_MESH
    jne     9f
    test    dword ptr [rdi+OB_FLAGS], OBF_HIDDEN|OBF_GROUND|OBF_WATER
    jnz     9f
    push    rdi
    call    la_of
    pop     rdi
    test    rax, rax
    mov     eax, 0
    jnz     9f
    mov     eax, 1
9:  ret

# pt_colliders - what particles hit this step (made again when it changed)
pt_colliders:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    and     rsp, -16
    sub     rsp, 64
    xor     eax, eax
    mov     [rip+pc_no], eax
    mov     [rip+pc_nl], eax
    mov     [rip+pc_gnd], eax
    mov     rbx, [rip+an_cur]           # rigid bodies, cloth colliders
    test    rbx, rbx
    jz      3f
    xor     r12d, r12d
1:  cmp     r12d, [rbx+AN_NRB_]
    jae     2f
    imul    eax, r12d, RB_SZ_
    mov     edi, [rbx+AN_RB_+rax]
    inc     r12d
    call    obj_by_uid
    mov     rdi, rax
    call    pc_usable
    test    eax, eax
    jz      1b
    call    pc_add
    jmp     1b
2:  xor     r12d, r12d
21: cmp     r12d, [rbx+AN_CW_+20]       # (CW_N)
    jae     3f
    imul    eax, r12d, CL_SZ_
    lea     r13, [rbx+AN_CL_+rax]
    inc     r12d
    cmp     dword ptr [r13+4], 3        # (CL_TYPE: a collider)
    jne     21b
    mov     edi, [r13]
    call    obj_by_uid
    mov     rdi, rax
    call    pc_usable
    test    eax, eax
    jz      21b
    call    pc_add
    jmp     21b
3:  xor     r12d, r12d                  # landscapes, the ground
31: cmp     r12d, [rip+obj_count]
    jae     4f
    mov     edi, r12d
    call    obj_at
    inc     r12d
    cmp     dword ptr [rax+OB_TYPE], OT_MESH
    jne     31b
    test    dword ptr [rax+OB_FLAGS], OBF_HIDDEN
    jnz     31b
    test    dword ptr [rax+OB_FLAGS], OBF_GROUND
    jz      32f
    mov     dword ptr [rip+pc_gnd], 1
    mov     ecx, [rax+OB_LOC+4]
    mov     [rip+pc_gy], ecx
    jmp     31b
32: mov     r13, rax
    mov     rdi, rax
    call    la_of
    test    rax, rax
    jz      31b
    mov     ecx, [rip+pc_nl]
    cmp     ecx, PC_MAXL
    jae     31b
    lea     rdx, [rip+pc_land]
    mov     [rdx+rcx*8], r13
    inc     dword ptr [rip+pc_nl]
    jmp     31b
4:  mov     r13, 0x2545F4914F6CDD1D     # what the triangles were made from
    xor     r12d, r12d
    xor     r14d, r14d                  # triangles
41: cmp     r12d, [rip+pc_no]
    jae     42f
    lea     rax, [rip+pc_objs]
    mov     r15, [rax+r12*8]
    inc     r12d
    mov     rax, r13
    lea     rdi, [r15+OB_LOC]
    mov     esi, 36
    call    sc_mix
    mov     r13, rax
    mov     rdi, r15
    call    obj_eval
    xor     r13, rax
    mov     ecx, [rax+ME_VER]
    xor     r13, rcx
    mov     rcx, 0x9E3779B97F4A7C15
    imul    r13, rcx
    add     r14d, [rax+ME_NTRIS]
    jmp     41b
42: mov     eax, [rip+pc_no]
    xor     r13, rax
    mov     dword ptr [rip+pc_any], 0
    mov     eax, [rip+pc_gnd]
    or      eax, [rip+pc_nl]
    or      eax, r14d
    jz      9f
    mov     dword ptr [rip+pc_any], 1
    test    r14d, r14d
    jz      43f
    cmp     r13, [rip+pc_key]
    je      9f
43: mov     [rip+pc_key], r13
    mov     [rip+pc_ntri], r14d
    mov     dword ptr [rip+pc_nn], 0
    test    r14d, r14d
    jz      9f
    mov     eax, r14d                   # room: triangles, order, centres,
    cmp     rax, [rip+pc_cap]           #  nodes (2 a triangle)
    jbe     5f
    call    pc_unmap
    lea     rax, [r14+r14]
    mov     [rip+pc_cap], rax
    imul    rsi, rax, CT_SZ
    call    pc_map
    mov     [rip+pc_tri], rax
    mov     rax, [rip+pc_cap]
    lea     rsi, [rax*4]
    call    pc_map
    mov     [rip+pc_ix], rax
    mov     rax, [rip+pc_cap]
    shl     rax, 4
    mov     rsi, rax
    call    pc_map
    mov     [rip+pc_cen], rax
    mov     rax, [rip+pc_cap]
    imul    rsi, rax, 2*CN_SZ
    call    pc_map
    mov     [rip+pc_node], rax
    cmp     qword ptr [rip+pc_tri], 0
    je      .Lpc_fail
    cmp     qword ptr [rip+pc_ix], 0
    je      .Lpc_fail
    cmp     qword ptr [rip+pc_cen], 0
    je      .Lpc_fail
    cmp     qword ptr [rip+pc_node], 0
    je      .Lpc_fail
5:  xor     r12d, r12d                  # the triangles in the world
    xor     r14d, r14d
51: cmp     r12d, [rip+pc_no]
    jae     6f
    lea     rax, [rip+pc_objs]
    mov     r15, [rax+r12*8]
    inc     r12d
    mov     rdi, r15
    lea     rsi, [rsp]
    call    obj_matrix
    mov     rdi, r15
    call    obj_eval
    mov     rbx, rax
    xor     r13d, r13d
52: cmp     r13d, [rbx+ME_NTRIS]
    jae     51b
    imul    eax, r13d, 12
    add     rax, [rbx+ME_TRIS]
    mov     r8, rax
    mov     r9, [rbx+ME_POS]
    imul    rdx, r14, CT_SZ
    add     rdx, [rip+pc_tri]
    xor     ecx, ecx
53: mov     eax, [r8+rcx*4]
    lea     rax, [rax+rax*2]
    LD3     xmm0, r9+rax*4, xmm5
    lea     rdi, [rsp]
    push    rcx
    push    rdx
    call    m_pt
    pop     rdx
    pop     rcx
    shl     ecx, 4
    movaps  [rdx+rcx], xmm0
    shr     ecx, 4
    inc     ecx
    cmp     ecx, 3
    jb      53b
    movaps  xmm0, [rdx]                 # a, e1, e2, n
    movaps  xmm1, [rdx+16]
    movaps  xmm2, [rdx+32]
    movaps  xmm6, xmm0                  # (the centre)
    addps   xmm6, xmm1
    addps   xmm6, xmm2
    mulps   xmm6, [rip+pq_third4]
    subps   xmm1, xmm0
    subps   xmm2, xmm0
    movaps  [rdx+16], xmm1
    movaps  [rdx+32], xmm2
    CROSS   xmm3, xmm1, xmm2, xmm4
    movaps  xmm0, xmm3
    call    unit
    movaps  [rdx+48], xmm0
    mov     rax, [rip+pc_cen]
    mov     rcx, r14
    shl     rcx, 4
    movaps  [rax+rcx], xmm6
    mov     rax, [rip+pc_ix]
    mov     [rax+r14*4], r14d
    inc     r14d
    inc     r13d
    jmp     52b
6:  xor     edi, edi                    # the tree
    mov     esi, r14d
    call    pc_build
    jmp     9f
.Lpc_fail:
    call    pc_unmap
    mov     dword ptr [rip+pc_ntri], 0
    mov     qword ptr [rip+pc_key], 0
9:  lea     rsp, [rbp-40]
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret

# pc_map(rsi=bytes) -> rax (0: none)
pc_map:
    xor     edi, edi
    mov     edx, PROT_RW
    mov     r10d, MAP_NORES
    mov     r8, -1
    xor     r9d, r9d
    mov     eax, SYS_MMAP
    syscall
    cmp     rax, -4096
    jb      1f
    xor     eax, eax
1:  ret

# pc_unmap - the triangles' memory goes
pc_unmap:
    push    rbx
    mov     rbx, [rip+pc_cap]
    test    rbx, rbx
    jz      9f
    mov     rdi, [rip+pc_tri]
    imul    rsi, rbx, CT_SZ
    call    1f
    mov     rdi, [rip+pc_ix]
    lea     rsi, [rbx*4]
    call    1f
    mov     rdi, [rip+pc_cen]
    mov     rsi, rbx
    shl     rsi, 4
    call    1f
    mov     rdi, [rip+pc_node]
    imul    rsi, rbx, 2*CN_SZ
    call    1f
    xor     eax, eax
    mov     [rip+pc_tri], rax
    mov     [rip+pc_ix], rax
    mov     [rip+pc_cen], rax
    mov     [rip+pc_node], rax
    mov     [rip+pc_cap], rax
9:  pop     rbx
    ret
1:  test    rdi, rdi
    jz      2f
    mov     eax, SYS_MUNMAP
    syscall
2:  ret

# pc_build(edi=first, esi=end in pc_ix) -> eax = a node over them (made
#   with its children)
pc_build:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r12d, edi
    mov     r13d, esi
    mov     ebx, [rip+pc_nn]
    inc     dword ptr [rip+pc_nn]
    imul    r14, rbx, CN_SZ
    add     r14, [rip+pc_node]
    movaps  xmm6, [rip+pq_big4]         # its box (corners), the centres' box
    movaps  xmm7, [rip+pq_nbig4]
    movaps  xmm8, xmm6
    movaps  xmm9, xmm7
    mov     ecx, r12d
1:  cmp     ecx, r13d
    jae     2f
    mov     rax, [rip+pc_ix]
    mov     eax, [rax+rcx*4]
    imul    rdx, rax, CT_SZ
    add     rdx, [rip+pc_tri]
    movaps  xmm0, [rdx]
    minps   xmm6, xmm0
    maxps   xmm7, xmm0
    movaps  xmm1, xmm0
    addps   xmm1, [rdx+16]
    minps   xmm6, xmm1
    maxps   xmm7, xmm1
    addps   xmm0, [rdx+32]
    minps   xmm6, xmm0
    maxps   xmm7, xmm0
    shl     rax, 4
    add     rax, [rip+pc_cen]
    minps   xmm8, [rax]
    maxps   xmm9, [rax]
    inc     ecx
    jmp     1b
2:  andps   xmm6, [rip+pq_xyz]
    andps   xmm7, [rip+pq_xyz]
    movaps  [r14], xmm6
    movaps  [r14+16], xmm7
    mov     eax, r13d
    sub     eax, r12d
    cmp     eax, 4
    ja      3f
    mov     [r14+12], r12d              # a leaf
    or      eax, 0x80000000
    mov     [r14+28], eax
    jmp     9f
3:  subps   xmm9, xmm8                  # split the longest side at its middle
    xor     r15d, r15d
    movss   xmm0, xmm9
    movaps  xmm1, xmm9
    shufps  xmm1, xmm1, 0x55
    comiss  xmm1, xmm0
    jbe     31f
    mov     r15d, 1
    movss   xmm0, xmm1
31: movaps  xmm1, xmm9
    shufps  xmm1, xmm1, 0xAA
    comiss  xmm1, xmm0
    jbe     32f
    mov     r15d, 2
    movss   xmm0, xmm1
32: mulss   xmm0, [rip+pq_half]
    addss   xmm0, [rip+pq_tiny]
    movss   [rsp-8], xmm0
    movaps  [rsp-32], xmm8
    movss   xmm1, [rsp-32+r15*4]        # the middle
    addss   xmm1, [rsp-8]
    mov     ecx, r12d                   # partition: below it first
    mov     edx, r13d
    mov     rsi, [rip+pc_ix]
    mov     rdi, [rip+pc_cen]
4:  cmp     ecx, edx
    jae     5f
    mov     eax, [rsi+rcx*4]
    mov     r8, rax
    shl     r8, 4
    add     r8, rdi
    movss   xmm2, [r8+r15*4]
    comiss  xmm2, xmm1
    jae     41f
    inc     ecx
    jmp     4b
41: dec     edx
    mov     r8d, [rsi+rdx*4]
    mov     [rsi+rcx*4], r8d
    mov     [rsi+rdx*4], eax
    jmp     4b
5:  cmp     ecx, r12d                   # all one side: halves
    je      51f
    cmp     ecx, r13d
    jne     52f
51: mov     ecx, r12d
    add     ecx, r13d
    shr     ecx, 1
52: mov     r15d, ecx
    mov     edi, r12d
    mov     esi, r15d
    call    pc_build
    imul    r14, rbx, CN_SZ             # (the nodes do not move)
    add     r14, [rip+pc_node]
    mov     [r14+12], eax
    mov     edi, r15d
    mov     esi, r13d
    call    pc_build
    imul    r14, rbx, CN_SZ
    add     r14, [rip+pc_node]
    mov     [r14+28], eax
9:  mov     eax, ebx
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# pc_cast(rdi=its state: [0] where it was, [64] would be; out [80] the hit,
#   [96] the surface's normal (against the motion)) -> eax = 1 on a hit:
#   the first of the ground, the landscapes, the triangles. Re-entrant.
pc_cast:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    and     rsp, -16
    sub     rsp, 128+PC_STACK*4     # [0] p0 [16] d [32] 1/d [48] n
                                    # [64] t [68] hit [72] k [76] h0 [80] x
    mov     rbx, rdi
    movaps  xmm0, [rbx]
    movaps  [rsp], xmm0
    movaps  xmm1, [rbx+64]
    subps   xmm1, xmm0
    andps   xmm1, [rip+pq_xyz]
    movaps  [rsp+16], xmm1
    mov     eax, [rip+pq_one]
    mov     [rsp+64], eax               # the first hit so far: none (t 1)
    mov     dword ptr [rsp+68], 0
    mov     dword ptr [rsp+72], 0       # (1: a landscape's, its point at +112)
    cmp     dword ptr [rip+pc_any], 0
    je      .Lpk_out
    cmp     dword ptr [rip+pc_gnd], 0   # the ground: y crosses its height
    je      .Lpk_land
    movss   xmm1, [rsp+64]
    movss   xmm0, [rbx+68]              # where it would be, above it
    subss   xmm0, [rip+pc_gy]
    xorps   xmm2, xmm2
    comiss  xmm0, xmm2
    jae     .Lpk_land
    movss   xmm1, [rbx+4]               # was above: where it crossed
    subss   xmm1, [rip+pc_gy]
    xorps   xmm3, xmm3
    comiss  xmm1, xmm2
    jbe     1f
    movss   xmm3, xmm1
    subss   xmm1, xmm0
    divss   xmm3, xmm1
1:  movss   [rsp+64], xmm3
    mov     dword ptr [rsp+68], 1
    mov     dword ptr [rsp+72], 0
    movaps  xmm0, [rip+pq_ey]
    movaps  [rsp+48], xmm0
.Lpk_land:                              # landscapes: under their height
    xor     r12d, r12d
2:  cmp     r12d, [rip+pc_nl]
    jae     .Lpk_tris
    lea     rax, [rip+pc_land]
    mov     r13, [rax+r12*8]
    inc     r12d
    mov     rdi, r13
    movss   xmm0, [rbx+64]
    movss   xmm1, [rbx+72]
    call    la_wheight
    test    eax, eax
    jz      2b
    movss   xmm1, [rbx+68]
    subss   xmm1, xmm0                  # f1: under it when < 0
    xorps   xmm2, xmm2
    comiss  xmm1, xmm2
    jae     2b
    movss   [rsp+80], xmm1
    mov     rdi, r13
    movss   xmm0, [rbx]
    movss   xmm1, [rbx+8]
    call    la_wheight
    xorps   xmm3, xmm3                  # t: where f crosses 0
    test    eax, eax
    jz      21f
    movss   xmm1, [rbx+4]
    subss   xmm1, xmm0                  # f0
    xorps   xmm2, xmm2
    comiss  xmm1, xmm2
    jbe     21f
    movss   xmm3, xmm1
    subss   xmm1, [rsp+80]
    divss   xmm3, xmm1
21: comiss  xmm3, [rsp+64]
    jae     2b
    movss   [rsp+64], xmm3
    mov     dword ptr [rsp+68], 1
    movss   xmm0, [rsp+16]              # its normal there (by differences)
    mulss   xmm0, xmm3
    addss   xmm0, [rsp]
    movss   [rsp+84], xmm0              # x
    movss   xmm1, [rsp+24]
    mulss   xmm1, xmm3
    addss   xmm1, [rsp+8]
    movss   [rsp+88], xmm1              # z
    movss   xmm0, [rsp+84]              # the point: on the surface
    mov     rdi, r13
    call    la_wheight
    movss   [rsp+116], xmm0
    mov     eax, [rsp+84]
    mov     [rsp+112], eax
    mov     eax, [rsp+88]
    mov     [rsp+120], eax
    mov     dword ptr [rsp+124], 0
    mov     dword ptr [rsp+72], 1
    movss   xmm0, [rsp+84]
    movss   xmm1, [rsp+88]
    addss   xmm0, [rip+pq_dx]
    mov     rdi, r13
    call    la_wheight
    movss   [rsp+92], xmm0
    movss   xmm0, [rsp+84]
    subss   xmm0, [rip+pq_dx]
    movss   xmm1, [rsp+88]
    mov     rdi, r13
    call    la_wheight
    movss   xmm1, [rsp+92]
    subss   xmm1, xmm0
    movss   [rsp+92], xmm1              # dh/dx (x 2 dx)
    movss   xmm0, [rsp+84]
    movss   xmm1, [rsp+88]
    addss   xmm1, [rip+pq_dx]
    mov     rdi, r13
    call    la_wheight
    movss   [rsp+96], xmm0
    movss   xmm0, [rsp+84]
    movss   xmm1, [rsp+88]
    subss   xmm1, [rip+pq_dx]
    mov     rdi, r13
    call    la_wheight
    movss   xmm1, [rsp+96]
    subss   xmm1, xmm0                  # dh/dz
    movss   xmm0, [rsp+92]
    xorps   xmm0, [rip+pq_sgn]
    movss   xmm2, [rip+pq_dx]
    addss   xmm2, xmm2
    xorps   xmm1, [rip+pq_sgn]
    unpcklps xmm0, xmm2                 # (-hx, 2dx, -hz)
    movlhps xmm0, xmm1
    call    unit
    movaps  [rsp+48], xmm0
    jmp     2b
.Lpk_tris:                              # the triangles: the tree
    cmp     dword ptr [rip+pc_ntri], 0
    je      .Lpk_out
    movaps  xmm0, [rsp+16]              # 1/d (huge where d is 0)
    movaps  xmm1, xmm0
    andps   xmm1, [rip+pq_abs]
    cmpltps xmm1, [rip+pq_tiny4]
    movaps  xmm2, xmm1
    andps   xmm2, [rip+pq_tiny4]
    orps    xmm0, xmm2                  # (tiny where 0)
    movaps  xmm2, [rip+pq_one4]
    divps   xmm2, xmm0
    movaps  [rsp+32], xmm2
    mov     dword ptr [rsp+128], 0      # the stack: the root
    mov     r12d, 1
.Lpk_walk:
    test    r12d, r12d
    jz      .Lpk_out
    dec     r12d
    mov     eax, [rsp+128+r12*4]
    imul    r13, rax, CN_SZ
    add     r13, [rip+pc_node]
    movaps  xmm0, [r13]                 # the slabs: enters before t, leaves
    subps   xmm0, [rsp]                 #  after 0
    mulps   xmm0, [rsp+32]
    movaps  xmm1, [r13+16]
    subps   xmm1, [rsp]
    mulps   xmm1, [rsp+32]
    movaps  xmm2, xmm0
    minps   xmm0, xmm1                  # near
    maxps   xmm1, xmm2                  # far
    movaps  xmm2, xmm0
    shufps  xmm2, xmm2, 0x55
    maxss   xmm0, xmm2
    movaps  xmm2, xmm0
    movhlps xmm2, xmm2
    maxss   xmm0, xmm2                  # (lanes 0 1 2)
    movaps  xmm2, xmm1
    shufps  xmm2, xmm2, 0x55
    minss   xmm1, xmm2
    movaps  xmm2, xmm1
    movhlps xmm2, xmm2
    minss   xmm1, xmm2
    xorps   xmm3, xmm3
    maxss   xmm0, xmm3
    minss   xmm1, [rsp+64]
    comiss  xmm0, xmm1
    ja      .Lpk_walk
    mov     eax, [r13+28]
    test    eax, eax
    js      .Lpk_leaf
    cmp     r12d, PC_STACK-2
    jae     .Lpk_walk
    mov     [rsp+128+r12*4], eax
    inc     r12d
    mov     eax, [r13+12]
    mov     [rsp+128+r12*4], eax
    inc     r12d
    jmp     .Lpk_walk
.Lpk_leaf:
    and     eax, 0x7fffffff
    mov     r14d, [r13+12]
    lea     r15d, [r14+rax]
3:  cmp     r14d, r15d
    jae     .Lpk_walk
    mov     rax, [rip+pc_ix]
    mov     eax, [rax+r14*4]
    inc     r14d
    imul    rdx, rax, CT_SZ
    add     rdx, [rip+pc_tri]
    movaps  xmm7, [rsp+16]              # Moller-Trumbore: p = d x e2
    movaps  xmm8, [rdx+32]
    CROSS   xmm9, xmm7, xmm8, xmm4
    movaps  xmm10, [rdx+16]
    movaps  xmm0, xmm10
    DOT3    xmm0, xmm9                  # det
    movaps  xmm1, xmm0
    andps   xmm1, [rip+pq_abs]
    comiss  xmm1, [rip+pq_mtiny]
    jbe     3b
    movss   xmm11, [rip+pq_one]
    divss   xmm11, xmm0                 # 1 / det
    movaps  xmm12, [rsp]
    subps   xmm12, [rdx]                # s = p0 - a
    andps   xmm12, [rip+pq_xyz]
    movaps  xmm0, xmm12
    DOT3    xmm0, xmm9
    mulss   xmm0, xmm11                 # u
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    jb      3b
    comiss  xmm0, [rip+pq_one]
    ja      3b
    movss   xmm13, xmm0
    CROSS   xmm14, xmm12, xmm10, xmm4   # q = s x e1
    movaps  xmm0, xmm7
    DOT3    xmm0, xmm14
    mulss   xmm0, xmm11                 # v
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    jb      3b
    addss   xmm0, xmm13
    comiss  xmm0, [rip+pq_one]
    ja      3b
    movaps  xmm0, xmm8
    DOT3    xmm0, xmm14
    mulss   xmm0, xmm11                 # t
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    jb      3b
    comiss  xmm0, [rsp+64]
    jae     3b
    movss   [rsp+64], xmm0
    mov     dword ptr [rsp+68], 1
    mov     dword ptr [rsp+72], 0
    movaps  xmm0, [rdx+48]              # its normal, against the motion
    movaps  xmm1, xmm0
    DOT3    xmm1, xmm7
    xorps   xmm2, xmm2
    comiss  xmm1, xmm2
    jbe     31f
    xorps   xmm0, [rip+pq_sgn]
    andps   xmm0, [rip+pq_xyz]
31: movaps  [rsp+48], xmm0
    jmp     3b
.Lpk_out:
    xor     eax, eax
    cmp     dword ptr [rsp+68], 0
    je      9f
    movss   xmm0, [rsp+64]              # the hit: p0 + t d
    shufps  xmm0, xmm0, 0
    mulps   xmm0, [rsp+16]
    addps   xmm0, [rsp]
    andps   xmm0, [rip+pq_xyz]
    cmp     dword ptr [rsp+72], 0
    je      8f
    movaps  xmm0, [rsp+112]
8:  movaps  [rbx+80], xmm0
    movaps  xmm0, [rsp+48]
    movaps  [rbx+96], xmm0
    mov     eax, 1
9:  lea     rsp, [rbp-40]
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret

# pt_listen - which systems keep their events this step, and whose events
#   each one born of events uses (by its name)
pt_listen:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    xor     ebx, ebx
1:  cmp     ebx, [rip+pt_ns]
    jae     2f
    imul    rax, rbx, SR_SZ
    lea     rcx, [rip+pt_sr]
    mov     dword ptr [rcx+rax+SR_LISTEN], 0
    mov     qword ptr [rcx+rax+SR_EVS], 0
    inc     ebx
    jmp     1b
2:  xor     ebx, ebx
3:  cmp     ebx, [rip+pt_ns]
    jae     9f
    imul    r12, rbx, SR_SZ
    lea     rax, [rip+pt_sr]
    add     r12, rax
    inc     ebx
    mov     r13, [r12+SR_REC]
    test    r13, r13
    jz      3b
    cmp     dword ptr [r12+SR_COLLON], 0    # it splits: its own hits
    je      4f
    cmp     dword ptr [r13+PS_ONHIT], 3
    jne     4f
    or      dword ptr [r12+SR_LISTEN], 1
4:  cmp     dword ptr [r13+PS_FROM], 4
    jne     3b
    xor     r14d, r14d                  # the one with that name
5:  cmp     r14d, [rip+pt_ns]
    jae     3b
    imul    r15, r14, SR_SZ
    lea     rax, [rip+pt_sr]
    add     r15, rax
    inc     r14d
    mov     edi, [r15+SR_UID]
    mov     esi, [r15+SR_K]
    call    ps_nth
    test    rax, rax
    jz      5b
    lea     rdi, [rax+PS_NAME]
    lea     rsi, [r13+PS_EVNAME]
    call    str_eq
    test    eax, eax
    jz      5b
    mov     [r12+SR_EVS], r15
    mov     eax, [r13+PS_EVKIND]
    cmp     eax, 1
    jne     6f
    or      dword ptr [r15+SR_LISTEN], 1
    jmp     3b
6:  cmp     eax, 2
    jne     3b
    or      dword ptr [r15+SR_LISTEN], 2
    jmp     3b
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# sys_gather(r12=system) - its blocks' hits and deaths this step, in order
sys_gather:
    push    rbx
    push    r13
    push    r14
    xor     eax, eax
    mov     [r12+SR_NH], eax
    mov     [r12+SR_ND], eax
    mov     ecx, [r12+SR_L0]            # its hits, kept or not
    mov     edx, ecx
    add     edx, [r12+SR_LN]
    lea     rsi, [rip+ev_bh]
1:  cmp     ecx, edx
    jae     2f
    add     eax, [rsi+rcx*4]
    inc     ecx
    jmp     1b
2:  add     [r12+SR_HITS], eax
    cmp     qword ptr [rip+pt_stage], 0
    je      9f
    xor     r13d, r13d                  # 0 hits, 1 deaths
1:  cmp     r13d, 2
    jae     9f
    lea     ecx, [r13+1]
    test    [r12+SR_LISTEN], ecx
    jz      7f
    lea     r14, [r12+SR_EVH+r13*8]     # its room
    cmp     qword ptr [r14], 0
    jne     2f
    call    ev_reserve
    mov     [r14], rax
    test    rax, rax
    jz      7f
2:  mov     rdi, [r14]
    xor     ebx, ebx
    mov     r8d, [r12+SR_L0]
3:  mov     eax, [r12+SR_L0]
    add     eax, [r12+SR_LN]
    cmp     r8d, eax
    jae     6f
    lea     rax, [rip+ev_bh]
    test    r13d, r13d
    jz      4f
    lea     rax, [rip+ev_bd]
4:  mov     ecx, [rax+r8*4]
    imul    rsi, r8, 2*BLK*EV_SZ
    add     rsi, [rip+pt_stage]
    imul    rax, r13, BLK*EV_SZ
    add     rsi, rax
    add     ebx, ecx
    imul    ecx, ecx, EV_SZ
    rep     movsb
    inc     r8d
    jmp     3b
6:  mov     [r12+SR_NH+r13*4], ebx
7:  inc     r13d
    jmp     1b
9:  pop     r14
    pop     r13
    pop     rbx
    ret

# ev_place(edi=which of this step's newborn, r12=system, rsi=out: the
#   point, the normal, [96] the event's velocity) - where one born of an
#   event starts: the event's place (a little off the surface for a hit)
ev_place:
    push    rbx
    push    r13
    push    r14
    mov     r14, rsi
    mov     eax, edi
    xor     edx, edx
    div     dword ptr [r12+SR_EVP]      # the event
    cmp     dword ptr [r12+SR_EMODE], 2
    je      .Lev_born
    imul    rax, rax, EV_SZ
    add     rax, [r12+SR_EVA]
    movaps  xmm0, [rax]
    andps   xmm0, [rip+pq_xyz]
    movaps  xmm1, [rax+16]
    andps   xmm1, [rip+pq_xyz]
    movaps  [r14+96], xmm1
    movaps  xmm2, [rax+32]
    movaps  [r14+16], xmm2
    movss   xmm3, [rip+pq_ev]
    shufps  xmm3, xmm3, 0
    mulps   xmm3, xmm2
    addps   xmm0, xmm3
    movaps  [r14], xmm0
    movaps  xmm0, xmm2                  # (none: up)
    DOT3    xmm0, xmm0
    comiss  xmm0, [rip+pq_tiny]
    ja      9f
    movaps  xmm0, [rip+pq_ey]
    movaps  [r14+16], xmm0
    jmp     9f
.Lev_born:                              # the other's newborn: where it is
    mov     r13, [r12+SR_EVS]
    cmp     eax, [r13+SR_ER]
    jae     1f
    mov     edi, [r13+SR_ELB]
    add     eax, [r13+SR_EC]
    jmp     2f
1:  sub     eax, [r13+SR_ER]
    mov     ecx, eax
    shr     ecx, BLKSH
    and     eax, BLK-1
    add     ecx, [r13+SR_ENB]
    mov     edx, [r13+SR_SI]
    shl     rdx, 12
    lea     rsi, [rip+sr_blk]
    add     rdx, rsi
    mov     edi, [rdx+rcx*4]
2:  mov     ebx, eax
    call    blk_at
    lea     rax, [rax+rbx*4]
    movss   xmm0, [rax+A_X]
    movss   xmm1, [rax+A_Y]
    movss   xmm2, [rax+A_Z]
    unpcklps xmm0, xmm1
    movlhps xmm0, xmm2
    andps   xmm0, [rip+pq_xyz]
    movaps  [r14], xmm0
    movss   xmm0, [rax+A_VX]
    movss   xmm1, [rax+A_VY]
    movss   xmm2, [rax+A_VZ]
    unpcklps xmm0, xmm1
    movlhps xmm0, xmm2
    andps   xmm0, [rip+pq_xyz]
    movaps  [r14+96], xmm0
    movaps  xmm1, xmm0
    DOT3    xmm1, xmm1
    comiss  xmm1, [rip+pq_tiny]
    ja      3f
    movaps  xmm0, [rip+pq_ey]
3:  call    unit
    movaps  [r14+16], xmm0
9:  pop     r14
    pop     r13
    pop     rbx
    ret

.section .note.GNU-stack,"",@progbits
