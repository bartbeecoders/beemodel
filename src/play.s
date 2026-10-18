# =============================================================================
#  BeeModel - play mode: walk or fly through the scene while it runs.
#
#  F5 (play.start) snapshots the scene and plays from the viewport's eye:
#
#  walk  a capsule (0.3 m radius, 1.75 m tall, eyes at 1.6) under the
#        rigid-body world's gravity, moved and slid along every mesh's
#        triangles: each tick (fixed 1/120 s steps) it moves, then up to
#        five times takes the deepest contact and leaves it (a contact
#        facing up under 50 degrees is ground; walls and ceilings take the
#        velocity into them away). Blocked on the ground, it tries the move
#        again 0.4 m higher and comes back down onto the step; on the
#        ground it follows slopes down. Space jumps, Shift runs.
#  fly   free, no collisions; Space up, C down, Shift faster. F switches.
#
#  WASD move, the mouse looks (captured: the compositor's locked pointer
#  and relative motion when it has them). The scene's frame runs with the
#  clock, so keys, rigid bodies and cloth play live. Esc stops and asks:
#  K keeps the changes (one undo step), D or Esc discards them (the scene,
#  its frame and the camera as they were).
#
#  Each mesh gets a grid of its triangles in its own space the first time
#  the capsule comes near; queries take the capsule's box into that space,
#  test the triangles found there in world space (scale, rotation, moving
#  objects all fine).
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

.globl pl_walk
.globl pl_run
.globl pl_fly
.globl pl_jump
.globl pl_mode
.globl pl_on
.globl pl_pos
.globl pl_radius
.globl pl_height
.globl play_tick
.globl play_key
.globl play_look
.globl play_motion
.globl play_hud
.globl pl_stat
.globl pl_script_step
.globl pl_script_look

.equ KEY_F5,    63
.equ KEY_A,     30
.equ KEY_S,     31
.equ KEY_D,     32
.equ KEY_C,     46
.equ KEY_LCTRL, 29
.equ IN_FWD,    1                       # held keys
.equ IN_BACK,   2
.equ IN_LEFT,   4
.equ IN_RIGHT,  8
.equ IN_UP,     16
.equ IN_RUN,    32
.equ IN_DOWN,   64
.equ PC_MAX,    256                     # meshes with a grid
.equ PC_SZ,     80
.equ PC_MESH,   0
.equ PC_VER,    8
.equ PC_MAP,    16                      # the mapping: cell offsets, entries,
.equ PC_BYTES,  24                      #  stamps
.equ PC_OFF,    32
.equ PC_ENT,    40
.equ PC_STAMP,  48
.equ PC_N,      56                      # cells x, y, z (u16 each)
.equ PC_CELL,   64                      # f32: a cell's side
.equ PG_CAP,    128
.equ MAP_ANON_PRIV, 0x22

.section .data
.align 4
pl_radius:      .float 0.3
pl_height:      .float 1.75
pl_eye_h:       .float 1.6
pl_step_h:      .float 0.4
pl_walk:        .float 4.0
pl_run:         .float 8.0
pl_fly:         .float 8.0
pl_flyrun:      .float 24.0
pl_jump:        .float 5.0
pl_ground_cos:  .float 0.64             # 50 degrees
pl_dt:          .float 0.0083333333     # 1/120
pl_look_k:      .float 0.0025

.section .bss
.align 16
pl_pos:         .skip 16                # feet
pl_vel:         .skip 16
pl_start:       .skip 16
pl_cam:         .skip 32                # the camera before (yaw .. tz)
pl_box0:        .skip 16                # a query box
pl_box1:        .skip 16
pl_best_n:      .skip 16                # the deepest contact: its normal
pl_mat:         .skip 48                # an object's matrix
pl_inv:         .skip 48                #  and its inverse
pl_tri:         .skip 48                # a triangle in world space
pl_on:          .skip 4                 # 0 off, 1 playing, 2 asking
pl_mode:        .skip 4                 # 1 walk, 2 fly
pl_keys:        .skip 4
pl_ground:      .skip 4
pl_wall:        .skip 4
pl_snap:        .skip 8                 # the snapshot (undo.s)
pl_frame0:      .skip 4                 # the frame play began at
pl_frame_was:   .skip 4
pl_time:        .skip 4                 # seconds played
pl_acc:         .skip 4                 # time not yet stepped
pl_best_d:      .skip 4                 # its depth
pl_best_obj:    .skip 4                 # its object (handle)
pl_cur_obj:     .skip 4                 # (the object being tested)
pl_gobj:        .skip 4                 # the object stood on, where it was
pl_gground:     .skip 4                 # (the last ground contact's object)
pl_gloc:        .skip 12
pl_t_last:      .skip 8
pl_ts:          .skip 16
pl_lastx:       .skip 4
pl_lasty:       .skip 4
pl_haspos:      .skip 4
pl_locked:      .skip 4
pl_stamp:       .skip 4
pl_steps:       .skip 4
pl_tab:         .skip PC_SZ*PC_MAX
pl_ntab:        .skip 4

.section .rodata
.align 16
f_abs:          .long 0x7fffffff, 0x7fffffff, 0x7fffffff, 0x7fffffff
f_xyz:          .long -1, -1, -1, 0
f_up:           .float 0, 1, 0, 0
f_zero:         .float 0.0
f_one:          .float 1.0
f_half:         .float 0.5
f_eps:          .float 1.0e-8
f_tiny:         .float 1.0e-4
f_skin:         .float 0.001
f_big:          .float 1.0e30
f_fall:         .float -1000.0
f_pmax:         .float 1.5
f_pmin:         .float -1.5
f_tmax:         .float 0.1              # the longest tick
f_frame:        .float 0.016666668      # a scripted step's frame
f_snap:         .float 0.25             # down a slope: kept on it
f_cam_d:        .float 0.05
f_rad2deg:      .float 57.29578
f_ceil:         .float -0.7
f_grav:         .float 0, -9.81, 0, 0
s_hud:          .asciz "PLAY   WASD move   mouse look   Space jump   Shift run   F fly   Esc stop"
s_hud_fly:      .asciz "PLAY (fly)   WASD move   mouse look   Space up   C down   Shift faster   F walk   Esc stop"
s_ask:          .asciz "Play stopped:   K  keep the changes      D  discard them"
s_started:      .asciz "  play: walk (Esc stops)"
s_started_f:    .asciz "  play: fly (Esc stops)"
s_kept:         .asciz "  play: changes kept (Ctrl+Z undoes them)"
s_gone:         .asciz "  play: changes discarded"
s_label:        .asciz "Play"
s_walk:         .asciz "walk"
s_flyw:         .asciz "fly"
s_keep:         .asciz "keep"

.text

# =============================================================================
#  Operators
# =============================================================================
OPERATOR op_play_start, "play.start", "Play", do_play_start, key=KEY_F5, flags=OPF_AI_SAFE, doc="Play the scene: walk (or fly) from the viewport's eye while simulations and animations run; Esc stops (keep or discard the changes): play.start [walk|fly] [x y z]"
OPERATOR op_play_stop, "play.stop", "Stop Playing", do_play_stop, flags=OPF_AI_SAFE, doc="Stop play mode: play.stop [keep|discard] (default: discard - the scene as it was)"
OPERATOR op_play_mode, "play.mode", "Walk / Fly", do_play_mode, flags=OPF_AI_SAFE, doc="Switch play mode between walking and flying: play.mode walk|fly"

# do_play_start - play.start [walk|fly] [x y z]
do_play_start:
    push    rbx
    push    r12
    sub     rsp, 8
    cmp     dword ptr [rip+pl_on], 0
    jne     9f
    mov     dword ptr [rip+pl_mode], 1
    mov     rbx, [rip+op_arg]
    test    rbx, rbx
    jz      2f
    mov     rsi, rbx
    call    im_next_word
    test    eax, eax
    jz      2f
    cmp     byte ptr [rip+im_word], 'f'
    jne     1f
    mov     dword ptr [rip+pl_mode], 2
    mov     rbx, rsi                    # (past "fly")
1:  xor     r12d, r12d                  # x y z (words that are not numbers:
11: cmp     r12d, 3                     #  skipped)
    jae     12f
    mov     rsi, rbx
    call    im_next_word
    mov     rbx, rsi
    test    eax, eax
    jz      2f
    lea     rsi, [rip+im_word]
    lea     rdx, [rsi+rax]
    call    parse_float
    test    eax, eax
    jz      11b
    lea     rax, [rip+pl_start]
    movss   [rax+r12*4], xmm0
    inc     r12d
    jmp     11b
12: mov     dword ptr [rip+pl_haspos], 1
2:  lea     rdi, [rip+s_label]          # the scene as it is now
    call    undo_snap
    mov     [rip+pl_snap], rax
    lea     rsi, [rip+cam_yaw]
    lea     rdi, [rip+pl_cam]
    mov     ecx, 24
    rep     movsb
    mov     eax, [rip+an_frame]
    mov     [rip+pl_frame_was], eax
    mov     [rip+pl_frame0], eax
    cmp     dword ptr [rip+pl_haspos], 0 # where: given, or the viewport's eye
    jne     3f
    call    view_eye
    movaps  [rip+pl_start], xmm0
3:  mov     dword ptr [rip+pl_haspos], 0
    movaps  xmm0, [rip+pl_start]
    cmp     dword ptr [rip+pl_mode], 2
    je      31f
    xorps   xmm1, xmm1                  # (walking: the feet below the eye)
    insertps xmm1, [rip+pl_eye_h], 0x10
    subps   xmm0, xmm1
31: andps   xmm0, [rip+f_xyz]
    movaps  [rip+pl_pos], xmm0
    movaps  [rip+pl_start], xmm0
    xorps   xmm0, xmm0
    movaps  [rip+pl_vel], xmm0
    mov     dword ptr [rip+pl_keys], 0
    mov     dword ptr [rip+pl_ground], 0
    mov     dword ptr [rip+pl_time], 0
    mov     dword ptr [rip+pl_acc], 0
    mov     dword ptr [rip+pl_steps], 0
    mov     dword ptr [rip+pl_gobj], 0
    mov     edi, 1                      # simulations live, the logic graphs
    call    rb_live
    call    lg_begin
    call    ms_now
    mov     [rip+pl_t_last], rax
    mov     dword ptr [rip+pl_on], 1
    call    wl_lock_pointer             # (the window: the mouse captured)
    mov     [rip+pl_locked], eax
    mov     dword ptr [rip+pl_lastx], -100000
    call    pl_camera
    lea     rdi, [rip+s_started]
    cmp     dword ptr [rip+pl_mode], 2
    jne     4f
    lea     rdi, [rip+s_started_f]
