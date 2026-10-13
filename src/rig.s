# =============================================================================
#  BeeModel - rigging: constraints, inverse kinematics, drivers, motion
#  paths and onion skins.
#
#  Constraints and drivers live in the animation block (anim.s), so they are
#  shared with undo steps, copied before a change and saved with the keys.
#
#  Object constraints act on the owner's own transform (its "base", what
#  the user or the keys last set it to), in their order: copy location /
#  rotation / scale (some axes, optionally added to the base), track to (an
#  axis points at the target, another up), limit location / rotation /
#  scale, child of (the target's motion since the constraint was made).
#  The result is written into the object; a later difference from what was
#  written is the user's edit and becomes the new base.
#
#  IK (on a bone of an armature): the chain from the bone up its parents
#  (chain length, 0: to the root) reaches for a target object, FABRIK or
#  CCD, then the chain turns about its root-to-tip line towards a pole
#  object. Bones get the rotation from their posed direction to the solved
#  one; arm.s poses the armature again with those (descendants follow).
#
#  Drivers set a channel (any animation path) from an expression (expr.s)
#  over named variables (other channels) and "frame", whenever the scene is
#  evaluated: every frame drawn, after an operator or a frame change.
#
#  Motion paths: the selected objects' origins (or, in pose mode, the
#  selected bones' tails) over a frame range, drawn as lines with a dot a
#  frame, keyed frames larger. Onion skins: the active object's evaluated
#  mesh some frames before (red) and after (green), drawn as wires.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

.globl rig_eval
.globl rig_ik
.globl rig_draw
.globl rig_tick
.globl rig_reset
.globl bone_tail
.globl expr_name_hook

# a constraint
.equ CN_OWNER,  0                       # object uid
.equ CN_BONE,   4                       # IK: the tip bone
.equ CN_TYPE,   8
.equ CN_TARGET, 12                      # object uid (0: none)
.equ CN_POLE,   16                      # IK: object uid (0: none)
.equ CN_AXES,   20                      # bits x y z
.equ CN_TRACK,  24                      # track to: the axis (x y z -x -y -z);
                                        #  IK: the solver (0 FABRIK, 1 CCD)
.equ CN_UP,     28                      # track to: the up axis
.equ CN_INFL,   32                      # influence 0..1
.equ CN_CHAIN,  36                      # IK: bones (0: to the root)
.equ CN_ITER,   40                      # IK: iterations
.equ CN_FLAGS,  44
.equ CN_MIN,    48                      # limits
.equ CN_MAX,    60
.equ CN_BASE,   72                      # the owner's own transform,
.equ CN_LAST,   108                     #  and what was written (9 floats)
.equ CN_INV,    144                     # child of: the target's inverse then
.equ CF_OFFSET, 1                       # copy: add to the base
.equ CF_BASE,   2                       # CN_BASE is set
.equ CF_MUTE,   4
.equ CT_COPYLOC, 1
.equ CT_COPYROT, 2
.equ CT_COPYSCL, 3
.equ CT_TRACK,  4
.equ CT_LIMLOC, 5
.equ CT_LIMROT, 6
.equ CT_LIMSCL, 7
.equ CT_CHILD,  8
.equ CT_IK,     9
# a driver
.equ DR_KIND,   0                       # the channel it sets
.equ DR_A,      4
.equ DR_B,      8
.equ DR_C,      12
.equ DR_NV,     16
.equ DR_MUTE,   20
.equ DR_VARS,   24                      # 4 x (name 8, kind a b c)
.equ DR_MAXV,   4
.equ DR_EXPR,   120
.equ DR_EXPRSZ, DR_SZ_-DR_EXPR
# arm.s
.equ AR_N,      4
.equ BN_PARENT, 24
.equ BN_HEAD,   28
.equ BN_TAIL,   40
.equ BN_SEL,    56
.equ IK_MAXB,   32
.equ MP_MAX,    4                       # motion paths
.equ MP_MAXF,   1024
.equ ON_MAX,    8                       # onion skins (before + after)
.equ HASHK,     0x9E3779B97F4A7C15
.equ K_OBJ_,    1
.equ K_BONE_,   5
.equ COL_GHOST_A, 0x60d070              # onion skins after,
.equ COL_GHOST_B, 0xf06060              #  before
.equ COL_PATH,  0x7aa6ff
.equ COL_PATH_KEY, 0xffd27a

.section .data
.align 4
on_before:      .long 2                 # onion skins: frames before, after,
on_after:       .long 2
on_step:        .long 2                 #  every how many frames

.section .bss
.align 16
rg_t:           .skip 48                # a transform being built: loc rot scale
rg_prev:        .skip 48
rg_e:           .skip 48
rg_m:           .skip 64
rg_m2:          .skip 64
rg_m3:          .skip 64
rg_cols:        .skip 48                # track to: the axes as columns
rg_v:           .skip 16
rg_w:           .skip 16
rg_busy:        .skip 4
rg_n:           .skip 4
rg_ikh:         .skip 8                 # the IK constraints and what they read
expr_name_hook: .skip 8                 # expr.s asks it for names (0: none)
dr_cur:         .skip 8                 # the driver being evaluated
ik_a:           .skip 64                # the armature's matrix, its inverse
ik_ai:          .skip 64
ik_b:           .skip 4*IK_MAXB         # the chain, root first
ik_p:           .skip 16*(IK_MAXB+1)    # joints: solved,
ik_o:           .skip 16*(IK_MAXB+1)    #  as posed
ik_l:           .skip 4*IK_MAXB         # segment lengths
ik_n:           .skip 4
ik_tgt:         .skip 16
ik_pole:        .skip 16
ik_d0:          .skip 16
ik_d1:          .skip 16
ik_q:           .skip 64
ik_mo:          .skip 64
ik_mn:          .skip 64
ik_t1:          .skip 64
ik_t2:          .skip 64
ik_t3:          .skip 64
mp_n:           .skip 4                 # motion paths: how many,
mp_f0:          .skip 4                 #  from which frame,
mp_nf:          .skip 4                 #  frames
mp_anim:        .skip 8                 #  the animation they saw
mp_pts:         .skip MP_MAX*MP_MAXF*12
mp_key:         .skip MP_MAX*MP_MAXF    #  a key there
mp_who:         .skip MP_MAX*8          #  uid, bone (-1: the object)
on_on:          .skip 4                 # onion skins: shown,
on_n:           .skip 4                 #  ghosts made,
on_obj:         .skip 8                 #  of which object,
on_frame:       .skip 4                 #  around which frame,
on_anim:        .skip 8                 #  with which animation,
on_mesh:        .skip 8*ON_MAX          #  each a mesh (referenced),
on_mat:         .skip 48*ON_MAX         #  its matrix,
on_off:         .skip 4*ON_MAX          #  its frame offset
rg_word:        .skip 64

.section .rodata
.align 16
rf_one:         .float 1.0
rf_zero:        .float 0.0
rf_tiny:        .float 1.0e-8
rf_tol:         .float 1.0e-4
rf_half:        .float 0.5
rf_near:        .float 0.9999
rf_up:          .float 0.999
rf_neg1:        .float -0.99999
rf_pi:          .float 3.14159265
rf_deg:         .float 0.017453292
.align 16
rf_absm:        .long 0x7fffffff, 0, 0, 0
rf_ident:       .float 1, 0, 0, 0,  0, 1, 0, 0,  0, 0, 1, 0
.text

# -----------------------------------------------------------------------------
# Vectors (3 floats in memory)
# -----------------------------------------------------------------------------
# vsub(rdi=out, rsi=a, rdx=b) - out = a - b
vsub:
    movss   xmm0, [rsi]
    subss   xmm0, [rdx]
    movss   xmm1, [rsi+4]
    subss   xmm1, [rdx+4]
    movss   xmm2, [rsi+8]
    subss   xmm2, [rdx+8]
    movss   [rdi], xmm0
    movss   [rdi+4], xmm1
    movss   [rdi+8], xmm2
    ret
# vdot(rdi=a, rsi=b) -> xmm0
vdot:
    movss   xmm0, [rdi]
    mulss   xmm0, [rsi]
    movss   xmm1, [rdi+4]
    mulss   xmm1, [rsi+4]
    addss   xmm0, xmm1
    movss   xmm1, [rdi+8]
    mulss   xmm1, [rsi+8]
    addss   xmm0, xmm1
    ret
# vlen(rdi) -> xmm0
vlen:
    mov     rsi, rdi
    call    vdot
    sqrtss  xmm0, xmm0
    ret
# vnorm(rdi) - unit in place (unchanged when ~0) -> xmm0 = its length
vnorm:
    call    vlen
    comiss  xmm0, [rip+rf_tiny]
    jbe     1f
    movss   xmm1, [rip+rf_one]
    divss   xmm1, xmm0
    movss   xmm2, [rdi]
    mulss   xmm2, xmm1
    movss   [rdi], xmm2
    movss   xmm2, [rdi+4]
    mulss   xmm2, xmm1
    movss   [rdi+4], xmm2
    movss   xmm2, [rdi+8]
    mulss   xmm2, xmm1
    movss   [rdi+8], xmm2
1:  ret
# vaxpy(rdi=out, rsi=a, rdx=d, xmm0=s) - out = a + s d (out may be a or d)
vaxpy:
    movss   xmm1, [rdx]
    mulss   xmm1, xmm0
    addss   xmm1, [rsi]
    movss   xmm2, [rdx+4]
    mulss   xmm2, xmm0
    addss   xmm2, [rsi+4]
    movss   xmm3, [rdx+8]
    mulss   xmm3, xmm0
    addss   xmm3, [rsi+8]
    movss   [rdi], xmm1
    movss   [rdi+4], xmm2
    movss   [rdi+8], xmm3
    ret
# vcross(rdi=out, rsi=a, rdx=b) - out = a x b (out not a or b)
vcross:
    movss   xmm0, [rsi+4]
    mulss   xmm0, [rdx+8]
    movss   xmm1, [rsi+8]
    mulss   xmm1, [rdx+4]
    subss   xmm0, xmm1
    movss   [rdi], xmm0
    movss   xmm0, [rsi+8]
    mulss   xmm0, [rdx]
    movss   xmm1, [rsi]
    mulss   xmm1, [rdx+8]
    subss   xmm0, xmm1
    movss   [rdi+4], xmm0
    movss   xmm0, [rsi]
    mulss   xmm0, [rdx+4]
    movss   xmm1, [rsi+4]
    mulss   xmm1, [rdx]
    subss   xmm0, xmm1
    movss   [rdi+8], xmm0
    ret
# vcopy(rdi=out, rsi=a)
vcopy:
    mov     rax, [rsi]
    mov     [rdi], rax
    mov     eax, [rsi+8]
    mov     [rdi+8], eax
    ret

# rot_axis(rdi=out 3x4, rsi=unit axis k, xmm0=angle) - R = c I + s [k]x +
#   (1 - c) k k^T, no translation
rot_axis:
    push    rbx
    push    r12
    sub     rsp, 24
    mov     rbx, rdi
    mov     r12, rsi
    call    sincos                      # xmm0 = sin, xmm1 = cos
    movss   [rsp], xmm0
    movss   [rsp+4], xmm1
    movss   xmm2, [rip+rf_one]
    subss   xmm2, xmm1
    movss   [rsp+8], xmm2               # 1 - c
    xor     ecx, ecx
1:  xor     edx, edx
2:  movss   xmm0, [r12+rcx*4]           # (1 - c) k_i k_j
    mulss   xmm0, [r12+rdx*4]
    mulss   xmm0, [rsp+8]
    cmp     ecx, edx
    jne     3f
    addss   xmm0, [rsp+4]
3:  imul    r8, rcx, 16
    lea     r8, [rbx+r8]
    movss   [r8+rdx*4], xmm0
    inc     edx
    cmp     edx, 3
    jb      2b
    mov     dword ptr [r8+12], 0
    inc     ecx
    cmp     ecx, 3
    jb      1b
    movss   xmm3, [rsp]                 # + s [k]x
    lea     rdi, [rbx]
    lea     rsi, [r12]
    call    add_skew
    add     rsp, 24
    pop     r12
    pop     rbx
    ret