4:  call    log_line
    mov     dword ptr [rip+dirty], 1
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# view_eye -> xmm0 = the viewport camera's eye (target - fwd x distance)
view_eye:
    sub     rsp, 24
    fld     dword ptr [rip+cam_yaw]
    fsincos
    fstp    dword ptr [rsp]             # cos yaw
    fstp    dword ptr [rsp+4]           # sin yaw
    fld     dword ptr [rip+cam_pitch]
    fsincos
    fstp    dword ptr [rsp+8]           # cos pitch
    fstp    dword ptr [rsp+12]          # sin pitch
    movss   xmm0, [rsp+8]
    mulss   xmm0, [rsp+4]
    mulss   xmm0, [rip+cam_dist]
    addss   xmm0, [rip+cam_tx]
    movss   xmm1, [rsp+12]
    mulss   xmm1, [rip+cam_dist]
    addss   xmm1, [rip+cam_ty]
    movss   xmm2, [rsp+8]
    mulss   xmm2, [rsp]
    mulss   xmm2, [rip+cam_dist]
    addss   xmm2, [rip+cam_tz]
    unpcklps xmm0, xmm1
    movlhps xmm0, xmm2
    andps   xmm0, [rip+f_xyz]
    add     rsp, 24
    ret

# do_play_stop - play.stop [keep|discard]
do_play_stop:
    sub     rsp, 8
    cmp     dword ptr [rip+pl_on], 0
    je      9f
    xor     edi, edi
    mov     rsi, [rip+op_arg]
    test    rsi, rsi
    jz      1f
    call    im_next_word
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+s_keep]
    call    str_eq
    mov     edi, eax
1:  call    play_end
9:  add     rsp, 8
    ret

# play_end(edi=1: keep, 0: discard)
play_end:
    push    rbx
    mov     ebx, edi
    mov     dword ptr [rip+pl_on], 0
    mov     dword ptr [rip+pl_keys], 0
    call    wl_unlock_pointer
    mov     dword ptr [rip+pl_locked], 0
    call    pl_free_grids
    call    lg_end
    xor     edi, edi
    call    rb_live
    mov     rdi, [rip+pl_snap]
    mov     qword ptr [rip+pl_snap], 0
    mov     esi, ebx
    call    undo_back
    test    ebx, ebx
    jnz     1f
    movss   xmm0, [rip+pl_frame_was]    # discarded: the frame, the camera
    call    an_set_frame
    lea     rsi, [rip+pl_cam]
    lea     rdi, [rip+cam_yaw]
    mov     ecx, 24
    rep     movsb
    mov     edi, [rip+vp_area]
    call    cam_store
    lea     rdi, [rip+s_gone]
    call    log_line
    jmp     9f
1:  lea     rdi, [rip+s_kept]
    call    log_line
9:  mov     dword ptr [rip+dirty], 1
    pop     rbx
    ret

# do_play_mode - play.mode walk|fly
do_play_mode:
    sub     rsp, 8
    mov     rsi, [rip+op_arg]
    test    rsi, rsi
    jz      9f
    call    im_next_word
    mov     eax, 1
    cmp     byte ptr [rip+im_word], 'f'
    jne     1f
    mov     eax, 2
1:  mov     [rip+pl_mode], eax
    xorps   xmm0, xmm0
    movaps  [rip+pl_vel], xmm0
9:  add     rsp, 8
    ret

# =============================================================================
#  Input
# =============================================================================
# play_key(edi=evdev, esi=1 pressed / 0 released) -> eax = 1 when taken
play_key:
    cmp     dword ptr [rip+pl_on], 0
    je      .Lpk_no
    cmp     dword ptr [rip+pl_on], 1    # (playing: the logic graphs see it)
    jne     0f
    push    rdi
    push    rsi
    sub     rsp, 8
    call    lg_key
    add     rsp, 8
    pop     rsi
    pop     rdi
0:
    cmp     dword ptr [rip+pl_on], 2    # asking: K keeps, D / Esc discard
    jne     1f
    test    esi, esi
    jz      .Lpk_yes
    cmp     edi, KEY_K
    jne     11f
    mov     edi, 1
    jmp     12f
11: cmp     edi, KEY_D
    je      13f
    cmp     edi, KEY_ESC
    jne     .Lpk_yes
13: xor     edi, edi
12: sub     rsp, 8
    call    play_end
    add     rsp, 8
    jmp     .Lpk_yes
1:  cmp     edi, KEY_ESC
    jne     2f
    test    esi, esi
    jz      .Lpk_yes
    mov     dword ptr [rip+pl_on], 2    # stopped: the question
    mov     dword ptr [rip+pl_keys], 0
    sub     rsp, 8
    call    wl_unlock_pointer
    add     rsp, 8
    mov     dword ptr [rip+pl_locked], 0
    mov     dword ptr [rip+dirty], 1
    jmp     .Lpk_yes
2:  cmp     edi, KEY_F
    jne     3f
    test    esi, esi
    jz      .Lpk_yes
    mov     eax, [rip+pl_mode]
    xor     eax, 3                      # walk <-> fly
    mov     [rip+pl_mode], eax
    xorps   xmm0, xmm0
    movaps  [rip+pl_vel], xmm0
    jmp     .Lpk_yes
3:  xor     eax, eax                    # held keys
    cmp     edi, KEY_W
    jne     31f
    mov     eax, IN_FWD
31: cmp     edi, KEY_S
    jne     32f
    mov     eax, IN_BACK
32: cmp     edi, KEY_A
    jne     33f
    mov     eax, IN_LEFT
33: cmp     edi, KEY_D
    jne     34f
    mov     eax, IN_RIGHT
34: cmp     edi, KEY_SPACE
    jne     35f
    mov     eax, IN_UP
35: cmp     edi, KEY_LEFTSHIFT
    jne     36f
    mov     eax, IN_RUN
36: cmp     edi, KEY_C
    jne     37f
    mov     eax, IN_DOWN
37: cmp     edi, KEY_LCTRL
    jne     38f
    mov     eax, IN_DOWN
38: test    esi, esi
    jz      39f
    or      [rip+pl_keys], eax
    jmp     .Lpk_yes
39: not     eax
    and     [rip+pl_keys], eax
.Lpk_yes:
    mov     eax, 1
    ret
.Lpk_no:
    xor     eax, eax
    ret

# play_look(xmm0=dx, xmm1=dy pixels) - the mouse turns the view
play_look:
    cmp     dword ptr [rip+pl_on], 1
    jne     9f
    mulss   xmm0, [rip+pl_look_k]
    mulss   xmm1, [rip+pl_look_k]
    movss   xmm2, [rip+cam_yaw]
    subss   xmm2, xmm0
    movss   [rip+cam_yaw], xmm2
    movss   xmm2, [rip+cam_pitch]
    addss   xmm2, xmm1
    maxss   xmm2, [rip+f_pmin]
    minss   xmm2, [rip+f_pmax]
    movss   [rip+cam_pitch], xmm2
    mov     dword ptr [rip+dirty], 1
9:  ret

# play_motion(edi=x, esi=y) -> eax = 1 when taken: without a locked pointer
#   the pointer's movement turns the view
play_motion:
    xor     eax, eax
    cmp     dword ptr [rip+pl_on], 0
    je      9f
    cmp     dword ptr [rip+pl_on], 1
    jne     8f
    cmp     dword ptr [rip+pl_locked], 0
    jne     8f
    mov     eax, [rip+pl_lastx]
    mov     [rip+pl_lastx], edi
    mov     ecx, [rip+pl_lasty]
    mov     [rip+pl_lasty], esi
    cmp     eax, -100000
    je      8f
    sub     edi, eax
    sub     esi, ecx
    cvtsi2ss xmm0, edi
    cvtsi2ss xmm1, esi
    sub     rsp, 8
    call    play_look
    add     rsp, 8
8:  mov     eax, 1
9:  ret

# =============================================================================
#  The tick
# =============================================================================
# play_tick - (the main loop) the time since the last tick: the player moved
#   in fixed steps, the scene's frame on
play_tick:
    cmp     dword ptr [rip+pl_on], 1
    jne     9f
    sub     rsp, 8
    call    ms_now
    mov     rcx, rax
    sub     rax, [rip+pl_t_last]
    mov     [rip+pl_t_last], rcx
    cvtsi2ss xmm0, rax
    divss   xmm0, [rip+f_thousand]
    minss   xmm0, [rip+f_tmax]
    call    pl_advance
    add     rsp, 8
9:  ret

# pl_advance(xmm0=seconds) - fixed steps for that time (with what is left
#   over from before), the frame, the camera
pl_advance:
    push    rbx
    sub     rsp, 16
    movss   xmm1, [rip+pl_acc]
    addss   xmm0, xmm1
    movss   [rip+pl_acc], xmm0
1:  movss   xmm0, [rip+pl_acc]
    comiss  xmm0, [rip+pl_dt]
    jb      2f
    subss   xmm0, [rip+pl_dt]
    movss   [rip+pl_acc], xmm0
    movss   xmm0, [rip+pl_time]
    addss   xmm0, [rip+pl_dt]
    movss   [rip+pl_time], xmm0
    call    pl_step
    inc     dword ptr [rip+pl_steps]
    movss   xmm0, [rip+pl_dt]           # the logic graphs, the same step
    call    lg_step
    jmp     1b
2:  call    an_range                    # the scene's frame: by the clock
    mulss   xmm0, [rip+pl_time]
    addss   xmm0, [rip+pl_frame0]
    call    an_set_frame
    call    pl_camera
    mov     dword ptr [rip+dirty], 1
    add     rsp, 16
    pop     rbx
    ret

# pl_camera - the viewport's camera at the player's eyes
pl_camera:
    sub     rsp, 40
    movaps  xmm0, [rip+pl_pos]
    cmp     dword ptr [rip+pl_mode], 2
    je      1f
    xorps   xmm1, xmm1
    insertps xmm1, [rip+pl_eye_h], 0x10
    addps   xmm0, xmm1
1:  movaps  [rsp], xmm0                 # the eye
    fld     dword ptr [rip+cam_yaw]     # target = eye + fwd x d,
    fsincos                             #  fwd = -(cp sy, sp, cp cy)
    fstp    dword ptr [rsp+16]          # cos yaw
    fstp    dword ptr [rsp+20]          # sin yaw
    fld     dword ptr [rip+cam_pitch]
    fsincos
    fstp    dword ptr [rsp+24]          # cos pitch
    fstp    dword ptr [rsp+28]          # sin pitch
    movss   xmm0, [rsp+24]
    mulss   xmm0, [rsp+20]
    mulss   xmm0, [rip+f_cam_d]
    movss   xmm1, [rsp]
    subss   xmm1, xmm0
    movss   [rip+cam_tx], xmm1
    movss   xmm0, [rsp+28]
    mulss   xmm0, [rip+f_cam_d]
    movss   xmm1, [rsp+4]
    subss   xmm1, xmm0
    movss   [rip+cam_ty], xmm1
    movss   xmm0, [rsp+24]
    mulss   xmm0, [rsp+16]
    mulss   xmm0, [rip+f_cam_d]
    movss   xmm1, [rsp+8]
    subss   xmm1, xmm0
    movss   [rip+cam_tz], xmm1
    mov     eax, [rip+f_cam_d]
    mov     [rip+cam_dist], eax
    mov     edi, [rip+vp_area]
    call    cam_store
    add     rsp, 40
    ret

# pl_wish -> xmm0 = the velocity the keys ask for (walk: horizontal)
pl_wish:
    sub     rsp, 24
    fld     dword ptr [rip+cam_yaw]
    fsincos
    fstp    dword ptr [rsp]             # cos yaw
    fstp    dword ptr [rsp+4]           # sin yaw
    fld     dword ptr [rip+cam_pitch]
    fsincos
    fstp    dword ptr [rsp+8]
    fstp    dword ptr [rsp+12]
    xorps   xmm3, xmm3                  # forward amount, right amount, up
    xorps   xmm4, xmm4
    xorps   xmm5, xmm5
    mov     eax, [rip+pl_keys]
    movss   xmm6, [rip+f_one]
    test    eax, IN_FWD
    jz      1f
    addss   xmm3, xmm6
1:  test    eax, IN_BACK
    jz      2f
    subss   xmm3, xmm6
2:  test    eax, IN_RIGHT
    jz      3f
    addss   xmm4, xmm6
3:  test    eax, IN_LEFT
    jz      4f
    subss   xmm4, xmm6
4:  test    eax, IN_UP
    jz      5f
    addss   xmm5, xmm6
5:  test    eax, IN_DOWN
    jz      6f
    subss   xmm5, xmm6
6:  movss   xmm7, [rip+pl_walk]         # speed
    cmp     dword ptr [rip+pl_mode], 2
    jne     61f
    movss   xmm7, [rip+pl_fly]
    test    eax, IN_RUN
    jz      62f
    movss   xmm7, [rip+pl_flyrun]
    jmp     62f
61: test    eax, IN_RUN
    jz      62f
    movss   xmm7, [rip+pl_run]
62: cmp     dword ptr [rip+pl_mode], 2
    je      7f
    # walk: forward (-sy, 0, -cy), right (cy, 0, -sy)
    movss   xmm0, [rsp+4]
    mulss   xmm0, xmm3
    movss   xmm1, [rsp]
    mulss   xmm1, xmm4
    subss   xmm1, xmm0                  # x = cy r - sy f
    movss   xmm0, [rsp]
    mulss   xmm0, xmm3
    movss   xmm2, [rsp+4]
    mulss   xmm2, xmm4
    addss   xmm0, xmm2
    xorps   xmm2, xmm2
    subss   xmm2, xmm0                  # z = -(cy f + sy r)
    xorps   xmm0, xmm0
    jmp     8f
7:  # fly: forward = fwd (with pitch), right, world up
    movss   xmm0, [rsp+8]
    mulss   xmm0, [rsp+4]
    mulss   xmm0, xmm3
    movss   xmm1, [rsp]
    mulss   xmm1, xmm4
    subss   xmm1, xmm0                  # x
    movss   xmm0, [rsp+12]
    mulss   xmm0, xmm3
    xorps   xmm2, xmm2
    subss   xmm2, xmm0
    addss   xmm2, xmm5
    movss   xmm0, xmm2                  # y
    movss   xmm2, [rsp+8]
    mulss   xmm2, [rsp]
    mulss   xmm2, xmm3
    movss   xmm6, [rsp+4]
    mulss   xmm6, xmm4
    addss   xmm2, xmm6
    xorps   xmm6, xmm6
    subss   xmm6, xmm2
    movss   xmm2, xmm6                  # z
8:  unpcklps xmm1, xmm0                 # x y
    movlhps xmm1, xmm2                  # x y z ?
    andps   xmm1, [rip+f_xyz]
    movaps  xmm0, xmm1                  # (normalized, times the speed)
    dpps    xmm0, xmm0, 0x7f
    comiss  xmm0, [rip+f_tiny]
    jbe     9f
    sqrtps  xmm0, xmm0
    divps   xmm1, xmm0
    shufps  xmm7, xmm7, 0
    mulps   xmm1, xmm7
9:  movaps  xmm0, xmm1
    add     rsp, 24
    ret

# pl_step - one fixed step
pl_step:
    push    rbx
    sub     rsp, 48
    call    pl_wish
    cmp     dword ptr [rip+pl_mode], 2
    jne     1f
    movaps  [rip+pl_vel], xmm0          # fly: as asked, no collisions
    mulps   xmm0, [rip+pl_dt4]
    addps   xmm0, [rip+pl_pos]
    movaps  [rip+pl_pos], xmm0
    jmp     9f
1:  movaps  [rsp], xmm0
    call    pl_ride                     # (on something that moved: along)
    movaps  xmm0, [rsp]
    movaps  xmm1, [rip+pl_vel]          # walk: horizontal as asked, the
    insertps xmm0, xmm1, 0x50           #  vertical by gravity
    movaps  [rip+pl_vel], xmm0
    cmp     dword ptr [rip+pl_ground], 0
    je      2f
    test    dword ptr [rip+pl_keys], IN_UP
    jz      2f
    movss   xmm1, [rip+pl_jump]         # jump
    insertps xmm0, xmm1, 0x10
    movaps  [rip+pl_vel], xmm0
    mov     dword ptr [rip+pl_ground], 0
2:  call    rb_gravity                  # (rax: the world's gravity)
    movaps  xmm1, [rax]
    mulps   xmm1, [rip+pl_dt4]
    addps   xmm1, [rip+pl_vel]
    movaps  [rip+pl_vel], xmm1
    mov     eax, [rip+pl_ground]
    mov     [rsp+32], eax               # on the ground before?
    movaps  xmm0, [rip+pl_pos]
    movaps  [rsp], xmm0                 # where it was
    movaps  xmm0, [rip+pl_vel]          # the move
    mulps   xmm0, [rip+pl_dt4]
    addps   xmm0, [rip+pl_pos]
    movaps  [rip+pl_pos], xmm0
    call    pl_resolve
    cmp     dword ptr [rsp+32], 0       # blocked on the ground: a step?
    je      5f
    cmp     dword ptr [rip+pl_wall], 0
    je      5f
    call    pl_try_step
5:  cmp     dword ptr [rsp+32], 0       # walked off down a slope: kept on it
    je      6f
    cmp     dword ptr [rip+pl_ground], 0
    jne     6f
    movss   xmm0, [rip+pl_vel+4]
    comiss  xmm0, [rip+f_zero]
    ja      6f
    call    pl_snap_down
6:  call    pl_ride_mark                # what it stands on now, and where
    movss   xmm0, [rip+pl_pos+4]        # fell out of the world: back
    comiss  xmm0, [rip+f_fall]
    jae     9f
    movaps  xmm0, [rip+pl_start]
    movaps  [rip+pl_pos], xmm0
    xorps   xmm0, xmm0
    movaps  [rip+pl_vel], xmm0
9:  add     rsp, 48
    pop     rbx
    ret

# pl_ride - standing on an object that moved since the last step (a moving
#   platform): the player moves with it
pl_ride:
    sub     rsp, 8
    cmp     dword ptr [rip+pl_ground], 0
    je      9f
    mov     edi, [rip+pl_gobj]
    test    edi, edi
    jz      9f
    call    obj_get
    test    rax, rax
    jz      9f
    movups  xmm0, [rax+OB_LOC]
    movsd   xmm1, [rip+pl_gloc]
    insertps xmm1, [rip+pl_gloc+8], 0x20
    subps   xmm0, xmm1
    andps   xmm0, [rip+f_xyz]
    addps   xmm0, [rip+pl_pos]
    movaps  [rip+pl_pos], xmm0
9:  add     rsp, 8
    ret

# pl_ride_mark - after the step: the object stood on and its place
pl_ride_mark:
    sub     rsp, 8
    mov     dword ptr [rip+pl_gobj], 0
    cmp     dword ptr [rip+pl_ground], 0
    je      9f
    mov     edi, [rip+pl_gground]
    mov     [rip+pl_gobj], edi
    call    obj_get
    test    rax, rax
    jz      8f
    mov     rcx, [rax+OB_LOC]
    mov     [rip+pl_gloc], rcx
    mov     ecx, [rax+OB_LOC+8]
    mov     [rip+pl_gloc+8], ecx
    jmp     9f
8:  mov     dword ptr [rip+pl_gobj], 0
9:  add     rsp, 8
    ret

# pl_resolve - up to five times: the deepest contact left; pl_ground,
#   pl_wall. Ground (facing up within 50 degrees): out straight up, no
#   falling into it. A ceiling: out along it, no rising into it. A wall or a
#   steep slope: out sideways only, the velocity into it taken away
#   sideways (nothing climbs it; gravity slides down it)
pl_resolve:
    push    rbx
    sub     rsp, 16
    mov     dword ptr [rip+pl_ground], 0
    mov     dword ptr [rip+pl_wall], 0
    xor     ebx, ebx
1:  cmp     ebx, 5
    jae     9f
    call    pl_contact                  # pl_best_d, pl_best_n
    movss   xmm0, [rip+pl_best_d]
    comiss  xmm0, [rip+f_zero]
    jbe     9f
    mov     edi, [rip+pl_best_obj]      # (logic: the player touched it)
    call    lg_touch
    movss   xmm0, [rip+pl_best_d]
    addss   xmm0, [rip+f_skin]
    movaps  xmm1, [rip+pl_best_n]
    movaps  xmm2, xmm1
    shufps  xmm2, xmm2, 0x55            # n.y
    comiss  xmm2, [rip+pl_ground_cos]
    jb      2f
    divss   xmm0, xmm2                  # ground: straight up
    xorps   xmm3, xmm3
    insertps xmm3, xmm0, 0x10
    addps   xmm3, [rip+pl_pos]
    movaps  [rip+pl_pos], xmm3
    mov     dword ptr [rip+pl_ground], 1
    mov     eax, [rip+pl_best_obj]      # (what it stands on)
    mov     [rip+pl_gground], eax
    movss   xmm3, [rip+pl_vel+4]
    comiss  xmm3, [rip+f_zero]
    jae     8f
    mov     dword ptr [rip+pl_vel+4], 0
    jmp     8f