# add_skew(rdi=3x4, rsi=v, xmm3=s) - += s [v]x
add_skew:
    movss   xmm0, [rsi]                 # x
    mulss   xmm0, xmm3
    movss   xmm1, [rsi+4]               # y
    mulss   xmm1, xmm3
    movss   xmm2, [rsi+8]               # z
    mulss   xmm2, xmm3
    movss   xmm4, [rdi+4]               # m01 -= z
    subss   xmm4, xmm2
    movss   [rdi+4], xmm4
    movss   xmm4, [rdi+8]               # m02 += y
    addss   xmm4, xmm1
    movss   [rdi+8], xmm4
    movss   xmm4, [rdi+16]              # m10 += z
    addss   xmm4, xmm2
    movss   [rdi+16], xmm4
    movss   xmm4, [rdi+24]              # m12 -= x
    subss   xmm4, xmm0
    movss   [rdi+24], xmm4
    movss   xmm4, [rdi+32]              # m20 -= y
    subss   xmm4, xmm1
    movss   [rdi+32], xmm4
    movss   xmm4, [rdi+36]              # m21 += x
    addss   xmm4, xmm0
    movss   [rdi+36], xmm4
    ret

# rot_ab(rdi=out 3x4, rsi=unit a, rdx=unit b) - the shortest rotation taking
#   a to b: I + [v]x + [v]x^2 / (1 + c), v = a x b, c = a . b
rot_ab:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 48
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13, rdx
    lea     rdi, [rsp]
    call    vcross
    mov     rdi, r12
    mov     rsi, r13
    call    vdot
    comiss  xmm0, [rip+rf_neg1]
    ja      1f
    # opposite: half a turn about an axis square to a
    lea     rdi, [rsp+16]               # a x X
    mov     rsi, r12
    lea     rdx, [rip+rf_ident]
    call    vcross
    lea     rdi, [rsp+16]
    call    vnorm
    comiss  xmm0, [rip+rf_tol]
    ja      11f
    lea     rdi, [rsp+16]               # (a along X: a x Y)
    mov     rsi, r12
    lea     rdx, [rip+rf_ident+16]
    call    vcross
    lea     rdi, [rsp+16]
    call    vnorm
11: mov     rdi, rbx
    lea     rsi, [rsp+16]
    movss   xmm0, [rip+rf_pi]
    call    rot_axis
    jmp     9f
1:  addss   xmm0, [rip+rf_one]
    movss   xmm1, [rip+rf_one]
    divss   xmm1, xmm0
    movss   [rsp+32], xmm1              # f = 1 / (1 + c)
    lea     rdi, [rsp]
    lea     rsi, [rsp]
    call    vdot
    movss   [rsp+36], xmm0              # v . v
    xor     ecx, ecx                    # I + f (v v^T - (v.v) I)
2:  xor     edx, edx
3:  movss   xmm0, [rsp+rcx*4]
    mulss   xmm0, [rsp+rdx*4]
    cmp     ecx, edx
    jne     4f
    subss   xmm0, [rsp+36]
4:  mulss   xmm0, [rsp+32]
    cmp     ecx, edx
    jne     5f
    addss   xmm0, [rip+rf_one]
5:  imul    r8, rcx, 16
    lea     r8, [rbx+r8]
    movss   [r8+rdx*4], xmm0
    inc     edx
    cmp     edx, 3
    jb      3b
    mov     dword ptr [r8+12], 0
    inc     ecx
    cmp     ecx, 3
    jb      2b
    mov     rdi, rbx                    # + [v]x
    lea     rsi, [rsp]
    movss   xmm3, [rip+rf_one]
    call    add_skew
9:  add     rsp, 48
    pop     r13
    pop     r12
    pop     rbx
    ret

# -----------------------------------------------------------------------------
# Evaluation
# -----------------------------------------------------------------------------
# rig_eval - drivers, then constraints, into the scene; armatures whose IK
#   changed are posed again (call it whenever the scene may have changed)
rig_eval:
    push    rbx
    push    r12
    sub     rsp, 8
    cmp     dword ptr [rip+rg_busy], 0
    jne     9f
    mov     rbx, [rip+an_cur]
    test    rbx, rbx
    jz      5f
    mov     eax, [rbx+AN_NCON_]
    or      eax, [rbx+AN_NDRV_]
    jz      5f
    mov     dword ptr [rip+rg_busy], 1
    call    rig_drivers
    call    rig_constraints
    call    rig_ikcheck
    mov     dword ptr [rip+rg_busy], 0
    call    arm_refresh
    jmp     9f
5:  cmp     qword ptr [rip+rg_ikh], 0   # no rigging: was there IK?
    je      9f
    mov     qword ptr [rip+rg_ikh], 0
    call    arms_dirty
    call    arm_refresh
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# rig_reset - a new scene: nothing seen yet
rig_reset:
    mov     qword ptr [rip+rg_ikh], 0
    mov     dword ptr [rip+mp_n], 0
    mov     qword ptr [rip+on_obj], 0
    jmp     on_free

# arms_dirty - every armature is posed again
arms_dirty:
    push    rbx
    xor     ebx, ebx
1:  cmp     ebx, [rip+obj_count]
    jae     9f
    mov     edi, ebx
    call    obj_at
    cmp     dword ptr [rax+OB_TYPE], OT_ARMATURE
    jne     2f
    or      dword ptr [rax+OB_FLAGS], OBF_ARM_DIRTY
2:  inc     ebx
    jmp     1b
9:  pop     rbx
    ret

# ---- drivers -----------------------------------------------------------------
rig_drivers:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 16
    mov     rbx, [rip+an_cur]
    xor     r12d, r12d
1:  cmp     r12d, [rbx+AN_NDRV_]
    jae     9f
    imul    r13, r12, DR_SZ_
    lea     r13, [rbx+AN_DRV_+r13]
    cmp     dword ptr [r13+DR_MUTE], 0
    jne     8f
    mov     [rip+dr_cur], r13
    lea     rax, [rip+dr_name]
    mov     [rip+expr_name_hook], rax
    lea     rdi, [r13+DR_EXPR]
    call    expr_eval
    mov     qword ptr [rip+expr_name_hook], 0
    test    eax, eax
    jz      8f
    cvtsd2ss xmm0, xmm0
    movss   [rsp], xmm0
    mov     edi, [r13+DR_KIND]          # set only when it differs
    mov     esi, [r13+DR_A]
    mov     edx, [r13+DR_B]
    mov     ecx, [r13+DR_C]
    xor     r8d, r8d
    call    an_chan
    test    eax, eax
    jz      8f
    ucomiss xmm0, [rsp]
    jne     2f
    jnp     8f
2:  mov     edi, [r13+DR_KIND]
    mov     esi, [r13+DR_A]
    mov     edx, [r13+DR_B]
    mov     ecx, [r13+DR_C]
    movss   xmm0, [rsp]
    mov     r8d, 1
    call    an_chan
    mov     dword ptr [rip+dirty], 1
8:  inc     r12d
    jmp     1b
9:  add     rsp, 16
    pop     r13
    pop     r12
    pop     rbx
    ret

# dr_name(rdi=name, 8-byte padded) -> eax = 1, xmm0 = its value (double):
#   "frame" or one of the driver's variables
dr_name:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12
    and     rsp, -16
    mov     rax, [rdi]
    cmp     qword ptr [rdi+8], 0
    jne     8f
    mov     rcx, 0x656d617266           # "frame"
    cmp     rax, rcx
    jne     1f
    cvtss2sd xmm0, [rip+an_frame]
    mov     eax, 1
    jmp     9f
1:  mov     rbx, [rip+dr_cur]
    xor     r12d, r12d
2:  cmp     r12d, [rbx+DR_NV]
    jae     8f
    imul    rcx, r12, 24
    cmp     rax, [rbx+DR_VARS+rcx]
    je      3f
    inc     r12d
    jmp     2b
3:  lea     rcx, [rbx+DR_VARS+rcx]
    mov     edi, [rcx+8]
    mov     esi, [rcx+12]
    mov     edx, [rcx+16]
    mov     ecx, [rcx+20]
    xor     r8d, r8d
    call    an_chan
    test    eax, eax
    jz      9f
    cvtss2sd xmm0, xmm0
    mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  lea     rsp, [rbp-16]
    pop     r12
    pop     rbx
    pop     rbp
    ret

# ---- object constraints ----------------------------------------------------------
# cn_rec(rbx=block, esi=index) -> rax = the record
cn_rec:
    imul    rax, rsi, CN_SZ_
    lea     rax, [rbx+AN_CON_+rax]
    ret

# cn_live(rax=record) -> ZF set when it acts on objects (not IK, not muted)
cn_live:
    test    dword ptr [rax+CN_FLAGS], CF_MUTE
    jnz     1f
    cmp     dword ptr [rax+CN_TYPE], CT_IK
    je      1f
    cmp     eax, eax                    # ZF = 1
    ret
1:  or      eax, 1                      # (rax kept non-zero) ZF = 0
    ret

rig_constraints:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    mov     rbx, [rip+an_cur]
    xor     r12d, r12d
1:  cmp     r12d, [rbx+AN_NCON_]
    jae     9f
    mov     esi, r12d
    call    cn_rec
    mov     r13, rax
    call    cn_live
    jnz     8f
    xor     r15d, r15d                  # its owner's first?
2:  cmp     r15d, r12d
    jae     3f
    mov     esi, r15d
    call    cn_rec
    mov     ecx, [rax+CN_OWNER]
    cmp     ecx, [r13+CN_OWNER]
    jne     21f
    call    cn_live
    jz      8f
21: inc     r15d
    jmp     2b
3:  mov     edi, [r13+CN_OWNER]
    call    obj_by_uid
    test    rax, rax
    jz      8f
    mov     r14, rax
    test    dword ptr [r13+CN_FLAGS], CF_BASE   # changed since written: its base
    jz      31f
    lea     rsi, [r14+OB_LOC]
    lea     rdi, [r13+CN_LAST]
    mov     ecx, 36
    repe    cmpsb
    je      32f
31: lea     rsi, [r14+OB_LOC]
    lea     rdi, [r13+CN_BASE]
    mov     ecx, 36
    rep     movsb
    or      dword ptr [r13+CN_FLAGS], CF_BASE
32: lea     rsi, [r13+CN_BASE]
    lea     rdi, [rip+rg_t]
    mov     ecx, 36
    rep     movsb
    mov     r15d, r12d                  # each of the owner's, in order
4:  cmp     r15d, [rbx+AN_NCON_]
    jae     5f
    mov     esi, r15d
    call    cn_rec
    mov     ecx, [rax+CN_OWNER]
    cmp     ecx, [r13+CN_OWNER]
    jne     41f
    call    cn_live
    jnz     41f
    mov     rdi, rax
    call    cn_apply
41: inc     r15d
    jmp     4b
5:  lea     rsi, [rip+rg_t]             # written when it differs
    lea     rdi, [r14+OB_LOC]
    mov     ecx, 36
    repe    cmpsb
    je      51f
    lea     rsi, [rip+rg_t]
    lea     rdi, [r14+OB_LOC]
    mov     ecx, 36
    rep     movsb
    mov     dword ptr [rip+dirty], 1
51: lea     rsi, [rip+rg_t]
    lea     rdi, [r13+CN_LAST]
    mov     ecx, 36
    rep     movsb
8:  inc     r12d
    jmp     1b
9:  add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# cn_apply(rdi=record) - rg_t through one constraint
cn_apply:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    lea     rsi, [rip+rg_t]
    lea     rdi, [rip+rg_prev]
    mov     ecx, 36
    rep     movsb
    xor     r12d, r12d
    mov     edi, [rbx+CN_TARGET]
    test    edi, edi
    jz      1f
    call    obj_by_uid
    mov     r12, rax
1:  mov     eax, [rbx+CN_TYPE]
    cmp     eax, CT_COPYSCL
    jbe     .Lca_copy
    cmp     eax, CT_TRACK
    je      .Lca_track
    cmp     eax, CT_LIMSCL
    jbe     .Lca_limit
    cmp     eax, CT_CHILD
    je      .Lca_child
    jmp     .Lca_infl
.Lca_copy:                              # copy location / rotation / scale
    test    r12, r12
    jz      .Lca_infl
    lea     r13d, [rax-1]
    imul    r13d, r13d, 12              # the property's offset
    xor     ecx, ecx
2:  bt      dword ptr [rbx+CN_AXES], ecx
    jnc     3f
    lea     rdx, [r13+rcx*4]
    movss   xmm0, [r12+OB_LOC+rdx]
    lea     r8, [rip+rg_t]
    test    dword ptr [rbx+CN_FLAGS], CF_OFFSET
    jz      22f
    cmp     dword ptr [rbx+CN_TYPE], CT_COPYSCL
    je      21f
    addss   xmm0, [r8+rdx]
    jmp     22f