2:  comiss  xmm2, [rip+f_ceil]
    ja      3f
    shufps  xmm0, xmm0, 0               # a ceiling: along it
    mulps   xmm0, xmm1
    addps   xmm0, [rip+pl_pos]
    movaps  [rip+pl_pos], xmm0
    movss   xmm3, [rip+pl_vel+4]
    comiss  xmm3, [rip+f_zero]
    jbe     8f
    mov     dword ptr [rip+pl_vel+4], 0
    jmp     8f
3:  mov     dword ptr [rip+pl_wall], 1  # a wall: sideways
    insertps xmm1, xmm1, 0x0a           # (n.x, 0, n.z)
    movaps  xmm3, xmm1
    dpps    xmm3, xmm3, 0x7f
    sqrtps  xmm3, xmm3
    movaps  xmm4, xmm3
    maxss   xmm4, [rip+f_minh]
    divss   xmm0, xmm4                  # (the depth, sideways)
    maxps   xmm3, [rip+f_tiny4]
    divps   xmm1, xmm3                  # n_h, unit
    movaps  xmm4, xmm1
    shufps  xmm0, xmm0, 0
    mulps   xmm4, xmm0
    addps   xmm4, [rip+pl_pos]
    movaps  [rip+pl_pos], xmm4
    movaps  xmm3, [rip+pl_vel]          # the velocity into it, sideways
    movaps  xmm4, xmm3
    dpps    xmm4, xmm1, 0x7f
    comiss  xmm4, [rip+f_zero]
    jae     8f
    mulps   xmm4, xmm1
    subps   xmm3, xmm4
    movaps  [rip+pl_vel], xmm3
8:  inc     ebx
    jmp     1b
9:  add     rsp, 16
    pop     rbx
    ret

# pl_try_step - (blocked) the step again from 0.4 m higher, then down onto
#   what is there: kept when it lands on ground
pl_try_step:
    push    rbx
    sub     rsp, 64
    movaps  xmm0, [rip+pl_pos]          # as it is now (the fallback)
    movaps  [rsp], xmm0
    movaps  xmm0, [rip+pl_vel]
    movaps  [rsp+16], xmm0
    call    pl_wish                     # the move asked for, flat: at
    insertps xmm0, xmm0, 0x0a           #  least the radius on (the round
    andps   xmm0, [rip+f_xyz]           #  bottom past the step's edge)
    movaps  xmm2, xmm0
    dpps    xmm2, xmm2, 0x7f
    comiss  xmm2, [rip+f_tiny]
    jbe     8f
    sqrtps  xmm2, xmm2
    divps   xmm0, xmm2
    movss   xmm2, [rip+pl_radius]
    mulss   xmm2, [rip+f_stepk]
    shufps  xmm2, xmm2, 0
    mulps   xmm0, xmm2
    movaps  xmm2, xmm0
    xorps   xmm1, xmm1
    insertps xmm1, [rip+pl_step_h], 0x10
    movaps  xmm3, [rsp]
    addps   xmm3, xmm1                  # up
    addps   xmm3, xmm2                  # and on
    movaps  [rip+pl_pos], xmm3
    movaps  [rsp+32], xmm1
    call    pl_resolve
    cmp     dword ptr [rip+pl_wall], 0  # still a wall up there: too tall
    jne     8f
    movaps  xmm0, [rip+pl_pos]          # down again
    subps   xmm0, [rsp+32]
    movaps  [rip+pl_pos], xmm0
    call    pl_resolve
    cmp     dword ptr [rip+pl_ground], 0
    je      8f
    cmp     dword ptr [rip+pl_wall], 0
    jne     8f
    movss   xmm0, [rip+pl_pos+4]        # higher than before: a step taken -
    subss   xmm0, [rsp+4]               #  up onto it where it stands (the
    comiss  xmm0, [rip+f_rise]          #  walk takes it on from there)
    jbe     8f
    movss   xmm0, [rip+pl_pos+4]
    movaps  xmm1, [rsp]
    insertps xmm1, xmm0, 0x10
    movaps  [rip+pl_pos], xmm1
    movaps  xmm0, [rsp+16]
    movaps  [rip+pl_vel], xmm0
    mov     dword ptr [rip+pl_vel+4], 0
    mov     dword ptr [rip+pl_ground], 1
    jmp     9f
8:  movaps  xmm0, [rsp]                 # no: as it was
    movaps  [rip+pl_pos], xmm0
    movaps  xmm0, [rsp+16]
    movaps  [rip+pl_vel], xmm0
    mov     dword ptr [rip+pl_ground], 1
9:  add     rsp, 64
    pop     rbx
    ret

# pl_snap_down - (just left the ground, not jumping) down up to 0.25 m onto
#   ground below, else as it was
pl_snap_down:
    sub     rsp, 24
    movaps  xmm0, [rip+pl_pos]
    movaps  [rsp], xmm0
    xorps   xmm1, xmm1
    insertps xmm1, [rip+f_snap], 0x10
    subps   xmm0, xmm1
    movaps  [rip+pl_pos], xmm0
    call    pl_resolve
    cmp     dword ptr [rip+pl_ground], 0
    jne     9f
    movaps  xmm0, [rsp]
    movaps  [rip+pl_pos], xmm0
9:  add     rsp, 24
    ret

# =============================================================================
#  Contacts: the capsule against every mesh's triangles
# =============================================================================
# pl_contact - pl_best_d / pl_best_n: the deepest the capsule at pl_pos goes
#   into a triangle (0: none)
pl_contact:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 56
    mov     dword ptr [rip+pl_best_d], 0
    movaps  xmm0, [rip+pl_pos]          # the capsule's box
    movss   xmm1, [rip+pl_radius]
    shufps  xmm1, xmm1, 0
    movaps  xmm2, xmm0
    subps   xmm2, xmm1
    andps   xmm2, [rip+f_xyz]
    movaps  [rip+pl_box0], xmm2
    addps   xmm0, xmm1
    movss   xmm3, [rip+pl_height]
    subss   xmm3, [rip+pl_radius]
    xorps   xmm4, xmm4
    insertps xmm4, xmm3, 0x10
    addps   xmm0, xmm4
    andps   xmm0, [rip+f_xyz]
    movaps  [rip+pl_box1], xmm0
    xor     ebx, ebx
.Lco_obj:
    cmp     ebx, [rip+obj_count]
    jae     .Lco_out
    mov     edi, ebx
    call    obj_at
    mov     r12, rax
    lea     rax, [rip+obj_list]
    mov     eax, [rax+rbx*4]
    mov     [rip+pl_cur_obj], eax
    cmp     dword ptr [r12+OB_TYPE], OT_MESH
    jne     .Lco_next
    test    dword ptr [r12+OB_FLAGS], OBF_HIDDEN|OBF_WATER   # (water: not
    jnz     .Lco_next                                       #  walked on)
    mov     rdi, r12
    call    obj_eval
    test    rax, rax
    jz      .Lco_next
    mov     r13, rax
    cmp     dword ptr [r13+ME_NTRIS], 0
    je      .Lco_next
    mov     rdi, r12
    lea     rsi, [rip+pl_mat]
    call    obj_matrix
    call    pl_invert
    test    eax, eax
    jz      .Lco_next
    call    box_local                   # the box in its space: [rsp] .. [rsp+16]
    movaps  [rsp], xmm0
    movaps  [rsp+16], xmm1
    movups  xmm2, [r13+ME_BMIN]         # disjoint from its mesh's box: skip
    andps   xmm2, [rip+f_xyz]
    movups  xmm3, [r13+ME_BMAX]
    andps   xmm3, [rip+f_xyz]
    cmpltps xmm3, xmm0                  # max < q0 or q1 < min
    cmpltps xmm1, xmm2
    orps    xmm3, xmm1
    andps   xmm3, [rip+f_xyz]
    movmskps eax, xmm3
    test    eax, eax
    jnz     .Lco_next
    mov     rdi, r13
    call    pl_grid
    test    rax, rax
    jz      .Lco_next
    mov     r14, rax                    # its grid
    inc     dword ptr [rip+pl_stamp]
    mov     rdi, r14                    # cells overlapping the box
    movaps  xmm0, [rsp]
    call    cell_of_pt
    mov     [rsp+32], eax
    mov     [rsp+36], edx
    mov     [rsp+40], ecx
    movaps  xmm0, [rsp+16]
    mov     rdi, r14
    call    cell_of_pt
    mov     [rsp+44], eax
    mov     [rsp+48], edx
    mov     [rsp+52], ecx
    mov     r15d, [rsp+40]              # z
.Lco_z:
    cmp     r15d, [rsp+52]
    jg      .Lco_next
    mov     ebp, [rsp+36]               # y
.Lco_y:
    cmp     ebp, [rsp+48]
    jg      .Lco_znext
    mov     ecx, [rsp+32]               # x
.Lco_x:
    cmp     ecx, [rsp+44]
    jg      .Lco_ynext
    push    rcx
    sub     rsp, 8
    movzx   eax, word ptr [r14+PC_N+2]  # the cell
    imul    eax, r15d
    add     eax, ebp
    movzx   edx, word ptr [r14+PC_N]
    imul    eax, edx
    add     eax, ecx
    mov     rdx, [r14+PC_OFF]
    mov     r8d, [rdx+rax*4]
    mov     r9d, [rdx+rax*4+4]
.Lco_t:
    cmp     r8d, r9d
    jae     .Lco_tdone
    mov     rdx, [r14+PC_ENT]
    mov     eax, [rdx+r8*4]             # a triangle (once a query)
    mov     rdx, [r14+PC_STAMP]
    mov     r10d, [rip+pl_stamp]
    cmp     [rdx+rax*4], r10d
    je      .Lco_tnext
    mov     [rdx+rax*4], r10d
    push    r8
    push    r9
    mov     rdi, r13
    mov     esi, eax
    call    tri_world                   # pl_tri
    call    cap_tri                     # deeper than the best: kept
    pop     r9
    pop     r8
.Lco_tnext:
    inc     r8d
    jmp     .Lco_t
.Lco_tdone:
    add     rsp, 8
    pop     rcx
    inc     ecx
    jmp     .Lco_x
.Lco_ynext:
    inc     ebp
    jmp     .Lco_y
.Lco_znext:
    inc     r15d
    jmp     .Lco_z
.Lco_next:
    inc     ebx
    jmp     .Lco_obj
.Lco_out:
    add     rsp, 56
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# pl_invert -> eax = 1: pl_inv = the inverse of pl_mat (0: singular)
pl_invert:
    lea     rsi, [rip+pl_mat]
    lea     rdi, [rip+pl_inv]
    # cofactors of the 3x3 part (rows of 16 bytes: m0 m1 m2 t)
    movss   xmm0, [rsi+20]              # c00 = m11 m22 - m12 m21
    mulss   xmm0, [rsi+40]
    movss   xmm1, [rsi+24]
    mulss   xmm1, [rsi+36]
    subss   xmm0, xmm1
    movss   xmm2, [rsi+24]              # c01 = m12 m20 - m10 m22
    mulss   xmm2, [rsi+32]
    movss   xmm1, [rsi+16]
    mulss   xmm1, [rsi+40]
    subss   xmm2, xmm1
    movss   xmm3, [rsi+16]              # c02 = m10 m21 - m11 m20
    mulss   xmm3, [rsi+36]
    movss   xmm1, [rsi+20]
    mulss   xmm1, [rsi+32]
    subss   xmm3, xmm1
    movss   xmm4, [rsi]                 # det = m00 c00 + m01 c01 + m02 c02
    mulss   xmm4, xmm0
    movss   xmm1, [rsi+4]
    mulss   xmm1, xmm2
    addss   xmm4, xmm1
    movss   xmm1, [rsi+8]
    mulss   xmm1, xmm3
    addss   xmm4, xmm1
    movaps  xmm5, xmm4
    andps   xmm5, [rip+f_abs]
    comiss  xmm5, [rip+f_eps]
    jbe     8f
    movss   xmm5, [rip+f_one]
    divss   xmm5, xmm4                  # 1 / det
    # inverse = adjugate / det: inv[r][c] = cof[c][r]
    mulss   xmm0, xmm5
    movss   [rdi], xmm0                 # inv00 = c00
    mulss   xmm2, xmm5
    movss   [rdi+16], xmm2              # inv10 = c01
    mulss   xmm3, xmm5
    movss   [rdi+32], xmm3              # inv20 = c02
    movss   xmm0, [rsi+8]               # c10 = m02 m21 - m01 m22 -> inv01
    mulss   xmm0, [rsi+36]
    movss   xmm1, [rsi+4]
    mulss   xmm1, [rsi+40]
    subss   xmm0, xmm1
    mulss   xmm0, xmm5
    movss   [rdi+4], xmm0
    movss   xmm0, [rsi]                 # c11 = m00 m22 - m02 m20 -> inv11
    mulss   xmm0, [rsi+40]
    movss   xmm1, [rsi+8]
    mulss   xmm1, [rsi+32]
    subss   xmm0, xmm1
    mulss   xmm0, xmm5
    movss   [rdi+20], xmm0
    movss   xmm0, [rsi+4]               # c12 = m01 m20 - m00 m21 -> inv21
    mulss   xmm0, [rsi+32]
    movss   xmm1, [rsi]
    mulss   xmm1, [rsi+36]
    subss   xmm0, xmm1
    mulss   xmm0, xmm5
    movss   [rdi+36], xmm0
    movss   xmm0, [rsi+4]               # c20 = m01 m12 - m02 m11 -> inv02
    mulss   xmm0, [rsi+24]
    movss   xmm1, [rsi+8]
    mulss   xmm1, [rsi+20]
    subss   xmm0, xmm1
    mulss   xmm0, xmm5
    movss   [rdi+8], xmm0
    movss   xmm0, [rsi+8]               # c21 = m02 m10 - m00 m12 -> inv12
    mulss   xmm0, [rsi+16]
    movss   xmm1, [rsi]
    mulss   xmm1, [rsi+24]
    subss   xmm0, xmm1
    mulss   xmm0, xmm5
    movss   [rdi+24], xmm0
    movss   xmm0, [rsi]                 # c22 = m00 m11 - m01 m10 -> inv22
    mulss   xmm0, [rsi+20]
    movss   xmm1, [rsi+4]
    mulss   xmm1, [rsi+16]
    subss   xmm0, xmm1
    mulss   xmm0, xmm5
    movss   [rdi+40], xmm0
    xor     ecx, ecx                    # translation: -inv x t
1:  imul    eax, ecx, 16
    movss   xmm0, [rdi+rax]
    mulss   xmm0, [rsi+12]
    movss   xmm1, [rdi+rax+4]
    mulss   xmm1, [rsi+28]
    addss   xmm0, xmm1
    movss   xmm1, [rdi+rax+8]
    mulss   xmm1, [rsi+44]
    addss   xmm0, xmm1
    xorps   xmm1, xmm1
    subss   xmm1, xmm0
    movss   [rdi+rax+12], xmm1
    inc     ecx
    cmp     ecx, 3
    jb      1b
    mov     eax, 1
    ret
8:  xor     eax, eax
    ret

# xform(rsi=3 x 4 matrix, xmm0=point) -> xmm0 = the point moved (xmm1, xmm2
#   clobbered)
xform:
    insertps xmm0, [rip+f_one], 0x30
    movaps  xmm1, xmm0
    dpps    xmm1, [rsi], 0xf1
    movaps  xmm2, xmm0
    dpps    xmm2, [rsi+16], 0xf2
    orps    xmm1, xmm2
    movaps  xmm2, xmm0
    dpps    xmm2, [rsi+32], 0xf4
    orps    xmm1, xmm2
    movaps  xmm0, xmm1
    ret

# box_local -> xmm0, xmm1 = the query box's corners taken into pl_inv's space
box_local:
    push    rbx
    sub     rsp, 48
    movaps  xmm0, [rip+f_bigv]
    movaps  [rsp], xmm0
    movaps  xmm0, [rip+f_nbigv]
    movaps  [rsp+16], xmm0
    xor     ebx, ebx
1:  cmp     ebx, 8
    jae     2f
    movaps  xmm0, [rip+pl_box0]         # corner bits: x y z
    movaps  xmm3, [rip+pl_box1]
    test    ebx, 1
    jz      11f
    insertps xmm0, xmm3, 0x00
11: test    ebx, 2
    jz      12f
    insertps xmm0, xmm3, 0x50
12: test    ebx, 4
    jz      13f
    insertps xmm0, xmm3, 0xa0
13: lea     rsi, [rip+pl_inv]
    call    xform
    movaps  xmm1, [rsp]
    minps   xmm1, xmm0
    movaps  [rsp], xmm1
    movaps  xmm1, [rsp+16]
    maxps   xmm1, xmm0
    movaps  [rsp+16], xmm1
    inc     ebx
    jmp     1b
2:  movaps  xmm0, [rsp]
    movaps  xmm1, [rsp+16]
    add     rsp, 48
    pop     rbx
    ret

# tri_world(rdi=mesh, esi=triangle) - pl_tri = its corners in world space
tri_world:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    lea     rax, [rsi+rsi*2]
    shl     rax, 2
    add     rax, [rbx+ME_TRIS]
    mov     r12, rax
    xor     ecx, ecx
1:  cmp     ecx, 3
    jae     9f
    push    rcx
    sub     rsp, 8
    mov     eax, [r12+rcx*4]
    lea     rax, [rax+rax*2]
    shl     rax, 2
    add     rax, [rbx+ME_POS]
    movsd   xmm0, [rax]
    insertps xmm0, [rax+8], 0x20
    lea     rsi, [rip+pl_mat]
    call    xform
    add     rsp, 8
    pop     rcx
    imul    eax, ecx, 16
    lea     rdx, [rip+pl_tri]
    movaps  [rdx+rax], xmm0
    inc     ecx
    jmp     1b
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# cap_tri - the capsule (pl_pos) against pl_tri: the closest points between
#   its axis and the triangle; deeper than pl_best_d: kept
.equ CT_A,      0                       # the axis: bottom, top sphere centres
.equ CT_B,      16
.equ CT_D2,     32                      # the closest distance squared so far
.equ CT_N,      48                      # the face normal, towards the capsule
.equ CT_X,      64
.equ CT_E,      80                      # (an edge's index)
cap_tri:
    sub     rsp, 104
    movaps  xmm0, [rip+pl_pos]
    xorps   xmm2, xmm2
    insertps xmm2, [rip+pl_radius], 0x10
    addps   xmm0, xmm2
    movaps  [rsp+CT_A], xmm0
    movss   xmm1, [rip+pl_height]
    subss   xmm1, [rip+pl_radius]
    subss   xmm1, [rip+pl_radius]
    xorps   xmm2, xmm2
    insertps xmm2, xmm1, 0x10
    addps   xmm0, xmm2
    movaps  [rsp+CT_B], xmm0
    mov     eax, [rip+f_big]
    mov     [rsp+CT_D2], eax
    lea     rcx, [rip+pl_tri]           # the face normal, to the capsule's side
    movaps  xmm4, [rcx+16]
    subps   xmm4, [rcx]
    movaps  xmm5, [rcx+32]
    subps   xmm5, [rcx]
    call    cross45
    movaps  xmm1, xmm6
    dpps    xmm1, xmm1, 0x7f
    comiss  xmm1, [rip+f_eps]
    jbe     .Lct_out                    # (no area)
    sqrtps  xmm1, xmm1
    divps   xmm6, xmm1
    movaps  xmm0, [rsp+CT_A]
    addps   xmm0, [rsp+CT_B]
    mulps   xmm0, [rip+f_half4]
    lea     rcx, [rip+pl_tri]
    subps   xmm0, [rcx]
    dpps    xmm0, xmm6, 0x71
    comiss  xmm0, [rip+f_zero]
    jae     1f
    xorps   xmm6, [rip+f_sign4]
1:  movaps  [rsp+CT_N], xmm6
    # the axis' ends against the triangle
    movaps  xmm0, [rsp+CT_A]
    call    pt_tri
    movaps  xmm1, [rsp+CT_A]
    call    keep_pair
    movaps  xmm0, [rsp+CT_B]
    call    pt_tri
    movaps  xmm1, [rsp+CT_B]
    call    keep_pair
    # the axis against the edges
    mov     dword ptr [rsp+CT_E], 0
2:  mov     eax, [rsp+CT_E]
    cmp     eax, 3
    jae     3f
    lea     rcx, [rip+pl_tri]
    imul    edx, eax, 16
    movaps  xmm2, [rcx+rdx]
    inc     eax
    cmp     eax, 3
    jb      21f
    xor     eax, eax