21: mulss   xmm0, [r8+rdx]
22: movss   [r8+rdx], xmm0
3:  inc     ecx
    cmp     ecx, 3
    jb      2b
    jmp     .Lca_infl
.Lca_limit:                             # limit location / rotation / scale
    lea     r13d, [rax-CT_LIMLOC]
    imul    r13d, r13d, 12
    xor     ecx, ecx
4:  bt      dword ptr [rbx+CN_AXES], ecx
    jnc     5f
    lea     rdx, [r13+rcx*4]
    lea     r8, [rip+rg_t]
    movss   xmm0, [r8+rdx]
    minss   xmm0, [rbx+CN_MAX+rcx*4]
    maxss   xmm0, [rbx+CN_MIN+rcx*4]
    movss   [r8+rdx], xmm0
5:  inc     ecx
    cmp     ecx, 3
    jb      4b
    jmp     .Lca_infl
.Lca_track:
    test    r12, r12
    jz      .Lca_infl
    mov     rdi, rbx
    mov     rsi, r12
    call    cn_track
    jmp     .Lca_infl
.Lca_child:                             # T T0^-1 base
    test    r12, r12
    jz      .Lca_infl
    mov     rdi, r12
    lea     rsi, [rip+rg_m]
    call    obj_matrix
    lea     rdi, [rip+rg_m2]
    lea     rsi, [rip+rg_m]
    lea     rdx, [rbx+CN_INV]
    call    m_mul
    lea     rdi, [rip+rg_t-OB_LOC]
    lea     rsi, [rip+rg_m3]
    call    obj_matrix
    lea     rdi, [rip+rg_m]
    lea     rsi, [rip+rg_m2]
    lea     rdx, [rip+rg_m3]
    call    m_mul
    lea     rdi, [rip+rg_e-60]          # (pose_from_mat writes at +60: BN_LOC)
    lea     rsi, [rip+rg_m]
    call    pose_from_mat
    lea     rsi, [rip+rg_e]
    lea     rdi, [rip+rg_t]
    mov     ecx, 36
    rep     movsb
.Lca_infl:                              # prev + (now - prev) influence
    movss   xmm1, [rbx+CN_INFL]
    comiss  xmm1, [rip+rf_one]
    jae     9f
    xor     ecx, ecx
6:  lea     r8, [rip+rg_t]
    lea     r9, [rip+rg_prev]
    movss   xmm0, [r8+rcx*4]
    subss   xmm0, [r9+rcx*4]
    mulss   xmm0, xmm1
    addss   xmm0, [r9+rcx*4]
    movss   [r8+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 9
    jb      6b
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# cn_track(rdi=record, rsi=target) - rg_t's rotation: its track axis at the
#   target, its up axis as near world up (Y) as it can
cn_track:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 32
    mov     rbx, rdi
    lea     rdi, [rsp]                  # f = target - owner
    lea     rsi, [rsi+OB_LOC]
    lea     rdx, [rip+rg_t]
    call    vsub
    lea     rdi, [rsp]
    call    vnorm
    comiss  xmm0, [rip+rf_tiny]
    jbe     9f
    mov     eax, [rbx+CN_TRACK]
    xor     edx, edx
    mov     ecx, 3
    div     ecx                         # eax = 0 / 1 (negative), edx = axis
    mov     r12d, edx                   # the track axis
    mov     r13d, eax
    mov     r14d, [rbx+CN_UP]
    cmp     r14d, 3
    jb      1f
    xor     r14d, r14d
1:  cmp     r14d, r12d
    jne     2f
    lea     eax, [r12+1]
    xor     edx, edx
    mov     ecx, 3
    div     ecx
    mov     r14d, edx
2:  imul    r8, r12, 16                 # c[track] = +-f
    lea     rdi, [rip+rg_cols]
    add     rdi, r8
    lea     rsi, [rsp]
    call    vcopy
    test    r13d, r13d
    jz      3f
    xor     ecx, ecx
21: movss   xmm0, [rip+rf_zero]
    subss   xmm0, [rdi+rcx*4]
    movss   [rdi+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      21b
3:  mov     r15, rdi                    # c[up] = W - (W . c) c, W = Y (Z
    xorps   xmm0, xmm0                  #  when looking along Y)
    movss   [rsp+16], xmm0
    movss   [rsp+24], xmm0
    movss   xmm1, [rip+rf_one]
    movss   [rsp+20], xmm1
    movss   xmm2, [r15+4]
    andps   xmm2, [rip+rf_absm]
    comiss  xmm2, [rip+rf_up]
    jb      4f
    movss   [rsp+20], xmm0
    movss   [rsp+24], xmm1
4:  lea     rdi, [rsp+16]
    mov     rsi, r15
    call    vdot
    xorps   xmm1, xmm1
    subss   xmm1, xmm0
    imul    r8, r14, 16
    lea     rdi, [rip+rg_cols]
    add     rdi, r8
    lea     rsi, [rsp+16]
    mov     rdx, r15
    movss   xmm0, xmm1
    call    vaxpy
    imul    r8, r14, 16
    lea     rdi, [rip+rg_cols]
    add     rdi, r8
    call    vnorm
    mov     eax, 3                      # c[r] = c[r+1] x c[r+2]
    sub     eax, r12d
    sub     eax, r14d
    mov     r12d, eax
    lea     eax, [r12+1]
    xor     edx, edx
    mov     ecx, 3
    div     ecx
    imul    rsi, rdx, 16
    lea     rax, [rip+rg_cols]
    add     rsi, rax
    lea     eax, [r12+2]
    xor     edx, edx
    mov     ecx, 3
    div     ecx
    imul    rdx, rdx, 16
    lea     rax, [rip+rg_cols]
    add     rdx, rax
    imul    rdi, r12, 16
    add     rdi, rax
    call    vcross
    xor     ecx, ecx                    # the matrix: m[row][col] = c[col][row]
5:  xor     edx, edx
6:  imul    r8, rdx, 16
    lea     rax, [rip+rg_cols]
    add     r8, rax
    movss   xmm0, [r8+rcx*4]
    imul    r9, rcx, 16
    lea     rax, [rip+rg_m]
    add     r9, rax
    movss   [r9+rdx*4], xmm0
    inc     edx
    cmp     edx, 3
    jb      6b
    lea     rax, [rip+rg_t]
    movss   xmm0, [rax+rcx*4]
    movss   [r9+12], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      5b
    lea     rdi, [rip+rg_e-60]
    lea     rsi, [rip+rg_m]
    call    pose_from_mat
    lea     rsi, [rip+rg_e+12]          # its rotation only
    lea     rdi, [rip+rg_t+12]
    call    vcopy
9:  add     rsp, 32
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ---- IK ----------------------------------------------------------------------
# rig_ikcheck - a stamp of every IK constraint and the transforms it reads;
#   when it changes, armatures are posed again
rig_ikcheck:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     rbx, [rip+an_cur]
    xor     r13d, r13d                  # hash
    xor     r12d, r12d
1:  cmp     r12d, [rbx+AN_NCON_]
    jae     5f
    mov     esi, r12d
    call    cn_rec
    mov     r14, rax
    cmp     dword ptr [r14+CN_TYPE], CT_IK
    jne     4f
    mov     rax, HASHK
    xor     r13, 0x5bd1e995
    imul    r13, rax
    mov     rdi, r14                    # its settings
    mov     esi, 6
    call    ik_mix
    mov     edi, [r14+CN_OWNER]         # the transforms it reads
    call    ik_mix_obj
    mov     edi, [r14+CN_TARGET]
    call    ik_mix_obj
    mov     edi, [r14+CN_POLE]
    call    ik_mix_obj
4:  inc     r12d
    jmp     1b
5:  cmp     r13, [rip+rg_ikh]
    je      9f
    mov     [rip+rg_ikh], r13
    call    arms_dirty
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
# ik_mix(rdi=data, esi=qwords) - into r13
ik_mix:
    mov     rax, HASHK
1:  test    esi, esi
    jz      2f
    xor     r13, [rdi]
    imul    r13, rax
    add     rdi, 8
    dec     esi
    jmp     1b
2:  ret
# ik_mix_obj(edi=uid) - its transform into r13 (nothing when not there)
ik_mix_obj:
    sub     rsp, 8
    test    edi, edi
    jz      9f
    call    obj_by_uid
    test    rax, rax
    jz      9f
    lea     rdi, [rax+OB_LOC]
    mov     esi, 5                      # loc, rot, scale (and the colour)
    call    ik_mix
9:  add     rsp, 8
    ret

# rig_ik(rdi=bones, rsi=armature object or 0) -> eax = 1 when IK posed some
#   bones: am_ov / am_ovf (arm.s has am_m, am_r posed without IK)
rig_ik:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    mov     [rsp], rdi
    mov     dword ptr [rsp+8], 0        # any
    test    rsi, rsi
    jz      9f
    mov     r14, rsi
    mov     rbx, [rip+an_cur]
    test    rbx, rbx
    jz      9f
    cmp     dword ptr [rbx+AN_NCON_], 0
    je      9f
    mov     rdi, r14                    # world -> armature
    lea     rsi, [rip+ik_a]
    call    obj_matrix
    lea     rdi, [rip+ik_ai]
    lea     rsi, [rip+ik_a]
    call    m_inv
    xor     r12d, r12d
1:  cmp     r12d, [rbx+AN_NCON_]
    jae     9f
    mov     esi, r12d
    call    cn_rec
    mov     r13, rax
    cmp     dword ptr [r13+CN_TYPE], CT_IK
    jne     8f
    test    dword ptr [r13+CN_FLAGS], CF_MUTE
    jnz     8f
    mov     eax, [r13+CN_OWNER]
    cmp     eax, [r14+OB_UID]
    jne     8f
    mov     rdi, [rsp]
    mov     esi, [r13+CN_BONE]
    cmp     esi, [rdi+AR_N]
    jae     8f
    mov     edi, [r13+CN_TARGET]
    call    obj_by_uid
    test    rax, rax
    jz      8f
    lea     rdi, [rip+ik_ai]
    lea     rsi, [rax+OB_LOC]
    lea     rdx, [rip+ik_tgt]
    call    xform_point
    mov     rdi, [rsp]
    mov     rsi, r13
    call    ik_chain
    test    eax, eax
    jz      8f
    call    ik_solve_rec
    mov     rdi, [rsp]
    call    ik_pose
    mov     dword ptr [rsp+8], 1
8:  inc     r12d
    jmp     1b
9:  mov     eax, [rsp+8]
    add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ik_chain(rdi=bones, rsi=record) -> eax = bones in the chain (ik_b, root
#   first), ik_o / ik_p its joints as posed, ik_l the lengths (0: none)
ik_chain:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 24
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13d, [r12+CN_CHAIN]
    test    r13d, r13d
    jz      1f
    cmp     r13d, IK_MAXB
    jbe     2f
1:  mov     r13d, IK_MAXB
2:  xor     r14d, r14d                  # tip to root, then turned round
    mov     eax, [r12+CN_BONE]
3:  lea     rcx, [rip+ik_b]
    mov     [rcx+r14*4], eax
    inc     r14d
    cmp     r14d, r13d
    jae     4f
    mov     rdi, rbx
    mov     esi, eax
    call    arm_bone
    mov     eax, [rax+BN_PARENT]
    test    eax, eax
    jns     3b
4:  mov     [rip+ik_n], r14d
    xor     ecx, ecx
    lea     edx, [r14-1]
    lea     r8, [rip+ik_b]
5:  cmp     ecx, edx
    jge     6f
    mov     eax, [r8+rcx*4]
    mov     r9d, [r8+rdx*4]
    mov     [r8+rcx*4], r9d
    mov     [r8+rdx*4], eax
    inc     ecx
    dec     edx
    jmp     5b
6:  xor     ecx, ecx                    # heads: the matrices' translations
7:  cmp     ecx, r14d
    jae     71f
    lea     r8, [rip+ik_b]
    mov     eax, [r8+rcx*4]
    imul    rax, rax, 48
    lea     r8, [rip+am_m]
    add     r8, rax
    imul    r9, rcx, 16
    lea     r10, [rip+ik_o]
    add     r9, r10
    mov     eax, [r8+12]
    mov     [r9], eax
    mov     eax, [r8+28]
    mov     [r9+4], eax
    mov     eax, [r8+44]
    mov     [r9+8], eax
    inc     ecx
    jmp     7b
71: lea     r8, [rip+ik_b]              # the tip's tail: M (0 len 0)
    mov     esi, [r8+r14*4-4]
    mov     rdi, rbx
    call    arm_bone
    lea     rdi, [rsp]
    lea     rsi, [rax+BN_TAIL]
    lea     rdx, [rax+BN_HEAD]
    call    vsub
    lea     rdi, [rsp]
    call    vlen
    xorps   xmm1, xmm1
    movss   [rsp], xmm1
    movss   [rsp+4], xmm0
    movss   [rsp+8], xmm1
    lea     r8, [rip+ik_b]
    mov     eax, [r8+r14*4-4]
    imul    rax, rax, 48
    lea     rdi, [rip+am_m]
    add     rdi, rax
    lea     rsi, [rsp]
    imul    rdx, r14, 16
    lea     rax, [rip+ik_o]
    add     rdx, rax
    call    xform_point
    xor     ecx, ecx                    # lengths; ik_p = ik_o
8:  cmp     ecx, r14d
    jae     81f
    mov     [rsp+16], ecx
    imul    rsi, rcx, 16
    lea     rax, [rip+ik_o]
    add     rsi, rax
    lea     rdx, [rsi+16]
    xchg    rsi, rdx
    lea     rdi, [rsp]
    call    vsub
    lea     rdi, [rsp]
    call    vlen
    mov     ecx, [rsp+16]
    lea     rax, [rip+ik_l]
    movss   [rax+rcx*4], xmm0
    inc     ecx
    jmp     8b
81: lea     rsi, [rip+ik_o]
    lea     rdi, [rip+ik_p]
    lea     ecx, [r14+1]
    shl     ecx, 4
    rep     movsb
    mov     eax, r14d
    add     rsp, 24
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ik_solve_rec(r13=record) - ik_p reaches for ik_tgt: the solver, the pole,
#   the influence
ik_solve_rec:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     ebx, [r13+CN_ITER]
    test    ebx, ebx
    jnz     1f
    mov     ebx, 20
1:  mov     edi, ebx
    cmp     dword ptr [r13+CN_TRACK], 1
    je      2f
    call    ik_fabrik
    jmp     3f
2:  call    ik_ccd
3:  mov     edi, [r13+CN_POLE]
    test    edi, edi
    jz      4f
    call    obj_by_uid
    test    rax, rax
    jz      4f
    lea     rdi, [rip+ik_ai]
    lea     rsi, [rax+OB_LOC]
    lea     rdx, [rip+ik_pole]
    call    xform_point
    call    ik_pole_turn
4:  movss   xmm1, [r13+CN_INFL]         # ik_o + (ik_p - ik_o) influence
    comiss  xmm1, [rip+rf_one]
    jae     9f
    mov     ecx, [rip+ik_n]
    inc     ecx
    shl     ecx, 2
    xor     edx, edx
5:  cmp     edx, ecx
    jae     9f
    lea     r8, [rip+ik_p]
    lea     r9, [rip+ik_o]
    movss   xmm0, [r8+rdx*4]
    subss   xmm0, [r9+rdx*4]
    mulss   xmm0, xmm1
    addss   xmm0, [r9+rdx*4]
    movss   [r8+rdx*4], xmm0
    inc     edx
    jmp     5b
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# IKJ reg, joint - reg = &ik_p[joint] (r15 = ik_p)
.macro IKJ reg, idx
    imul    \reg, \idx, 16
    add     \reg, r15
.endm

# ik_fabrik(edi=iterations) - forwards and backwards reaching
ik_fabrik:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 48
    mov     r14d, edi
    lea     r15, [rip+ik_p]
    mov     r12d, [rip+ik_n]
    lea     rdi, [rsp]                  # out of reach: straight at it
    lea     rsi, [rip+ik_tgt]
    mov     rdx, r15
    call    vsub
    lea     rdi, [rsp]
    call    vnorm
    movss   [rsp+16], xmm0              # distance
    xorps   xmm1, xmm1
    xor     ecx, ecx
1:  cmp     ecx, r12d
    jae     2f
    lea     rax, [rip+ik_l]
    addss   xmm1, [rax+rcx*4]
    inc     ecx
    jmp     1b
2:  comiss  xmm1, [rsp+16]
    ja      4f
    xor     ebx, ebx
3:  cmp     ebx, r12d
    jae     9f
    IKJ     rsi, rbx
    lea     rdi, [rsi+16]
    lea     rdx, [rsp]
    lea     rax, [rip+ik_l]
    movss   xmm0, [rax+rbx*4]
    call    vaxpy
    inc     ebx
    jmp     3b
4:  mov     rsi, r15                    # the root stays
    lea     rdi, [rsp+32]
    call    vcopy
5:  test    r14d, r14d
    jz      9f
    dec     r14d
    IKJ     rdi, r12                    # backwards: the tip at the target
    lea     rsi, [rip+ik_tgt]
    call    vcopy
    lea     ebx, [r12-1]
6:  test    ebx, ebx
    js      7f
    IKJ     r13, rbx                    # p[i] = p[i+1] + l (p[i] - p[i+1])^
    lea     rdi, [rsp]
    mov     rsi, r13
    lea     rdx, [r13+16]
    call    vsub
    lea     rdi, [rsp]
    call    vnorm
    mov     rdi, r13
    lea     rsi, [r13+16]
    lea     rdx, [rsp]
    lea     rax, [rip+ik_l]
    movss   xmm0, [rax+rbx*4]
    call    vaxpy
    dec     ebx
    jmp     6b
7:  mov     rdi, r15                    # forwards: the root back
    lea     rsi, [rsp+32]
    call    vcopy
    xor     ebx, ebx
8:  cmp     ebx, r12d
    jae     81f
    IKJ     r13, rbx                    # p[i+1] = p[i] + l (p[i+1] - p[i])^
    lea     rdi, [rsp]
    lea     rsi, [r13+16]
    mov     rdx, r13
    call    vsub
    lea     rdi, [rsp]
    call    vnorm
    lea     rdi, [r13+16]
    mov     rsi, r13
    lea     rdx, [rsp]
    lea     rax, [rip+ik_l]
    movss   xmm0, [rax+rbx*4]
    call    vaxpy
    inc     ebx
    jmp     8b
81: IKJ     rsi, r12                    # close enough?
    lea     rdi, [rsp]
    lea     rdx, [rip+ik_tgt]
    call    vsub
    lea     rdi, [rsp]
    call    vlen
    comiss  xmm0, [rip+rf_tol]
    ja      5b
9:  add     rsp, 48
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ik_ccd(edi=iterations) - cyclic coordinate descent: each joint, tip to
#   root, turns the rest of the chain to point the tip at the target
ik_ccd:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 112
    mov     r14d, edi
    lea     r15, [rip+ik_p]
    mov     r12d, [rip+ik_n]
1:  test    r14d, r14d
    jz      9f
    dec     r14d
    lea     ebx, [r12-1]
2:  test    ebx, ebx
    js      6f
    IKJ     r13, rbx
    IKJ     rsi, r12                    # a = tip - p[i], b = target - p[i]
    lea     rdi, [rsp]
    mov     rdx, r13
    call    vsub
    lea     rdi, [rsp]
    call    vnorm
    lea     rdi, [rsp+16]
    lea     rsi, [rip+ik_tgt]
    mov     rdx, r13
    call    vsub
    lea     rdi, [rsp+16]
    call    vnorm
    lea     rdi, [rsp+48]
    lea     rsi, [rsp]
    lea     rdx, [rsp+16]
    call    rot_ab
    lea     ecx, [rbx+1]                # p[j] = p[i] + R (p[j] - p[i])
3:  cmp     ecx, r12d
    ja      5f
    mov     [rsp+32], ecx
    IKJ     rsi, rcx
    lea     rdi, [rsp]
    mov     rdx, r13
    call    vsub
    lea     rdi, [rsp+48]
    lea     rsi, [rsp]
    lea     rdx, [rsp+16]
    call    xform_point
    mov     ecx, [rsp+32]
    IKJ     rdi, rcx
    mov     rsi, r13
    lea     rdx, [rsp+16]
    movss   xmm0, [rip+rf_one]
    call    vaxpy
    mov     ecx, [rsp+32]
    inc     ecx
    jmp     3b
5:  dec     ebx
    jmp     2b
6:  IKJ     rsi, r12
    lea     rdi, [rsp]
    lea     rdx, [rip+ik_tgt]
    call    vsub
    lea     rdi, [rsp]
    call    vlen
    comiss  xmm0, [rip+rf_tol]
    ja      1b
9:  add     rsp, 112
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ik_pole_turn - the chain's inner joints turn about the root-to-tip line,
#   the first towards ik_pole (lengths and ends stay)
ik_pole_turn:
    push    rbx
    push    r12
    push    r15
    sub     rsp, 112
    lea     r15, [rip+ik_p]
    mov     r12d, [rip+ik_n]
    cmp     r12d, 2
    jb      9f
    IKJ     rsi, r12                    # k = (tip - root)^
    lea     rdi, [rsp]
    mov     rdx, r15
    call    vsub
    lea     rdi, [rsp]
    call    vnorm
    comiss  xmm0, [rip+rf_tiny]
    jbe     9f
    lea     rdi, [rsp+16]               # v = p1 - root, square to k
    lea     rsi, [r15+16]
    mov     rdx, r15
    call    vsub
    lea     rdi, [rsp+16]
    call    ik_flat
    jbe     9f
    lea     rdi, [rsp+32]               # w = pole - root, square to k
    lea     rsi, [rip+ik_pole]
    mov     rdx, r15
    call    vsub
    lea     rdi, [rsp+32]
    call    ik_flat
    jbe     9f
    lea     rdi, [rsp+48]               # angle = atan2(k . (v x w), v . w)
    lea     rsi, [rsp+16]
    lea     rdx, [rsp+32]
    call    vcross
    lea     rdi, [rsp]
    lea     rsi, [rsp+48]
    call    vdot
    movss   [rsp+100], xmm0
    lea     rdi, [rsp+16]
    lea     rsi, [rsp+32]
    call    vdot
    movss   xmm1, xmm0
    movss   xmm0, [rsp+100]
    call    at2f
    lea     rdi, [rsp+48]
    lea     rsi, [rsp]
    call    rot_axis
    mov     ebx, 1
1:  cmp     ebx, r12d
    jae     9f
    IKJ     rsi, rbx
    lea     rdi, [rsp+16]
    mov     rdx, r15
    call    vsub
    lea     rdi, [rsp+48]
    lea     rsi, [rsp+16]
    lea     rdx, [rsp+32]
    call    xform_point
    IKJ     rdi, rbx
    mov     rsi, r15
    lea     rdx, [rsp+32]
    movss   xmm0, [rip+rf_one]
    call    vaxpy
    inc     ebx
    jmp     1b
9:  add     rsp, 112
    pop     r15
    pop     r12
    pop     rbx
    ret
# ik_flat(rdi=v; [rsp+8] = unit k of the caller) - v minus its part along
#   k, made unit -> flags: above when it had a length
ik_flat:
    push    rbx
    mov     rbx, rdi
    lea     rsi, [rsp+16]               # (the caller's k at its rsp)
    call    vdot
    xorps   xmm1, xmm1
    subss   xmm1, xmm0
    movss   xmm0, xmm1
    mov     rdi, rbx
    mov     rsi, rbx
    lea     rdx, [rsp+16]
    call    vaxpy
    mov     rdi, rbx
    call    vnorm
    comiss  xmm0, [rip+rf_tiny]
    pop     rbx
    ret
# at2f(xmm0=y, xmm1=x) -> xmm0 = atan2(y, x)
at2f:
    sub     rsp, 8
    movss   [rsp], xmm0
    movss   [rsp+4], xmm1
    fld     dword ptr [rsp]
    fld     dword ptr [rsp+4]
    fpatan
    fstp    dword ptr [rsp]
    movss   xmm0, [rsp]
    add     rsp, 8
    ret

# ik_pose(rdi=bones) - the chain's bones turned onto the solved joints: each
#   M' = [Q M | p], Q from its posed direction to its solved one; the pose
#   that makes it (P = R^-1 R(parent) M'(parent)^-1 M') into am_ov
ik_pose:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    mov     rbx, rdi
    lea     r15, [rip+ik_p]
    xor     r12d, r12d
1:  cmp     r12d, [rip+ik_n]
    jae     9f
    lea     rax, [rip+ik_b]
    mov     r13d, [rax+r12*4]           # the bone
    imul    r14, r13, 48
    imul    rdx, r12, 16                # directions: posed,
    lea     rax, [rip+ik_o]
    add     rdx, rax
    lea     rsi, [rdx+16]
    lea     rdi, [rip+ik_d0]
    call    vsub
    lea     rdi, [rip+ik_d0]
    call    vnorm
    IKJ     rdx, r12                    #  solved
    lea     rsi, [rdx+16]
    lea     rdi, [rip+ik_d1]
    call    vsub
    lea     rdi, [rip+ik_d1]
    call    vnorm
    lea     rdi, [rip+ik_q]
    lea     rsi, [rip+ik_d0]
    lea     rdx, [rip+ik_d1]
    call    rot_ab
    lea     rsi, [rip+am_m]             # M without its translation
    add     rsi, r14
    lea     rdi, [rip+ik_mo]
    mov     ecx, 48
    rep     movsb
    mov     dword ptr [rip+ik_mo+12], 0
    mov     dword ptr [rip+ik_mo+28], 0
    mov     dword ptr [rip+ik_mo+44], 0
    lea     rdi, [rip+ik_mn]
    lea     rsi, [rip+ik_q]
    lea     rdx, [rip+ik_mo]
    call    m_mul
    IKJ     rax, r12                    # at the solved joint
    mov     ecx, [rax]
    mov     [rip+ik_mn+12], ecx
    mov     ecx, [rax+4]
    mov     [rip+ik_mn+28], ecx
    mov     ecx, [rax+8]
    mov     [rip+ik_mn+44], ecx
    mov     rdi, rbx
    mov     esi, r13d
    call    arm_bone
    mov     eax, [rax+BN_PARENT]
    test    eax, eax
    js      2f
    imul    rax, rax, 48
    mov     [rsp], rax
    lea     rsi, [rip+am_m]
    add     rsi, rax
    lea     rdi, [rip+ik_t1]            # M'(parent)^-1
    call    m_inv
    mov     rax, [rsp]
    lea     rsi, [rip+am_r]
    add     rsi, rax
    lea     rdi, [rip+ik_t2]
    lea     rdx, [rip+ik_t1]
    call    m_mul
    lea     rdi, [rip+ik_t3]
    lea     rsi, [rip+ik_t2]
    lea     rdx, [rip+ik_mn]
    call    m_mul
    jmp     3f
2:  lea     rsi, [rip+ik_mn]
    lea     rdi, [rip+ik_t3]
    mov     ecx, 48
    rep     movsb
3:  lea     rsi, [rip+am_r]             # R^-1 (...)
    add     rsi, r14
    lea     rdi, [rip+ik_t1]
    call    m_inv
    lea     rdi, [rip+am_ov]
    add     rdi, r14
    lea     rsi, [rip+ik_t1]
    lea     rdx, [rip+ik_t3]
    call    m_mul
    lea     rax, [rip+am_ovf]
    mov     byte ptr [rax+r13], 1
    lea     rsi, [rip+ik_mn]            # the children see it
    lea     rdi, [rip+am_m]
    add     rdi, r14
    mov     ecx, 48
    rep     movsb
    inc     r12d
    jmp     1b
9:  add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Operators
# =============================================================================
OPERATOR op_cn_add,  "constraint.add",    "Add Constraint",    do_cn_add, flags=OPF_AI_SAFE|OPF_UNDO, doc="Constrain an object (or, for ik, a bone): constraint.add <object|armature:bone> <copy_location|copy_rotation|copy_scale|track_to|limit_location|limit_rotation|limit_scale|child_of|ik> [target] [axes xyz] [offset] [influence f] [min x y z] [max x y z] [track x|y|z|-x|-y|-z] [up x|y|z] [chain n] [pole object] [solver fabrik|ccd] [iterations n] (limit_rotation in degrees)"
OPERATOR op_cn_rem,  "constraint.remove", "Remove Constraint", do_cn_rem, flags=OPF_AI_SAFE|OPF_UNDO, doc="Remove a constraint by number (1.., as constraint.list shows) or all of an object's: constraint.remove <n|object>"
OPERATOR op_cn_set,  "constraint.set",    "Set Constraint",    do_cn_set, flags=OPF_AI_SAFE|OPF_UNDO, doc="Change a constraint (1..): constraint.set <n> <influence|mute> <value>"
OPERATOR op_cn_list, "constraint.list",   "List Constraints",  do_cn_list, flags=OPF_AI_SAFE|OPF_QUIET, doc="The constraints and drivers, in the console"
OPERATOR op_dr_add,  "anim.driver",       "Add Driver",        do_dr_add, flags=OPF_AI_SAFE|OPF_UNDO, doc="Drive a property by an expression of others: anim.driver <path> [name=path ...] <expression> (names: up to 8 letters; frame is the frame), e.g. anim.driver Door:ry a=Handle:rz a*2"
OPERATOR op_dr_rem,  "anim.driver_remove", "Remove Driver",    do_dr_rem, flags=OPF_AI_SAFE|OPF_UNDO, doc="Remove a property's driver: anim.driver_remove <path>"
OPERATOR op_mpath,   "anim.motion_paths", "Motion Paths",      do_mpath, flags=OPF_AI_SAFE, doc="Show the selected objects' (pose mode: bones') paths over the frame range: anim.motion_paths [start end] | clear"
OPERATOR op_onion,   "anim.onion",        "Onion Skins",       do_onion, flags=OPF_AI_SAFE, doc="Ghosts of the active object some frames before (red) and after (green): anim.onion [before after step] | off"

.section .rodata
ct_names:       .quad k_none, k_copyloc, k_copyrot, k_copyscl, k_track, k_limloc, k_limrot, k_limscl, k_child, k_ik, 0
k_none:         .asciz "-"
k_copyloc:      .asciz "copy_location"
k_copyrot:      .asciz "copy_rotation"
k_copyscl:      .asciz "copy_scale"
k_track:        .asciz "track_to"
k_limloc:       .asciz "limit_location"
k_limrot:       .asciz "limit_rotation"
k_limscl:       .asciz "limit_scale"
k_child:        .asciz "child_of"
k_ik:           .asciz "ik"
cn_keys:        .quad kk_axes, kk_offset, kk_infl, kk_min, kk_max, kk_track, kk_up, kk_chain, kk_pole, kk_solver, kk_iter, 0
kk_axes:        .asciz "axes"
kk_offset:      .asciz "offset"
kk_infl:        .asciz "influence"
kk_min:         .asciz "min"
kk_max:         .asciz "max"
kk_track:       .asciz "track"
kk_up:          .asciz "up"
kk_chain:       .asciz "chain"
kk_pole:        .asciz "pole"
kk_solver:      .asciz "solver"
kk_iter:        .asciz "iterations"
kk_mute:        .asciz "mute"
axis_names:     .quad ka_x, ka_y, ka_z, ka_nx, ka_ny, ka_nz, 0
ka_x:           .asciz "x"
ka_y:           .asciz "y"
ka_z:           .asciz "z"
ka_nx:          .asciz "-x"
ka_ny:          .asciz "-y"
ka_nz:          .asciz "-z"
k_ccd:          .asciz "ccd"
k_clear:        .asciz "clear"
k_off:          .asciz "off"
s_cn_bad:       .asciz "  constraint.add <object|armature:bone> <type> [target] [options] - not understood: "
s_cn_notgt:     .asciz "  that constraint needs a target object"
s_cn_bone:      .asciz "  only ik works on a bone (armature:bone), and ik only on one"
s_cn_full:      .asciz "  no room for more constraints / drivers"
s_cn_none:      .asciz "  no such constraint: "
s_cn_added:     .asciz "  constraint "
s_cn_on:        .asciz " on "
s_cn_to:        .asciz " -> "
s_cn_muted:     .asciz " (muted)"
s_dr_bad:       .asciz "  anim.driver <path> [name=path ...] <expression> - not a property: "
s_dr_expr:      .asciz "  the driver's expression: "
s_dr:           .asciz "  driver "
s_dr_none:      .asciz "  no driver on "
s_mp_none:      .asciz "  select objects (or, in pose mode, bones) to show their paths"
s_mp:           .asciz "  motion paths: "
s_mp_frames:    .asciz " over frames "
s_on:           .asciz "  onion skins: "
s_on_off:       .asciz "  onion skins off"
.text

# rg_num(rsi=text) -> xmm0 = the next number, eax = 1 (0: none), rsi after
rg_num:
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

# rg_index(rdi=word, rsi=list of names) -> eax = its place, or -1
rg_index:
    push    rbx
    push    r12
    push    r13
    mov     r12, rdi
    mov     r13, rsi
    xor     ebx, ebx
1:  mov     rsi, [r13+rbx*8]
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
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# rg_obj(rdi=name) -> rax = the object, or 0
rg_obj:
    sub     rsp, 8
    call    obj_find
    test    eax, eax
    jz      9f
    mov     edi, eax
    call    obj_get
    add     rsp, 8
    ret
9:  xor     eax, eax
    add     rsp, 8
    ret

# constraint.add
do_cn_add:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    lea     rbx, [rip+cn_new]           # the record, built here
    mov     rdi, rbx
    xor     eax, eax
    mov     ecx, CN_SZ_
    rep     stosb
    mov     dword ptr [rbx+CN_BONE], -1
    mov     dword ptr [rbx+CN_AXES], 7
    mov     dword ptr [rbx+CN_TRACK], 5
    mov     dword ptr [rbx+CN_UP], 1
    mov     eax, [rip+rf_one]
    mov     [rbx+CN_INFL], eax
    mov     rsi, [rip+op_arg]
    call    im_next_word                # the owner: object or armature:bone
    test    eax, eax
    jz      .Lcn_bad
    mov     r12, rsi
    lea     rdi, [rip+im_word]          # (split at ':')
    xor     r13, r13
1:  mov     al, [rdi]
    test    al, al
    jz      2f
    cmp     al, ':'
    je      11f
    inc     rdi
    jmp     1b
11: mov     byte ptr [rdi], 0
    lea     r13, [rdi+1]
    lea     rsi, [rip+rg_word]
    xor     ecx, ecx
12: mov     al, [r13+rcx]
    mov     [rsi+rcx], al
    inc     ecx
    test    al, al
    jz      2f
    cmp     ecx, 63
    jb      12b
    mov     byte ptr [rsi+rcx], 0
2:  lea     rdi, [rip+im_word]
    call    rg_obj
    test    rax, rax
    jz      .Lcn_bad
    mov     r14, rax
    mov     eax, [r14+OB_UID]
    mov     [rbx+CN_OWNER], eax
    test    r13, r13
    jz      3f
    mov     rdi, r14                    # its bone
    call    arm_of
    test    rax, rax
    jz      .Lcn_bad
    mov     rdi, rax
    lea     rsi, [rip+rg_word]
    call    arm_find_bone
    test    eax, eax
    js      .Lcn_bad
    mov     [rbx+CN_BONE], eax
3:  mov     rsi, r12                    # the type
    call    im_next_word
    mov     r12, rsi
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+ct_names]
    call    rg_index
    test    eax, eax
    jle     .Lcn_bad
    mov     [rbx+CN_TYPE], eax
    cmp     eax, CT_IK                  # (ik: FABRIK unless a solver is named)
    jne     31f
    mov     dword ptr [rbx+CN_TRACK], 0
31: cmp     eax, CT_IK                  # ik: on a bone; the rest: not
    sete    al
    cmp     dword ptr [rbx+CN_BONE], 0
    setge   cl
    cmp     al, cl
    jne     .Lcn_bonebad
    mov     eax, [rbx+CN_TYPE]          # a target?
    cmp     eax, CT_LIMLOC
    jb      4f
    cmp     eax, CT_LIMSCL
    jbe     5f
4:  mov     rsi, r12
    call    im_next_word
    mov     r12, rsi
    lea     rdi, [rip+im_word]
    call    rg_obj
    test    rax, rax
    jz      .Lcn_notgt
    cmp     rax, r14
    je      .Lcn_notgt
    mov     ecx, [rax+OB_UID]
    mov     [rbx+CN_TARGET], ecx
    cmp     dword ptr [rbx+CN_TYPE], CT_CHILD
    jne     5f
    mov     rdi, rax                    # child of: the target's inverse now
    lea     rsi, [rip+rg_m]
    call    obj_matrix
    lea     rdi, [rbx+CN_INV]
    lea     rsi, [rip+rg_m]
    call    m_inv
5:  mov     rsi, r12                    # options
    call    im_next_word
    mov     r12, rsi
    test    eax, eax
    jz      .Lcn_store
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+cn_keys]
    call    rg_index
    test    eax, eax
    js      .Lcn_bad
    mov     r15d, eax
    mov     rsi, r12
    cmp     r15d, 0
    je      .Lco_axes
    cmp     r15d, 1
    je      .Lco_offset
    cmp     r15d, 2
    je      .Lco_infl
    cmp     r15d, 4
    jbe     .Lco_minmax
    cmp     r15d, 6
    jbe     .Lco_axis
    cmp     r15d, 7
    je      .Lco_chain
    cmp     r15d, 8
    je      .Lco_pole
    cmp     r15d, 9
    je      .Lco_solver
    jmp     .Lco_iter
.Lco_axes:
    call    im_next_word
    mov     r12, rsi
    xor     edx, edx
    lea     rdi, [rip+im_word]
6:  movzx   eax, byte ptr [rdi]
    test    eax, eax
    jz      61f
    sub     eax, 'x'
    cmp     eax, 3
    jae     .Lcn_bad
    bts     edx, eax
    inc     rdi
    jmp     6b
61: mov     [rbx+CN_AXES], edx
    jmp     5b
.Lco_offset:
    or      dword ptr [rbx+CN_FLAGS], CF_OFFSET
    jmp     5b
.Lco_infl:
    call    rg_num
    mov     r12, rsi
    test    eax, eax
    jz      .Lcn_bad
    maxss   xmm0, [rip+rf_zero]
    minss   xmm0, [rip+rf_one]
    movss   [rbx+CN_INFL], xmm0
    jmp     5b
.Lco_minmax:
    lea     r13, [rbx+CN_MIN]
    cmp     r15d, 3
    je      7f
    lea     r13, [rbx+CN_MAX]
7:  xor     r15d, r15d
71: mov     rsi, r12
    call    rg_num
    mov     r12, rsi
    test    eax, eax
    jz      .Lcn_bad
    cmp     dword ptr [rbx+CN_TYPE], CT_LIMROT
    jne     72f
    mulss   xmm0, [rip+rf_deg]
72: movss   [r13+r15*4], xmm0
    inc     r15d
    cmp     r15d, 3
    jb      71b
    jmp     5b
.Lco_axis:                              # track / up
    call    im_next_word
    mov     r12, rsi
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+axis_names]
    call    rg_index
    test    eax, eax
    js      .Lcn_bad
    cmp     r15d, 5
    jne     73f
    mov     [rbx+CN_TRACK], eax
    jmp     5b