21: imul    edx, eax, 16
    movaps  xmm3, [rcx+rdx]
    movaps  xmm0, [rsp+CT_A]
    movaps  xmm1, [rsp+CT_B]
    call    seg_seg                     # xmm0 on the axis, xmm1 on the edge
    movaps  xmm4, xmm0
    movaps  xmm0, xmm1
    movaps  xmm1, xmm4
    call    keep_pair
    inc     dword ptr [rsp+CT_E]
    jmp     2b
3:  # the axis through the face: out along the normal, past its end behind
    lea     rcx, [rip+pl_tri]
    movaps  xmm0, [rsp+CT_A]
    subps   xmm0, [rcx]
    dpps    xmm0, [rsp+CT_N], 0x71      # da (signed, + on the capsule's side)
    movaps  xmm1, [rsp+CT_B]
    subps   xmm1, [rcx]
    dpps    xmm1, [rsp+CT_N], 0x71      # db
    movaps  xmm2, xmm0
    mulss   xmm2, xmm1
    comiss  xmm2, [rip+f_zero]
    jae     5f
    movaps  xmm2, xmm0                  # where it crosses
    subss   xmm2, xmm1
    movaps  xmm3, xmm0
    divss   xmm3, xmm2
    shufps  xmm3, xmm3, 0
    movaps  xmm4, [rsp+CT_B]
    subps   xmm4, [rsp+CT_A]
    mulps   xmm4, xmm3
    addps   xmm4, [rsp+CT_A]
    movaps  [rsp+CT_X], xmm4
    movss   [rsp+CT_E], xmm0            # (da, db kept)
    movss   [rsp+CT_E+4], xmm1
    movaps  xmm0, xmm4
    call    pt_tri
    movaps  xmm1, [rsp+CT_X]
    subps   xmm1, xmm0
    dpps    xmm1, xmm1, 0x71
    comiss  xmm1, [rip+f_tiny]
    ja      5f
    movss   xmm0, [rsp+CT_E]            # inside: depth = r + the end behind
    minss   xmm0, [rsp+CT_E+4]
    xorps   xmm1, xmm1
    subss   xmm1, xmm0
    addss   xmm1, [rip+pl_radius]
    movaps  xmm0, [rsp+CT_N]
    jmp     7f
5:  movss   xmm0, [rsp+CT_D2]           # else: depth = r - the distance
    comiss  xmm0, [rip+f_big]
    jae     .Lct_out
    sqrtss  xmm0, xmm0
    movss   xmm1, [rip+pl_radius]
    subss   xmm1, xmm0
    movaps  xmm0, [rsp+CT_N]            # (touching: the face normal)
    movss   xmm2, [rsp+CT_D2]
    comiss  xmm2, [rip+f_tiny]
    jbe     7f
    movaps  xmm0, [rip+pl_pair_s]       # from the triangle to the axis
    subps   xmm0, [rip+pl_pair_t]
    andps   xmm0, [rip+f_xyz]
    movaps  xmm2, xmm0
    dpps    xmm2, xmm2, 0x7f
    sqrtps  xmm2, xmm2
    divps   xmm0, xmm2
7:  comiss  xmm1, [rip+pl_best_d]       # deeper than the deepest so far?
    jbe     .Lct_out
    movss   [rip+pl_best_d], xmm1
    movaps  [rip+pl_best_n], xmm0
    mov     eax, [rip+pl_cur_obj]       # (and whose)
    mov     [rip+pl_best_obj], eax
.Lct_out:
    add     rsp, 104
    ret
# keep_pair(xmm0=on the triangle, xmm1=on the axis) - (cap_tri's frame, one
#   level up) the closest so far
keep_pair:
    movaps  xmm2, xmm1
    subps   xmm2, xmm0
    dpps    xmm2, xmm2, 0x71
    comiss  xmm2, [rsp+8+CT_D2]
    jae     9f
    movss   [rsp+8+CT_D2], xmm2
    movaps  [rip+pl_pair_t], xmm0
    movaps  [rip+pl_pair_s], xmm1
9:  ret

# cross45(xmm4=a, xmm5=b) -> xmm6 = a x b (xmm7 clobbered)
cross45:
    movaps  xmm6, xmm4
    shufps  xmm6, xmm6, 0xc9            # a.yzx
    movaps  xmm7, xmm5
    shufps  xmm7, xmm7, 0xd2            # b.zxy
    mulps   xmm6, xmm7
    movaps  xmm7, xmm4
    shufps  xmm7, xmm7, 0xd2            # a.zxy
    movaps  xmm8, xmm5
    shufps  xmm8, xmm8, 0xc9            # b.yzx
    mulps   xmm7, xmm8
    subps   xmm6, xmm7
    andps   xmm6, [rip+f_xyz]
    ret

# pt_tri(xmm0=p) -> xmm0 = the point of pl_tri closest to it (Ericson)
pt_tri:
    lea     rcx, [rip+pl_tri]
    movaps  xmm1, [rcx]                 # a
    movaps  xmm2, [rcx+16]              # b
    movaps  xmm3, [rcx+32]              # c
    movaps  xmm4, xmm2
    subps   xmm4, xmm1                  # ab
    movaps  xmm5, xmm3
    subps   xmm5, xmm1                  # ac
    movaps  xmm6, xmm0
    subps   xmm6, xmm1                  # ap
    movaps  xmm8, xmm4
    dpps    xmm8, xmm6, 0x71            # d1
    movaps  xmm9, xmm5
    dpps    xmm9, xmm6, 0x71            # d2
    xorps   xmm15, xmm15
    comiss  xmm8, xmm15
    ja      1f
    comiss  xmm9, xmm15
    ja      1f
    movaps  xmm0, xmm1                  # a
    ret
1:  movaps  xmm6, xmm0
    subps   xmm6, xmm2                  # bp
    movaps  xmm10, xmm4
    dpps    xmm10, xmm6, 0x71           # d3
    movaps  xmm11, xmm5
    dpps    xmm11, xmm6, 0x71           # d4
    comiss  xmm10, xmm15
    jb      2f
    comiss  xmm11, xmm10
    ja      2f
    movaps  xmm0, xmm2                  # b
    ret
2:  movaps  xmm7, xmm8                  # vc = d1 d4 - d3 d2
    mulss   xmm7, xmm11
    movaps  xmm6, xmm10
    mulss   xmm6, xmm9
    subss   xmm7, xmm6
    comiss  xmm7, xmm15
    ja      3f
    comiss  xmm8, xmm15
    jb      3f
    comiss  xmm10, xmm15
    ja      3f
    movaps  xmm6, xmm8                  # v = d1 / (d1 - d3): on ab
    subss   xmm6, xmm10
    divss   xmm8, xmm6
    shufps  xmm8, xmm8, 0
    mulps   xmm4, xmm8
    addps   xmm1, xmm4
    movaps  xmm0, xmm1
    ret
3:  movaps  xmm6, xmm0
    subps   xmm6, xmm3                  # cp
    movaps  xmm12, xmm4
    dpps    xmm12, xmm6, 0x71           # d5
    movaps  xmm13, xmm5
    dpps    xmm13, xmm6, 0x71           # d6
    comiss  xmm13, xmm15
    jb      4f
    comiss  xmm12, xmm13
    ja      4f
    movaps  xmm0, xmm3                  # c
    ret
4:  movaps  xmm14, xmm12                # vb = d5 d2 - d1 d6
    mulss   xmm14, xmm9
    movaps  xmm6, xmm8
    mulss   xmm6, xmm13
    subss   xmm14, xmm6
    comiss  xmm14, xmm15
    ja      5f
    comiss  xmm9, xmm15
    jb      5f
    comiss  xmm13, xmm15
    ja      5f
    movaps  xmm6, xmm9                  # w = d2 / (d2 - d6): on ac
    subss   xmm6, xmm13
    divss   xmm9, xmm6
    shufps  xmm9, xmm9, 0
    mulps   xmm5, xmm9
    addps   xmm1, xmm5
    movaps  xmm0, xmm1
    ret
5:  movaps  xmm6, xmm10                 # va = d3 d6 - d5 d4
    mulss   xmm6, xmm13
    movaps  xmm0, xmm12
    mulss   xmm0, xmm11
    subss   xmm6, xmm0
    comiss  xmm6, xmm15
    ja      6f
    movaps  xmm0, xmm11
    subss   xmm0, xmm10                 # d4 - d3
    comiss  xmm0, xmm15
    jb      6f
    movaps  xmm8, xmm12
    subss   xmm8, xmm13                 # d5 - d6
    comiss  xmm8, xmm15
    jb      6f
    addss   xmm8, xmm0                  # w = (d4 - d3) / ((d4-d3) + (d5-d6))
    divss   xmm0, xmm8
    shufps  xmm0, xmm0, 0
    subps   xmm3, xmm2
    mulps   xmm3, xmm0
    addps   xmm2, xmm3
    movaps  xmm0, xmm2
    ret
6:  addss   xmm6, xmm14                 # inside: barycentric
    addss   xmm6, xmm7
    movss   xmm0, [rip+f_one]
    divss   xmm0, xmm6
    mulss   xmm14, xmm0                 # v
    mulss   xmm7, xmm0                  # w
    shufps  xmm14, xmm14, 0
    shufps  xmm7, xmm7, 0
    mulps   xmm4, xmm14
    mulps   xmm5, xmm7
    addps   xmm1, xmm4
    addps   xmm1, xmm5
    movaps  xmm0, xmm1
    ret

# seg_seg(xmm0=p1, xmm1=q1, xmm2=p2, xmm3=q2) -> xmm0, xmm1 = the closest
#   points on the first and the second segment (Ericson)
seg_seg:
    movaps  xmm4, xmm1
    subps   xmm4, xmm0                  # d1
    movaps  xmm5, xmm3
    subps   xmm5, xmm2                  # d2
    movaps  xmm6, xmm0
    subps   xmm6, xmm2                  # r
    movaps  xmm7, xmm4
    dpps    xmm7, xmm4, 0x71            # a
    movaps  xmm8, xmm5
    dpps    xmm8, xmm5, 0x71            # e
    movaps  xmm9, xmm5
    dpps    xmm9, xmm6, 0x71            # f
    xorps   xmm15, xmm15
    movss   xmm14, [rip+f_one]
    comiss  xmm7, [rip+f_eps]
    ja      2f
    xorps   xmm10, xmm10                # s = 0, t = clamp(f / e)
    movaps  xmm11, xmm9
    comiss  xmm8, [rip+f_eps]
    jbe     11f
    divss   xmm11, xmm8
    maxss   xmm11, xmm15
    minss   xmm11, xmm14
    jmp     8f
11: xorps   xmm11, xmm11
    jmp     8f