73: cmp     eax, 3
    jae     .Lcn_bad
    mov     [rbx+CN_UP], eax
    jmp     5b
.Lco_chain:
    call    rg_num
    mov     r12, rsi
    test    eax, eax
    jz      .Lcn_bad
    cvttss2si eax, xmm0
    mov     [rbx+CN_CHAIN], eax
    jmp     5b
.Lco_iter:
    call    rg_num
    mov     r12, rsi
    test    eax, eax
    jz      .Lcn_bad
    cvttss2si eax, xmm0
    mov     [rbx+CN_ITER], eax
    jmp     5b
.Lco_pole:
    call    im_next_word
    mov     r12, rsi
    lea     rdi, [rip+im_word]
    call    rg_obj
    test    rax, rax
    jz      .Lcn_bad
    mov     eax, [rax+OB_UID]
    mov     [rbx+CN_POLE], eax
    jmp     5b
.Lco_solver:
    call    im_next_word
    mov     r12, rsi
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_ccd]
    call    str_eq
    mov     [rbx+CN_TRACK], eax
    jmp     5b
.Lcn_store:
    xor     edi, edi
    call    an_own_g
    test    rax, rax
    jz      .Lcn_full
    mov     r13, rax
    mov     ecx, [r13+AN_NCON_]
    cmp     ecx, CN_MAX_
    jae     .Lcn_full
    lea     eax, [rcx+1]
    mov     [r13+AN_NCON_], eax
    imul    rdi, rcx, CN_SZ_
    lea     rdi, [r13+AN_CON_+rdi]
    mov     rsi, rbx
    mov     ecx, CN_SZ_
    rep     movsb
    mov     esi, [r13+AN_NCON_]
    call    cn_log
    jmp     .Lcn_out
.Lcn_bonebad:
    lea     rdi, [rip+s_cn_bone]
    call    log_line
    call    undo_drop_last
    jmp     .Lcn_out
.Lcn_notgt:
    lea     rdi, [rip+s_cn_notgt]
    call    log_line
    call    undo_drop_last
    jmp     .Lcn_out
.Lcn_full:
    lea     rdi, [rip+s_cn_full]
    call    log_line
    call    undo_drop_last
    jmp     .Lcn_out
.Lcn_bad:
    lea     rdi, [rip+s_cn_bad]
    lea     rsi, [rip+im_word]
    call    log_pair
    call    undo_drop_last
.Lcn_out:
    add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# cn_log(esi=number 1..) - "  constraint 2: copy_location on Cube -> Target"
cn_log:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     r12d, esi
    mov     rbx, [rip+an_cur]
    lea     esi, [r12-1]
    call    cn_rec
    mov     rbx, rax
    call    fmt_reset
    lea     rdi, [rip+s_cn_added]
    call    fmt_str
    mov     edi, r12d
    call    fmt_int
    mov     edi, ':'
    call    fmt_char
    mov     edi, ' '
    call    fmt_char
    mov     eax, [rbx+CN_TYPE]
    cmp     eax, CT_IK
    ja      1f
    lea     rcx, [rip+ct_names]
    mov     rdi, [rcx+rax*8]
    call    fmt_str
1:  lea     rdi, [rip+s_cn_on]
    call    fmt_str
    mov     edi, [rbx+CN_OWNER]
    call    fmt_obj
    cmp     dword ptr [rbx+CN_BONE], 0
    jl      2f
    mov     edi, [rbx+CN_OWNER]
    call    obj_by_uid
    test    rax, rax
    jz      2f
    mov     rdi, rax
    call    arm_of
    test    rax, rax
    jz      2f
    mov     rdi, rax
    mov     esi, [rbx+CN_BONE]
    call    arm_bone
    push    rax
    mov     edi, ':'
    call    fmt_char
    pop     rdi
    call    fmt_str
2:  cmp     dword ptr [rbx+CN_TARGET], 0
    je      3f
    lea     rdi, [rip+s_cn_to]
    call    fmt_str
    mov     edi, [rbx+CN_TARGET]
    call    fmt_obj
3:  test    dword ptr [rbx+CN_FLAGS], CF_MUTE
    jz      4f
    lea     rdi, [rip+s_cn_muted]
    call    fmt_str
4:  lea     rdi, [rip+fmt_buf]
    call    log_line
    add     rsp, 8
    pop     r12
    pop     rbx
    ret
# fmt_obj(edi=uid) - its name (or ?)
fmt_obj:
    sub     rsp, 8
    call    obj_by_uid
    lea     rdi, [rip+k_none]
    test    rax, rax
    jz      1f
    lea     rdi, [rax+OB_NAME]
1:  call    fmt_str
    add     rsp, 8
    ret

# cn_unbase(rbx=block, esi=index) - before it goes: an owner's first live
#   constraint gives the object back its own transform
cn_unbase:
    sub     rsp, 8
    call    cn_rec
    test    dword ptr [rax+CN_FLAGS], CF_BASE
    jz      9f
    and     dword ptr [rax+CN_FLAGS], ~CF_BASE
    push    rax
    push    rax
    mov     edi, [rax+CN_OWNER]
    call    obj_by_uid
    pop     rsi
    pop     rsi
    test    rax, rax
    jz      9f
    lea     rdi, [rax+OB_LOC]
    add     rsi, CN_BASE
    mov     ecx, 36
    rep     movsb
9:  add     rsp, 8
    ret

# cn_delete(rbx=block, esi=index) - the record goes, the rest move down
cn_delete:
    push    r12
    mov     r12d, esi
    call    cn_unbase
    mov     esi, r12d
    call    cn_rec
    mov     rdi, rax
    lea     rsi, [rax+CN_SZ_]
    mov     ecx, [rbx+AN_NCON_]
    sub     ecx, r12d
    dec     ecx
    imul    ecx, ecx, CN_SZ_
    rep     movsb
    dec     dword ptr [rbx+AN_NCON_]
    pop     r12
    ret

# constraint.remove <n|object>
do_cn_rem:
    push    rbx
    push    r12
    push    r13
    xor     edi, edi
    call    an_own_g
    test    rax, rax
    jz      .Lcr_none
    mov     rbx, rax
    mov     rsi, [rip+op_arg]
    call    im_next_word
    test    eax, eax
    jz      .Lcr_none
    lea     rdi, [rip+im_word]
    call    rg_obj
    test    rax, rax
    jnz     3f
    lea     rsi, [rip+im_word]          # a number
    movzx   eax, byte ptr [rsi]
    sub     eax, '0'
    cmp     eax, 10
    jae     .Lcr_none
    mov     rsi, [rip+op_arg]
    call    rg_num
    cvttss2si eax, xmm0
    dec     eax
    cmp     eax, [rbx+AN_NCON_]
    jae     .Lcr_none
    mov     esi, eax
    call    cn_delete
    jmp     9f
3:  mov     r12d, [rax+OB_UID]          # all of an object's
    xor     r13d, r13d
    mov     ecx, [rbx+AN_NCON_]
    test    ecx, ecx
    jz      .Lcr_none
    dec     ecx
4:  test    ecx, ecx
    js      5f
    mov     esi, ecx
    push    rcx
    push    rcx
    call    cn_rec
    pop     rcx
    pop     rcx
    cmp     [rax+CN_OWNER], r12d
    jne     41f
    push    rcx
    push    rcx
    mov     esi, ecx
    call    cn_delete
    pop     rcx
    pop     rcx
    inc     r13d
41: dec     ecx
    jmp     4b
5:  test    r13d, r13d
    jnz     9f
.Lcr_none:
    lea     rdi, [rip+s_cn_none]
    lea     rsi, [rip+im_word]
    call    log_pair
    call    undo_drop_last
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# constraint.set <n> <influence|mute> <value>
do_cn_set:
    push    rbx
    push    r12
    push    r13
    xor     edi, edi
    call    an_own_g
    test    rax, rax
    jz      .Lcs_bad
    mov     rbx, rax
    mov     rsi, [rip+op_arg]
    call    rg_num
    test    eax, eax
    jz      .Lcs_bad
    mov     r12, rsi
    cvttss2si eax, xmm0
    dec     eax
    cmp     eax, [rbx+AN_NCON_]
    jae     .Lcs_bad
    mov     esi, eax
    call    cn_rec
    mov     r13, rax
    mov     rsi, r12
    call    im_next_word
    mov     r12, rsi
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+kk_infl]
    call    str_eq
    test    eax, eax
    jz      2f
    mov     rsi, r12
    call    rg_num
    test    eax, eax
    jz      .Lcs_bad
    maxss   xmm0, [rip+rf_zero]
    minss   xmm0, [rip+rf_one]
    movss   [r13+CN_INFL], xmm0
    jmp     9f
2:  lea     rdi, [rip+im_word]
    lea     rsi, [rip+kk_mute]
    call    str_eq
    test    eax, eax
    jz      .Lcs_bad
    mov     rsi, r12
    call    rg_num
    test    eax, eax
    jz      .Lcs_bad
    and     dword ptr [r13+CN_FLAGS], ~CF_MUTE
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    je      9f
    mov     rax, r13                    # muted: the object its own again
    sub     rax, rbx
    sub     rax, AN_CON_
    xor     edx, edx
    mov     ecx, CN_SZ_
    div     rcx
    mov     esi, eax
    call    cn_unbase
    or      dword ptr [r13+CN_FLAGS], CF_MUTE
    jmp     9f
.Lcs_bad:
    lea     rdi, [rip+s_cn_none]
    lea     rsi, [rip+im_word]
    call    log_pair
    call    undo_drop_last
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# constraint.list
do_cn_list:
    push    rbx
    push    r12
    push    r13
    mov     rbx, [rip+an_cur]
    test    rbx, rbx
    jz      9f
    xor     r12d, r12d
1:  cmp     r12d, [rbx+AN_NCON_]
    jae     2f
    inc     r12d
    mov     esi, r12d
    call    cn_log
    jmp     1b