2:  movaps  xmm12, xmm4
    dpps    xmm12, xmm6, 0x71           # c
    comiss  xmm8, [rip+f_eps]
    ja      3f
    xorps   xmm11, xmm11                # t = 0, s = clamp(-c / a)
    xorps   xmm10, xmm10
    subss   xmm10, xmm12
    divss   xmm10, xmm7
    maxss   xmm10, xmm15
    minss   xmm10, xmm14
    jmp     8f
3:  movaps  xmm13, xmm4
    dpps    xmm13, xmm5, 0x71           # b
    movaps  xmm0, xmm7                  # denom = a e - b b
    mulss   xmm0, xmm8
    movaps  xmm1, xmm13
    mulss   xmm1, xmm13
    subss   xmm0, xmm1
    xorps   xmm10, xmm10
    comiss  xmm0, [rip+f_eps]
    jbe     4f
    movaps  xmm10, xmm13                # s = clamp((b f - c e) / denom)
    mulss   xmm10, xmm9
    movaps  xmm1, xmm12
    mulss   xmm1, xmm8
    subss   xmm10, xmm1
    divss   xmm10, xmm0
    maxss   xmm10, xmm15
    minss   xmm10, xmm14
4:  movaps  xmm11, xmm13                # t = (b s + f) / e
    mulss   xmm11, xmm10
    addss   xmm11, xmm9
    divss   xmm11, xmm8
    comiss  xmm11, xmm15
    jae     5f
    xorps   xmm11, xmm11                # t < 0: s = clamp(-c / a)
    xorps   xmm10, xmm10
    subss   xmm10, xmm12
    divss   xmm10, xmm7
    maxss   xmm10, xmm15
    minss   xmm10, xmm14
    jmp     8f
5:  comiss  xmm11, xmm14
    jbe     8f
    movss   xmm11, xmm14                # t > 1: s = clamp((b - c) / a)
    movaps  xmm10, xmm13
    subss   xmm10, xmm12
    divss   xmm10, xmm7
    maxss   xmm10, xmm15
    minss   xmm10, xmm14
8:  movaps  xmm0, xmm6                  # (p1 = r + p2)
    addps   xmm0, xmm2
    shufps  xmm10, xmm10, 0
    mulps   xmm4, xmm10
    addps   xmm0, xmm4                  # c1 = p1 + d1 s
    shufps  xmm11, xmm11, 0
    mulps   xmm5, xmm11
    movaps  xmm1, xmm2
    addps   xmm1, xmm5                  # c2 = p2 + d2 t
    ret

# =============================================================================
#  A mesh's grid of triangles (its own space)
# =============================================================================
# pl_grid(rdi=mesh) -> rax = its grid (made the first time; 0: no room)
pl_grid:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 56
    mov     rbx, rdi
    lea     r12, [rip+pl_tab]
    mov     ecx, [rip+pl_ntab]
1:  test    ecx, ecx
    jz      2f
    cmp     [r12+PC_MESH], rbx
    jne     11f
    mov     eax, [rbx+ME_VER]
    cmp     [r12+PC_VER], eax
    je      .Lpg_have
11: add     r12, PC_SZ
    dec     ecx
    jmp     1b
2:  cmp     dword ptr [rip+pl_ntab], PC_MAX
    jae     .Lpg_none
    inc     dword ptr [rip+pl_ntab]
    mov     [r12+PC_MESH], rbx
    mov     eax, [rbx+ME_VER]
    mov     [r12+PC_VER], eax
    # cells: about the cube root of the triangles a side, along the longest
    mov     eax, [rbx+ME_NTRIS]
    cvtsi2ss xmm0, eax
    mov     [rsp], eax
    movss   [rsp+4], xmm0
    fld     dword ptr [rsp+4]           # cbrt via log2 / exp2
    fld1
    fxch
    fyl2x
    fdiv    dword ptr [rip+f_three]
    fld     st(0)
    frndint
    fsub    st(1), st(0)
    fxch
    f2xm1
    fld1
    faddp
    fscale
    fstp    st(1)
    fstp    dword ptr [rsp+4]
    movss   xmm0, [rsp+4]
    maxss   xmm0, [rip+f_one]
    minss   xmm0, [rip+f_gcap]
    movups  xmm1, [rbx+ME_BMAX]
    movups  xmm2, [rbx+ME_BMIN]
    subps   xmm1, xmm2
    andps   xmm1, [rip+f_xyz]
    maxps   xmm1, [rip+f_tiny4]
    movaps  xmm2, xmm1                  # the longest side / that = the cell
    shufps  xmm2, xmm2, 0x55
    maxss   xmm2, xmm1
    movaps  xmm3, xmm1
    shufps  xmm3, xmm3, 0xaa
    maxss   xmm2, xmm3
    divss   xmm2, xmm0
    movss   [r12+PC_CELL], xmm2            # (PC_N + 4: the cell size)
    shufps  xmm2, xmm2, 0
    divps   xmm1, xmm2
    cvttps2dq xmm1, xmm1
    mov     ecx, 3
    xor     edx, edx
3:  movd    eax, xmm1
    inc     eax
    cmp     eax, PG_CAP
    jbe     31f
    mov     eax, PG_CAP
31: mov     [r12+PC_N+rdx*2], ax
    psrldq  xmm1, 4
    inc     edx
    dec     ecx
    jnz     3b
    movzx   eax, word ptr [r12+PC_N]
    movzx   ecx, word ptr [r12+PC_N+2]
    imul    eax, ecx
    movzx   ecx, word ptr [r12+PC_N+4]
    imul    eax, ecx
    mov     [rsp+8], eax                # cells
    # count, then fill (a triangle in every cell its box touches)
    lea     edi, [rax+1]                # counts (become offsets)
    shl     rdi, 2
    call    pl_alloc
    test    rax, rax
    jz      .Lpg_fail
    mov     [r12+PC_OFF], rax
    mov     dword ptr [rsp+12], 0       # pass: 0 count, 1 fill
.Lpg_pass:
    xor     r13d, r13d                  # triangle
.Lpg_tri:
    cmp     r13d, [rbx+ME_NTRIS]
    jae     .Lpg_passdone
    mov     rdi, rbx
    mov     esi, r13d
    lea     rdx, [rsp+16]
    call    tri_cells                   # [rsp+16..40): x0 y0 z0 x1 y1 z1
    mov     r15d, [rsp+24]
4:  cmp     r15d, [rsp+36]
    jg      .Lpg_tnext
    mov     ebp, [rsp+20]
5:  cmp     ebp, [rsp+32]
    jg      45f
    mov     r14d, [rsp+16]
6:  cmp     r14d, [rsp+28]
    jg      56f
    movzx   eax, word ptr [r12+PC_N+2]
    imul    eax, r15d
    add     eax, ebp
    movzx   ecx, word ptr [r12+PC_N]
    imul    eax, ecx
    add     eax, r14d
    mov     rcx, [r12+PC_OFF]
    cmp     dword ptr [rsp+12], 0
    jne     61f
    inc     dword ptr [rcx+rax*4]
    jmp     62f
61: mov     edx, [rcx+rax*4]            # (the cursor)
    inc     dword ptr [rcx+rax*4]
    mov     rcx, [r12+PC_ENT]
    mov     [rcx+rdx*4], r13d
62: inc     r14d
    jmp     6b
56: inc     ebp
    jmp     5b
45: inc     r15d
    jmp     4b
.Lpg_tnext:
    inc     r13d
    jmp     .Lpg_tri
.Lpg_passdone:
    cmp     dword ptr [rsp+12], 0
    jne     .Lpg_done
    mov     rcx, [r12+PC_OFF]           # counts -> first entries (exclusive)
    xor     eax, eax
    xor     edx, edx
7:  cmp     edx, [rsp+8]
    ja      71f
    mov     esi, [rcx+rdx*4]
    mov     [rcx+rdx*4], eax
    add     eax, esi
    inc     edx
    jmp     7b
71: mov     [rsp+44], eax               # entries
    lea     edi, [rax+1]
    shl     rdi, 2
    call    pl_alloc
    test    rax, rax
    jz      .Lpg_fail
    mov     [r12+PC_ENT], rax
    mov     edi, [rbx+ME_NTRIS]
    inc     edi
    shl     rdi, 2
    call    pl_alloc
    test    rax, rax
    jz      .Lpg_fail
    mov     [r12+PC_STAMP], rax
    mov     dword ptr [rsp+12], 1
    jmp     .Lpg_pass
.Lpg_done:
    mov     rcx, [r12+PC_OFF]           # the cursors -> ends; offsets again
    mov     edx, [rsp+8]
8:  dec     edx
    js      81f
    mov     eax, [rcx+rdx*4]
    mov     [rcx+rdx*4+4], eax
    jmp     8b
81: mov     dword ptr [rcx], 0
.Lpg_have:
    mov     rax, r12
    jmp     9f
.Lpg_fail:
    mov     qword ptr [r12+PC_MESH], 0
.Lpg_none:
    xor     eax, eax
9:  add     rsp, 56
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# tri_cells(rdi=mesh, esi=triangle, rdx=out 6 ints) - (pl_grid, r12 = the
#   grid) the cells its box touches
tri_cells:
    push    rbx
    mov     rbx, rdx
    lea     rax, [rsi+rsi*2]
    shl     rax, 2
    add     rax, [rdi+ME_TRIS]
    mov     r8, [rdi+ME_POS]
    movaps  xmm0, [rip+f_bigv]
    movaps  xmm1, [rip+f_nbigv]
    xor     ecx, ecx
1:  mov     edx, [rax+rcx*4]
    lea     rdx, [rdx+rdx*2]
    movsd   xmm2, [r8+rdx*4]
    insertps xmm2, [r8+rdx*4+8], 0x20
    minps   xmm0, xmm2
    maxps   xmm1, xmm2
    inc     ecx
    cmp     ecx, 3
    jb      1b
    movups  xmm3, [rdi+ME_BMIN]
    andps   xmm3, [rip+f_xyz]
    movss   xmm4, [r12+PC_CELL]
    shufps  xmm4, xmm4, 0
    subps   xmm0, xmm3
    divps   xmm0, xmm4
    subps   xmm1, xmm3
    divps   xmm1, xmm4
    cvttps2dq xmm0, xmm0
    cvttps2dq xmm1, xmm1
    xor     ecx, ecx
2:  movd    eax, xmm0
    movd    edx, xmm1
    test    eax, eax
    jns     21f
    xor     eax, eax
21: test    edx, edx
    jns     22f
    xor     edx, edx