2:  xor     r12d, r12d
3:  cmp     r12d, [rbx+AN_NDRV_]
    jae     9f
    imul    r13, r12, DR_SZ_
    lea     r13, [rbx+AN_DRV_+r13]
    call    fmt_reset
    lea     rdi, [rip+s_dr]
    call    fmt_str
    lea     edi, [r12+1]
    call    fmt_int
    mov     edi, ':'
    call    fmt_char
    mov     edi, ' '
    call    fmt_char
    lea     rdi, [r13+DR_EXPR]
    call    fmt_str
    lea     rdi, [rip+fmt_buf]
    call    log_line
    inc     r12d
    jmp     3b
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# ---- drivers ---------------------------------------------------------------------
# dr_find(rbx=block) -> eax = the driver of the channel in ap_*, or -1
dr_find:
    xor     eax, eax
1:  cmp     eax, [rbx+AN_NDRV_]
    jae     8f
    imul    rcx, rax, DR_SZ_
    lea     rcx, [rbx+AN_DRV_+rcx]
    mov     edx, [rip+ap_kind]
    cmp     [rcx+DR_KIND], edx
    jne     2f
    mov     edx, [rip+ap_a]
    cmp     [rcx+DR_A], edx
    jne     2f
    mov     edx, [rip+ap_b]
    cmp     [rcx+DR_B], edx
    jne     2f
    mov     edx, [rip+ap_c]
    cmp     [rcx+DR_C], edx
    je      9f
2:  inc     eax
    jmp     1b
8:  mov     eax, -1
9:  ret

# anim.driver <path> [name=path ...] <expression>
do_dr_add:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    lea     r13, [rip+dr_new]
    mov     rdi, r13
    xor     eax, eax
    mov     ecx, DR_SZ_
    rep     stosb
    mov     rsi, [rip+op_arg]
    call    im_next_word
    test    eax, eax
    jz      .Ldr_bad
    mov     r12, rsi
    lea     rsi, [rip+im_word]
    call    an_path
    test    eax, eax
    jz      .Ldr_bad
    mov     eax, [rip+ap_kind]
    mov     [r13+DR_KIND], eax
    mov     eax, [rip+ap_a]
    mov     [r13+DR_A], eax
    mov     eax, [rip+ap_b]
    mov     [r13+DR_B], eax
    mov     eax, [rip+ap_c]
    mov     [r13+DR_C], eax
1:  mov     rsi, r12                    # variables: name=path
2:  cmp     byte ptr [rsi], ' '
    jne     3f
    inc     rsi
    jmp     2b
3:  mov     r12, rsi                    # (the expression, if not one)
    call    im_next_word
    mov     r14, rsi
    test    eax, eax
    jz      .Ldr_bad
    lea     rdi, [rip+im_word]          # a name of 1-8 letters, then '='
    xor     ecx, ecx
4:  movzx   eax, byte ptr [rdi+rcx]
    cmp     eax, '='
    je      5f
    mov     edx, eax
    or      edx, 0x20
    sub     edx, 'a'
    cmp     edx, 26
    jb      41f
    cmp     eax, '_'
    je      41f
    test    ecx, ecx
    jz      .Ldr_expr
    sub     eax, '0'
    cmp     eax, 10
    jae     .Ldr_expr
41: inc     ecx
    cmp     ecx, 8
    jbe     4b
    jmp     .Ldr_expr
5:  test    ecx, ecx
    jz      .Ldr_expr
    mov     eax, [r13+DR_NV]
    cmp     eax, DR_MAXV
    jae     .Ldr_bad
    imul    r15, rax, 24
    lea     r15, [r13+DR_VARS+r15]
    mov     qword ptr [r15], 0
    xor     edx, edx
51: cmp     edx, ecx
    jae     52f
    mov     al, [rdi+rdx]
    mov     [r15+rdx], al
    inc     edx
    jmp     51b
52: lea     rsi, [rdi+rcx+1]            # its path
    call    an_path
    test    eax, eax
    jz      .Ldr_bad
    mov     eax, [rip+ap_kind]
    mov     [r15+8], eax
    mov     eax, [rip+ap_a]
    mov     [r15+12], eax
    mov     eax, [rip+ap_b]
    mov     [r15+16], eax
    mov     eax, [rip+ap_c]
    mov     [r15+20], eax
    inc     dword ptr [r13+DR_NV]
    mov     r12, r14
    jmp     1b
.Ldr_expr:                              # the rest is the expression
    lea     rdi, [r13+DR_EXPR]
    mov     rsi, r12
    xor     ecx, ecx
6:  mov     al, [rsi+rcx]
    mov     [rdi+rcx], al
    test    al, al
    jz      61f
    inc     ecx
    cmp     ecx, DR_EXPRSZ-1
    jb      6b
    mov     byte ptr [rdi+rcx], 0
61: mov     [rip+dr_cur], r13           # it must evaluate
    lea     rax, [rip+dr_name]
    mov     [rip+expr_name_hook], rax
    lea     rdi, [r13+DR_EXPR]
    call    expr_eval
    mov     qword ptr [rip+expr_name_hook], 0
    test    eax, eax
    jz      .Ldr_experr
    mov     eax, [r13+DR_KIND]          # (its target again, for dr_find)
    mov     [rip+ap_kind], eax
    mov     eax, [r13+DR_A]
    mov     [rip+ap_a], eax
    mov     eax, [r13+DR_B]
    mov     [rip+ap_b], eax
    mov     eax, [r13+DR_C]
    mov     [rip+ap_c], eax
    xor     edi, edi
    call    an_own_g
    test    rax, rax
    jz      .Ldr_full
    mov     rbx, rax
    call    dr_find                     # (a channel has one driver)
    test    eax, eax
    jns     7f
    mov     eax, [rbx+AN_NDRV_]
    cmp     eax, DR_MAX_
    jae     .Ldr_full
    inc     dword ptr [rbx+AN_NDRV_]
7:  imul    rdi, rax, DR_SZ_
    lea     rdi, [rbx+AN_DRV_+rdi]
    mov     rsi, r13
    mov     ecx, DR_SZ_
    rep     movsb
    jmp     .Ldr_out
.Ldr_experr:
    lea     rdi, [rip+s_dr_expr]
    mov     rsi, [rip+expr_err]
    test    rsi, rsi
    jnz     8f
    lea     rsi, [rip+k_none]
8:  call    log_pair
    call    undo_drop_last
    jmp     .Ldr_out
.Ldr_full:
    lea     rdi, [rip+s_cn_full]
    call    log_line
    call    undo_drop_last
    jmp     .Ldr_out
.Ldr_bad:
    lea     rdi, [rip+s_dr_bad]
    lea     rsi, [rip+im_word]
    call    log_pair
    call    undo_drop_last
.Ldr_out:
    add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# anim.driver_remove <path>
do_dr_rem:
    push    rbx
    mov     rsi, [rip+op_arg]
    call    im_next_word
    lea     rsi, [rip+im_word]
    call    an_path
    test    eax, eax
    jz      8f
    xor     edi, edi
    call    an_own_g
    test    rax, rax
    jz      8f
    mov     rbx, rax
    call    dr_find
    test    eax, eax
    js      8f
    imul    rdi, rax, DR_SZ_
    lea     rdi, [rbx+AN_DRV_+rdi]
    lea     rsi, [rdi+DR_SZ_]
    mov     ecx, [rbx+AN_NDRV_]
    sub     ecx, eax
    dec     ecx
    imul    ecx, ecx, DR_SZ_
    rep     movsb
    dec     dword ptr [rbx+AN_NDRV_]
    jmp     9f
8:  lea     rdi, [rip+s_dr_none]
    lea     rsi, [rip+im_word]
    call    log_pair
    call    undo_drop_last
9:  pop     rbx
    ret

# =============================================================================
#  Motion paths, onion skins
# =============================================================================
.equ AN_CUR_,   64
.equ CU_SZ_,    32
.equ AN_NCUR_,  4
.equ KY_SZ_,    32

# mp_haskey(edi=kind, esi=a, edx=b (-1: any), xmm0=frame) -> eax = 1 when a
#   curve of the scene's on that channel has a key there
mp_haskey:
    mov     r8, [rip+an_cur]
    test    r8, r8
    jz      8f
    xor     ecx, ecx
1:  cmp     ecx, [r8+AN_NCUR_]
    jae     8f
    imul    r9, rcx, CU_SZ_
    lea     r9, [r8+AN_CUR_+r9]
    cmp     dword ptr [r9+24], 0        # (an action's: no)
    jne     5f
    cmp     [r9], edi
    jne     5f
    cmp     [r9+4], esi
    jne     5f
    cmp     edx, -1
    je      2f
    cmp     [r9+8], edx
    jne     5f
2:  mov     r10d, [r9+16]               # its keys
    mov     r11d, [r9+20]
3:  test    r11d, r11d
    jz      5f
    imul    rax, r10, KY_SZ_
    lea     rax, [r8+AN_RIGEND_+rax]
    movss   xmm1, [rax]
    subss   xmm1, xmm0
    andps   xmm1, [rip+rf_absm]
    comiss  xmm1, [rip+rf_half]
    jb      9f
    inc     r10d
    dec     r11d
    jmp     3b
5:  inc     ecx
    jmp     1b
8:  xor     eax, eax
    ret
9:  mov     eax, 1
    ret

# mp_point(edi=path, rsi=out) - where the path's object (or bone tail) is
mp_point:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 64
    mov     r12, rsi
    lea     rax, [rip+mp_who]
    mov     r13d, [rax+rdi*8+4]         # bone
    mov     edi, [rax+rdi*8]
    call    obj_by_uid
    test    rax, rax
    jz      8f
    mov     rbx, rax
    test    r13d, r13d
    jns     1f
    mov     rdi, r12
    lea     rsi, [rbx+OB_LOC]
    call    vcopy
    jmp     9f
1:  mov     rdi, rbx
    mov     esi, r13d
    mov     rdx, r12
    call    bone_tail
    jmp     9f
8:  xorps   xmm0, xmm0
    movss   [r12], xmm0
    movss   [r12+4], xmm0
    movss   [r12+8], xmm0
9:  add     rsp, 64
    pop     r13
    pop     r12
    pop     rbx
    ret

# bone_tail(rdi=armature object, esi=bone, rdx=out) - where its tail is
#   posed (IK too), in the world: A M (0 len 0)
bone_tail:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 64
    mov     rbx, rdi
    mov     r13d, esi
    mov     r12, rdx
    mov     rdi, rbx
    call    arm_of
    test    rax, rax
    jz      8f
    cmp     r13d, [rax+AR_N]
    jae     8f
    push    rax
    push    rax
    mov     [rip+am_owner], rbx
    mov     rdi, rax
    call    arm_pose_mats
    pop     rdi
    pop     rdi
    mov     esi, r13d
    call    arm_bone
    lea     rdi, [rsp]
    lea     rsi, [rax+BN_TAIL]
    lea     rdx, [rax+BN_HEAD]
    call    vsub
    lea     rdi, [rsp]
    call    vlen
    xorps   xmm1, xmm1
    movss   [rsp], xmm1
    movss   [rsp+4], xmm0
    movss   [rsp+8], xmm1
    imul    rdi, r13, 48
    lea     rax, [rip+am_m]
    add     rdi, rax
    lea     rsi, [rsp]
    lea     rdx, [rsp+16]
    call    xform_point
    mov     rdi, rbx
    lea     rsi, [rip+rg_m]
    call    obj_matrix
    lea     rdi, [rip+rg_m]
    lea     rsi, [rsp+16]
    mov     rdx, r12
    call    xform_point
    jmp     9f
8:  xorps   xmm0, xmm0
    movss   [r12], xmm0
    movss   [r12+4], xmm0
    movss   [r12+8], xmm0
9:  add     rsp, 64
    pop     r13
    pop     r12
    pop     rbx
    ret

# anim.motion_paths [start end] | clear
do_mpath:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    mov     dword ptr [rip+mp_n], 0
    mov     rsi, [rip+op_arg]
    call    im_next_word
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_clear]
    call    str_eq
    test    eax, eax
    jnz     .Lmp_out
    xor     r12d, r12d                  # who: pose mode's selected bones,
    cmp     dword ptr [rip+arm_mode], 2
    jne     3f
    mov     rbx, [rip+arm_obj]
    test    rbx, rbx
    jz      3f
    mov     rdi, rbx
    call    arm_of
    test    rax, rax
    jz      3f
    mov     r13, rax
    xor     r14d, r14d