22: movzx   r9d, word ptr [r12+PC_N+rcx*2]
    dec     r9d
    cmp     eax, r9d
    cmovg   eax, r9d
    cmp     edx, r9d
    cmovg   edx, r9d
    mov     [rbx+rcx*4], eax
    mov     [rbx+rcx*4+12], edx
    psrldq  xmm0, 4
    psrldq  xmm1, 4
    inc     ecx
    cmp     ecx, 3
    jb      2b
    pop     rbx
    ret

# cell_of_pt(rdi=grid, xmm0=point in its space) -> eax, edx, ecx = the cell
#   (clamped)
cell_of_pt:
    mov     rax, [rdi+PC_MESH]
    movups  xmm1, [rax+ME_BMIN]
    andps   xmm1, [rip+f_xyz]
    subps   xmm0, xmm1
    movss   xmm2, [rdi+PC_CELL]
    shufps  xmm2, xmm2, 0
    divps   xmm0, xmm2
    maxps   xmm0, [rip+f_m1v]           # (far off: clamped, no overflow)
    minps   xmm0, [rip+f_capv]
    cvttps2dq xmm0, xmm0
    sub     rsp, 16
    movdqu  [rsp], xmm0
    xor     ecx, ecx
1:  mov     eax, [rsp+rcx*4]
    test    eax, eax
    jns     2f
    xor     eax, eax
2:  movzx   edx, word ptr [rdi+PC_N+rcx*2]
    dec     edx
    cmp     eax, edx
    cmovg   eax, edx
    mov     [rsp+rcx*4], eax
    inc     ecx
    cmp     ecx, 3
    jb      1b
    mov     eax, [rsp]
    mov     edx, [rsp+4]
    mov     ecx, [rsp+8]
    add     rsp, 16
    ret

# pl_alloc(rdi=bytes) -> rax = zeroed memory (0: none); freed with the grids
pl_alloc:
    push    rbx
    mov     rsi, rdi
    add     rsi, 4095
    and     rsi, -4096
    mov     rbx, rsi
    xor     edi, edi
    mov     edx, PROT_RW
    mov     r10d, MAP_ANON_PRIV
    mov     r8, -1
    xor     r9d, r9d
    mov     eax, SYS_MMAP
    syscall
    cmp     rax, -4096
    jae     8f
    mov     ecx, [rip+pl_nmaps]         # remembered for pl_free_grids
    cmp     ecx, 3*PC_MAX
    jae     9f
    lea     rdx, [rip+pl_maps]
    shl     ecx, 4
    mov     [rdx+rcx], rax
    mov     [rdx+rcx+8], rbx
    inc     dword ptr [rip+pl_nmaps]
    jmp     9f
8:  xor     eax, eax
9:  pop     rbx
    ret

# pl_free_grids - every grid given back
pl_free_grids:
    push    rbx
    xor     ebx, ebx
1:  cmp     ebx, [rip+pl_nmaps]
    jae     2f
    mov     eax, ebx
    shl     eax, 4
    lea     rdx, [rip+pl_maps]
    mov     rdi, [rdx+rax]
    mov     rsi, [rdx+rax+8]
    mov     eax, SYS_MUNMAP
    syscall
    inc     ebx
    jmp     1b
2:  mov     dword ptr [rip+pl_nmaps], 0
    mov     dword ptr [rip+pl_ntab], 0
    lea     rdi, [rip+pl_tab]
    mov     ecx, PC_SZ*PC_MAX/8
    xor     eax, eax
    rep     stosq
    pop     rbx
    ret

# =============================================================================
#  Scripts, the HUD
# =============================================================================
# pl_script_step(xmm0=seconds, xmm1=forward, xmm2=right, xmm3=up / jump,
#   edi=1 run) - play on for that time with those keys (tests): the keys
#   as held for the whole time
pl_script_step:
    cmp     dword ptr [rip+pl_on], 1
    jne     9f
    push    rbp                         # any caller's stack (MCP, scripts)
    mov     rbp, rsp
    and     rsp, -16
    xor     eax, eax
    xorps   xmm4, xmm4
    comiss  xmm1, xmm4
    jbe     1f
    or      eax, IN_FWD
1:  comiss  xmm1, xmm4
    jae     2f
    or      eax, IN_BACK
2:  comiss  xmm2, xmm4
    jbe     3f
    or      eax, IN_RIGHT
3:  comiss  xmm2, xmm4
    jae     4f
    or      eax, IN_LEFT
4:  comiss  xmm3, xmm4
    jbe     5f
    or      eax, IN_UP
5:  comiss  xmm3, xmm4
    jae     6f
    or      eax, IN_DOWN
6:  test    edi, edi
    jz      7f
    or      eax, IN_RUN
7:  mov     [rip+pl_keys], eax
    sub     rsp, 16                     # in frames of 1/60 s, as the window
    movss   [rsp], xmm0                 #  plays it (animations, logic)
71: movss   xmm0, [rsp]
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    jbe     72f
    minss   xmm0, [rip+f_frame]
    movss   xmm1, [rsp]
    subss   xmm1, xmm0
    movss   [rsp], xmm1
    call    pl_advance
    jmp     71b
72: add     rsp, 16
    mov     dword ptr [rip+pl_keys], 0
    mov     rsp, rbp
    pop     rbp
9:  ret

# pl_script_look(xmm0=yaw, xmm1=pitch degrees) - where the player looks
pl_script_look:
    divss   xmm0, [rip+f_rad2deg]
    divss   xmm1, [rip+f_rad2deg]
    maxss   xmm1, [rip+f_pmin]
    minss   xmm1, [rip+f_pmax]
    movss   [rip+cam_yaw], xmm0
    movss   [rip+cam_pitch], xmm1
    cmp     dword ptr [rip+pl_on], 1
    jne     9f
    push    rbp
    mov     rbp, rsp
    and     rsp, -16
    call    pl_camera
    mov     rsp, rbp
    pop     rbp
9:  ret

# pl_stat(edi=k) -> xmm0: 0 state (0 off, 1 playing, 2 asking), 1-3 the feet
#   (x y z), 4 on the ground, 5-7 velocity, 8 mode (1 walk, 2 fly), 9 yaw,
#   10 pitch (degrees), 11 seconds played, 12 the frame, 13 the mouse
#   captured (a locked pointer), 14 steps taken, 15 meshes with a grid
pl_stat:
    xorps   xmm0, xmm0
    cmp     edi, 0
    jne     1f
    cvtsi2ss xmm0, dword ptr [rip+pl_on]
    ret
1:  cmp     edi, 3
    ja      2f
    lea     rax, [rip+pl_pos]
    movss   xmm0, [rax+rdi*4-4]
    ret
2:  cmp     edi, 4
    jne     3f
    cvtsi2ss xmm0, dword ptr [rip+pl_ground]
    ret
3:  cmp     edi, 7
    ja      4f
    lea     rax, [rip+pl_vel]
    movss   xmm0, [rax+rdi*4-20]
    ret
4:  cmp     edi, 8
    jne     5f
    cvtsi2ss xmm0, dword ptr [rip+pl_mode]
    ret
5:  cmp     edi, 9
    jne     6f
    movss   xmm0, [rip+cam_yaw]
    mulss   xmm0, [rip+f_rad2deg]
    ret
6:  cmp     edi, 10
    jne     7f
    movss   xmm0, [rip+cam_pitch]
    mulss   xmm0, [rip+f_rad2deg]
    ret
7:  cmp     edi, 11
    jne     8f
    movss   xmm0, [rip+pl_time]
    ret
8:  cmp     edi, 12
    jne     81f
    movss   xmm0, [rip+an_frame]
    ret
81: cmp     edi, 13
    jne     82f
    cvtsi2ss xmm0, dword ptr [rip+pl_locked]
    ret
82: cmp     edi, 14
    jne     83f
    cvtsi2ss xmm0, dword ptr [rip+pl_steps]
    ret
83: cmp     edi, 15
    jne     9f
    cvtsi2ss xmm0, dword ptr [rip+pl_ntab]
9:  ret

# play_hud - (viewport_draw) what the keys do, or the question
play_hud:
    cmp     dword ptr [rip+pl_on], 0
    je      9f
    sub     rsp, 8
    mov     edi, [rip+cvs_x0]
    add     edi, 10
    mov     esi, [rip+cvs_y1]
    sub     esi, 30
    mov     edx, [rip+cvs_x1]
    sub     edx, [rip+cvs_x0]
    sub     edx, 20
    mov     ecx, 22
    mov     r8d, 0x1d2027
    call    fill_rect
    mov     edi, [rip+cvs_x0]
    add     edi, 18
    mov     esi, [rip+cvs_y1]
    sub     esi, 27
    lea     rdx, [rip+s_hud]
    cmp     dword ptr [rip+pl_mode], 2
    jne     1f
    lea     rdx, [rip+s_hud_fly]
1:  mov     ecx, COL_TEXT
    cmp     dword ptr [rip+pl_on], 2
    jne     2f
    lea     rdx, [rip+s_ask]
    mov     ecx, COL_ACCENT
2:  call    draw_text
    add     rsp, 8
9:  ret

# ms_now -> rax = monotonic milliseconds
ms_now:
    sub     rsp, 24
    mov     edi, 1
    mov     rsi, rsp
    mov     eax, 228
    syscall
    mov     rax, [rsp]
    imul    rax, rax, 1000
    mov     rcx, rax
    mov     rax, [rsp+8]
    xor     edx, edx
    mov     r8d, 1000000
    div     r8
    add     rax, rcx
    add     rsp, 24
    ret

.section .rodata
.align 16
f_bigv:         .float 1.0e30, 1.0e30, 1.0e30, 0
f_nbigv:        .float -1.0e30, -1.0e30, -1.0e30, 0
f_half4:        .float 0.5, 0.5, 0.5, 0
f_sign4:        .long 0x80000000, 0x80000000, 0x80000000, 0
f_tiny4:        .float 1.0e-4, 1.0e-4, 1.0e-4, 1.0e-4
f_m1v:          .float -1.0, -1.0, -1.0, -1.0
f_capv:         .float 200.0, 200.0, 200.0, 200.0
pl_dt4:         .float 0.0083333333, 0.0083333333, 0.0083333333, 0
f_three:        .float 3.0
f_minh:         .float 0.2
f_rise:         .float 0.05
f_stepk:        .float 1.2
f_gcap:         .float 128.0
f_thousand:     .float 1000.0
.section .bss
.align 16
pl_pair_s:      .skip 16
pl_pair_t:      .skip 16
pl_maps:        .skip 16*3*PC_MAX
pl_nmaps:       .skip 4
.text