1:  cmp     r14d, [r13+AR_N]
    jae     5f
    cmp     r12d, MP_MAX
    jae     5f
    mov     rdi, r13
    mov     esi, r14d
    call    arm_bone
    test    byte ptr [rax+BN_SEL], 4
    jz      2f
    lea     rax, [rip+mp_who]
    mov     ecx, [rbx+OB_UID]
    mov     [rax+r12*8], ecx
    mov     [rax+r12*8+4], r14d
    inc     r12d
2:  inc     r14d
    jmp     1b
3:  xor     r14d, r14d                  #  or the selected objects
4:  cmp     r14d, [rip+obj_count]
    jae     5f
    cmp     r12d, MP_MAX
    jae     5f
    mov     edi, r14d
    call    obj_at
    test    dword ptr [rax+OB_FLAGS], OBF_SELECTED
    jz      41f
    lea     rcx, [rip+mp_who]
    mov     edx, [rax+OB_UID]
    mov     [rcx+r12*8], edx
    mov     dword ptr [rcx+r12*8+4], -1
    inc     r12d
41: inc     r14d
    jmp     4b
5:  test    r12d, r12d
    jz      .Lmp_none
    mov     [rip+mp_n], r12d
    call    an_range                    # frames: the range, or given
    mov     [rsp], eax
    mov     [rsp+4], edx
    mov     rsi, [rip+op_arg]
    call    rg_num
    test    eax, eax
    jz      6f
    cvttss2si eax, xmm0
    mov     [rsp], eax
    call    rg_num
    test    eax, eax
    jz      6f
    cvttss2si eax, xmm0
    mov     [rsp+4], eax
6:  mov     eax, [rsp]
    mov     [rip+mp_f0], eax
    mov     ecx, [rsp+4]
    sub     ecx, eax
    inc     ecx
    cmp     ecx, 2
    jge     61f
    mov     ecx, 2
61: cmp     ecx, MP_MAXF
    jbe     62f
    mov     ecx, MP_MAXF
62: mov     [rip+mp_nf], ecx
    mov     eax, [rip+an_frame]         # each frame, then back
    mov     [rsp+8], eax
    xor     r13d, r13d
7:  cmp     r13d, [rip+mp_nf]
    jae     8f
    mov     eax, [rip+mp_f0]
    add     eax, r13d
    cvtsi2ss xmm0, eax
    call    an_apply
    call    rig_eval
    xor     r14d, r14d
71: cmp     r14d, [rip+mp_n]
    jae     72f
    imul    eax, r14d, MP_MAXF
    add     eax, r13d
    mov     r15d, eax
    imul    rsi, r15, 12
    lea     rax, [rip+mp_pts]
    add     rsi, rax
    mov     edi, r14d
    call    mp_point
    lea     rax, [rip+mp_who]           # keyed there?
    mov     esi, [rax+r14*8]
    mov     edx, [rax+r14*8+4]
    mov     edi, K_OBJ_
    test    edx, edx
    js      711f
    mov     edi, K_BONE_
711:mov     eax, [rip+mp_f0]
    add     eax, r13d
    cvtsi2ss xmm0, eax
    call    mp_haskey
    lea     rcx, [rip+mp_key]
    mov     [rcx+r15], al
    inc     r14d
    jmp     71b
72: inc     r13d
    jmp     7b
8:  movss   xmm0, [rsp+8]
    call    an_apply
    call    fmt_reset
    lea     rdi, [rip+s_mp]
    call    fmt_str
    mov     edi, [rip+mp_n]
    call    fmt_int
    lea     rdi, [rip+s_mp_frames]
    call    fmt_str
    mov     edi, [rip+mp_f0]
    call    fmt_int
    mov     edi, '-'
    call    fmt_char
    mov     edi, [rip+mp_f0]
    add     edi, [rip+mp_nf]
    dec     edi
    call    fmt_int
    lea     rdi, [rip+fmt_buf]
    call    log_line
    jmp     .Lmp_out
.Lmp_none:
    lea     rdi, [rip+s_mp_none]
    call    log_line
.Lmp_out:
    mov     dword ptr [rip+dirty], 1
    add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# anim.onion [before after step] | off
do_onion:
    push    rbx
    sub     rsp, 16
    mov     rsi, [rip+op_arg]
    call    im_next_word
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_off]
    call    str_eq
    test    eax, eax
    jnz     8f
    mov     rsi, [rip+op_arg]
    call    rg_num
    test    eax, eax
    jz      2f
    mov     rbx, rsi
    cvttss2si eax, xmm0
    call    on_clamp
    mov     [rip+on_before], eax
    mov     [rip+on_after], eax
    mov     rsi, rbx
    call    rg_num
    test    eax, eax
    jz      2f
    mov     rbx, rsi
    cvttss2si eax, xmm0
    call    on_clamp
    mov     [rip+on_after], eax
    mov     rsi, rbx
    call    rg_num
    test    eax, eax
    jz      2f
    cvttss2si eax, xmm0
    cmp     eax, 1
    jge     1f
    mov     eax, 1
1:  mov     [rip+on_step], eax
2:  mov     dword ptr [rip+on_on], 1
    mov     qword ptr [rip+on_obj], 0   # (made again)
    call    fmt_reset
    lea     rdi, [rip+s_on]
    call    fmt_str
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
    lea     rdi, [rip+fmt_buf]
    call    log_line
    jmp     9f
8:  mov     dword ptr [rip+on_on], 0
    call    on_free
    lea     rdi, [rip+s_on_off]
    call    log_line
9:  mov     dword ptr [rip+dirty], 1
    add     rsp, 16
    pop     rbx
    ret
on_clamp:
    test    eax, eax
    jns     1f
    xor     eax, eax
1:  cmp     eax, ON_MAX/2
    jbe     2f
    mov     eax, ON_MAX/2
2:  ret

# on_free - the ghosts go
on_free:
    push    rbx
    xor     ebx, ebx
1:  cmp     ebx, [rip+on_n]
    jae     2f
    lea     rax, [rip+on_mesh]
    mov     rdi, [rax+rbx*8]
    call    mesh_unref
    inc     ebx
    jmp     1b
2:  mov     dword ptr [rip+on_n], 0
    pop     rbx
    ret

# rig_tick - once a frame before drawing: rigging evaluated, the onion
#   skins made again when the object, the frame or the keys changed
rig_tick:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    call    rig_eval
    cmp     dword ptr [rip+on_on], 0
    je      9f
    xor     ebx, ebx
    mov     edi, [rip+active_obj]
    test    edi, edi
    jz      1f
    call    obj_get
    mov     rbx, rax
    test    rbx, rbx
    jz      1f
    cmp     qword ptr [rbx+OB_MESH], 0
    jne     2f
    xor     ebx, ebx
1:  mov     qword ptr [rip+on_obj], 0
    call    on_free
    jmp     9f
2:  cmp     rbx, [rip+on_obj]
    jne     3f
    mov     eax, [rip+an_frame]
    cmp     eax, [rip+on_frame]
    jne     3f
    mov     rax, [rip+an_cur]
    cmp     rax, [rip+on_anim]
    je      9f
3:  call    on_free
    mov     [rip+on_obj], rbx
    mov     eax, [rip+an_frame]
    mov     [rip+on_frame], eax
    mov     eax, [rip+dirty]
    mov     [rsp], eax
    mov     r12d, [rip+on_before]       # offsets -before .. -1, 1 .. after
    neg     r12d
4:  cmp     r12d, [rip+on_after]
    jg      8f
    test    r12d, r12d
    jz      7f
    mov     eax, r12d
    imul    eax, [rip+on_step]
    cvtsi2ss xmm0, eax
    addss   xmm0, [rip+on_frame]
    call    an_apply
    mov     rdi, rbx
    call    obj_eval
    test    rax, rax
    jz      7f
    mov     r13, rax
    mov     rdi, rax
    call    mesh_ref
    mov     r14d, [rip+on_n]
    lea     rax, [rip+on_mesh]
    mov     [rax+r14*8], r13
    lea     rax, [rip+on_off]
    mov     [rax+r14*4], r12d
    imul    rsi, r14, 48
    lea     rax, [rip+on_mat]
    add     rsi, rax
    mov     rdi, rbx
    call    obj_matrix
    inc     dword ptr [rip+on_n]
7:  inc     r12d
    jmp     4b
8:  movss   xmm0, [rip+on_frame]
    call    an_apply
    mov     rax, [rip+an_cur]
    mov     [rip+on_anim], rax
    mov     eax, [rsp]
    mov     [rip+dirty], eax
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# rig_draw - in the viewport: motion paths, onion skins
rig_draw:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 32
    xor     r12d, r12d                  # ---- the ghosts: wires
1:  cmp     r12d, [rip+on_n]
    jae     .Lrd_paths
    lea     rax, [rip+on_mesh]
    mov     rbx, [rax+r12*8]
    lea     rax, [rip+on_off]
    mov     eax, [rax+r12*4]
    mov     r15d, COL_GHOST_A           # after: green, before: red; fainter
    test    eax, eax                    #  further away
    jg      11f
    mov     r15d, COL_GHOST_B
    neg     eax
11: cmp     eax, 1
    je      12f
    shr     r15d, 1
    and     r15d, 0x7f7f7f
12: imul    r14, r12, 48
    lea     rax, [rip+on_mat]
    add     r14, rax
    mov     ecx, [rbx+ME_NEDGES]        # (a large mesh: some of its edges)
    mov     eax, ecx
    xor     edx, edx
    mov     r8d, 20000
    div     r8d
    inc     eax
    mov     [rsp+24], eax               # step
    xor     r13d, r13d
2:  cmp     r13d, [rbx+ME_NEDGES]
    jae     3f
    mov     rax, [rbx+ME_EDGES]
    mov     ecx, [rax+r13*8]
    imul    rsi, rcx, 12
    add     rsi, [rbx+ME_POS]
    mov     rdi, r14
    lea     rdx, [rip+lp0]
    call    xform_point
    mov     rax, [rbx+ME_EDGES]
    mov     ecx, [rax+r13*8+4]
    imul    rsi, rcx, 12
    add     rsi, [rbx+ME_POS]
    mov     rdi, r14
    lea     rdx, [rip+lp1]
    call    xform_point
    mov     edx, r15d
    call    line3d
    add     r13d, [rsp+24]
    jmp     2b
3:  inc     r12d
    jmp     1b
.Lrd_paths:                             # ---- motion paths
    xor     r12d, r12d
4:  cmp     r12d, [rip+mp_n]
    jae     9f
    imul    eax, r12d, MP_MAXF
    imul    rbx, rax, 12
    lea     rcx, [rip+mp_pts]
    add     rbx, rcx                    # its points
    lea     rcx, [rip+mp_key]
    lea     r15, [rcx+rax]              # its keys
    xor     r13d, r13d
5:  lea     eax, [r13+1]
    cmp     eax, [rip+mp_nf]
    jae     6f
    imul    rsi, r13, 12
    add     rsi, rbx
    lea     rdi, [rip+lp0]
    call    vcopy
    imul    rsi, r13, 12
    lea     rsi, [rbx+rsi+12]
    lea     rdi, [rip+lp1]
    call    vcopy
    mov     edx, COL_PATH
    call    line3d
    inc     r13d
    jmp     5b
6:  xor     r13d, r13d                  # a dot a frame (keys larger, the
61: cmp     r13d, [rip+mp_nf]           #  frame shown white)
    jae     8f
    imul    rdi, r13, 12
    add     rdi, rbx
    call    world_px
    xorps   xmm3, xmm3
    comiss  xmm2, xmm3
    jbe     7f
    mov     edx, COL_PATH
    mov     ecx, 3
    cmp     byte ptr [r15+r13], 0
    je      62f
    mov     edx, COL_PATH_KEY
    mov     ecx, 6
62: mov     eax, [rip+mp_f0]
    add     eax, r13d
    cvtsi2ss xmm4, eax
    ucomiss xmm4, [rip+an_frame]
    jne     63f
    mov     edx, 0xffffff
    mov     ecx, 7
63: call    dot
7:  inc     r13d
    jmp     61b
8:  inc     r12d
    jmp     4b
9:  add     rsp, 32
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.section .bss
.align 16
cn_new:         .skip CN_SZ_
dr_new:         .skip DR_SZ_
.text

.section .note.GNU-stack,"",@progbits
