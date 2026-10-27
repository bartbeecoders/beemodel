# =============================================================================
#  BeeModel - mechanisms: CAD assemblies that move.
#
#  A joint moves a part relative to its parent (another part, or the
#  world): revolute (turned about an axis through a pivot) or slider
#  (moved along an axis). Its value comes from an expression (CAD
#  parameters, units, "frame": "angle", "crank * 2", "frame * 3deg"), or is
#  another joint's times a ratio: gears (revolute from revolute, the ratio
#  -teeth1/teeth2) and racks (slider from revolute, the ratio the pitch
#  radius). Limits clamp it (and say so). Parameters are animation
#  channels ("param:angle"), so a keyed parameter moves the whole
#  mechanism, and the feature tree rebuilds with it.
#
#  The part as it is when the joint is made is where it is at 0 (its
#  parent's place then is kept too); later its place is the parent's
#  motion since, times the joint's. Joints are evaluated in order, so a
#  part's parent joint comes first. The records live in the animation
#  block (undo, files).
#
#  After the parts move, each moving part is checked against every other
#  mesh (up to 64; not the part it is joined to): a triangle edge of one
#  passing strictly through a triangle of the other (touching faces do not
#  count). A pair that starts colliding is reported in the console.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

.globl mech_eval
.globl mech_value
.globl mech_hits
.globl param_chan

.equ MJ_TYPE,   0                       # 1 revolute, 2 slider
.equ MJ_A,      4                       # the parent (object uid; 0: world)
.equ MJ_B,      8                       # the part
.equ MJ_FLAGS,  12                      # 1: limits
.equ MJ_PIV,    16
.equ MJ_AXIS,   28                      # (unit)
.equ MJ_MIN,    40
.equ MJ_MAX,    44
.equ MJ_RATIO,  48
.equ MJ_SRC,    52                      # driven by joint (1..; 0: its expression)
.equ MJ_VAL,    56                      # its value now
.equ MJ_LIM,    60                      # held at a limit now
.equ MJ_EXPR,   64
.equ MJ_EXPRSZ, 64
.equ MJ_BREST,  128                     # the part's place at 0 (loc rot scale)
.equ MJ_AREST,  164                     # its parent's then
.equ MC_MAXP,   64                      # parts checked
.equ MC_MAXHIT, 64

.section .rodata
.align 16
mx_one:         .float 1.0
mx_eps:         .float 1.0e-5
mx_tiny:        .float 1.0e-12
mx_half:        .float 0.5
mx_mill:        .double 1000000.0
mx_dhalf:       .double 0.5
s_rev:          .asciz "revolute"
s_slider:       .asciz "slider"
s_world:        .asciz "world"
k_pivot:        .asciz "pivot"
k_axis:         .asciz "axis"
k_value:        .asciz "value"
k_min:          .asciz "min"
k_max:          .asciz "max"
k_gear:         .asciz "gear"
k_free:         .asciz "nolimits"
s_mj_bad:       .asciz "  mech.joint <revolute|slider> <part> <parent|world> [pivot x y z] [axis x y z] [min e] [max e] [gear <joint> <ratio>] [value <expression>] - not understood: "
s_mj_full:      .asciz "  no room for more mechanism joints"
s_mj_none:      .asciz "  no such mechanism joint: "
s_mj_expr:      .asciz "  the joint's value: "
s_mj:           .asciz "  joint "
s_mj_lim:       .asciz " (at its limit)"
s_mj_from:      .asciz " = joint "
s_mj_x:         .asciz " x "
s_col:          .asciz "  collision: "
s_col_and:      .asciz " / "
s_col_none:     .asciz "  no collisions"
s_cols:         .asciz "  collisions: "
s_eq:           .asciz " = "
s_colon:        .asciz ": "
.align 8
type_names:     .quad s_rev, s_slider, 0

.section .bss
.align 16
mx_m:           .skip 64
mx_m2:          .skip 64
mx_m3:          .skip 64
mx_j:           .skip 64
mx_e:           .skip 48
mx_busy:        .skip 4
mech_hits:      .skip 4                 # colliding pairs now
mc_n:           .skip 4                 # the pairs that collided last
mc_pairs:       .skip 8*MC_MAXHIT
mc_parts:       .skip 4*MC_MAXP
mx_word:        .skip 128
mx_numbuf:      .skip 48
mj_new:         .skip MJ_SZ_
.text

# mj_rec(rbx=block, esi=index) -> rax
mj_rec:
    imul    rax, rsi, MJ_SZ_
    lea     rax, [rbx+AN_MJ_+rax]
    ret

# mj_name(rdi=name) -> eax = 1, xmm0 = "frame" (expr.s's hook)
mj_name:
    mov     rax, [rdi]
    cmp     qword ptr [rdi+8], 0
    jne     8f
    mov     rcx, 0x656d617266           # "frame"
    cmp     rax, rcx
    jne     8f
    cvtss2sd xmm0, [rip+an_frame]
    mov     eax, 1
    ret
8:  xor     eax, eax
    ret

# mj_expr(rdi=text) -> xmm0 (float), eax = 1 (0: it failed; empty: 0)
mj_expr:
    xorps   xmm0, xmm0
    mov     eax, 1
    cmp     byte ptr [rdi], 0
    je      9f
    push    rbx
    mov     rbx, [rip+expr_name_hook]
    lea     rax, [rip+mj_name]
    mov     [rip+expr_name_hook], rax
    call    expr_eval
    mov     [rip+expr_name_hook], rbx
    pop     rbx
    cvtsd2ss xmm0, xmm0
9:  ret

# mj_joint_mat(rdi=record, xmm0=value, rsi=out 3x4) - [R | p - R p] about
#   the axis through the pivot, or [I | axis v]
mj_joint_mat:
    push    rbx
    push    r12
    sub     rsp, 40
    mov     rbx, rdi
    mov     r12, rsi
    cmp     dword ptr [rbx+MJ_TYPE], 2
    jne     1f
    lea     rsi, [rip+mj_ident]         # slider
    mov     rdi, r12
    mov     ecx, 48
    rep     movsb
    xor     ecx, ecx
11: movss   xmm1, [rbx+MJ_AXIS+rcx*4]
    mulss   xmm1, xmm0
    imul    edx, ecx, 16
    movss   [r12+rdx+12], xmm1
    inc     ecx
    cmp     ecx, 3
    jb      11b
    jmp     9f
1:  call    sincos                      # R = c I + s [k]x + (1 - c) k k^T
    movss   [rsp], xmm0
    movss   [rsp+4], xmm1
    movss   xmm2, [rip+mx_one]
    subss   xmm2, xmm1
    movss   [rsp+8], xmm2
    xor     ecx, ecx
2:  xor     edx, edx
3:  movss   xmm0, [rbx+MJ_AXIS+rcx*4]
    mulss   xmm0, [rbx+MJ_AXIS+rdx*4]
    mulss   xmm0, [rsp+8]
    cmp     ecx, edx
    jne     4f
    addss   xmm0, [rsp+4]
4:  imul    r8d, ecx, 16
    lea     r8, [r12+r8]
    movss   [r8+rdx*4], xmm0
    inc     edx
    cmp     edx, 3
    jb      3b
    inc     ecx
    cmp     ecx, 3
    jb      2b
    movss   xmm3, [rsp]                 # + s [k]x
    movss   xmm0, [rbx+MJ_AXIS]
    mulss   xmm0, xmm3
    movss   xmm1, [rbx+MJ_AXIS+4]
    mulss   xmm1, xmm3
    movss   xmm2, [rbx+MJ_AXIS+8]
    mulss   xmm2, xmm3
    movss   xmm4, [r12+4]
    subss   xmm4, xmm2
    movss   [r12+4], xmm4
    movss   xmm4, [r12+8]
    addss   xmm4, xmm1
    movss   [r12+8], xmm4
    movss   xmm4, [r12+16]
    addss   xmm4, xmm2
    movss   [r12+16], xmm4
    movss   xmm4, [r12+24]
    subss   xmm4, xmm0
    movss   [r12+24], xmm4
    movss   xmm4, [r12+32]
    subss   xmm4, xmm1
    movss   [r12+32], xmm4
    movss   xmm4, [r12+36]
    addss   xmm4, xmm0
    movss   [r12+36], xmm4
    xor     ecx, ecx                    # t = p - R p
5:  imul    edx, ecx, 16
    movss   xmm0, [r12+rdx]
    mulss   xmm0, [rbx+MJ_PIV]
    movss   xmm1, [r12+rdx+4]
    mulss   xmm1, [rbx+MJ_PIV+4]
    addss   xmm0, xmm1
    movss   xmm1, [r12+rdx+8]
    mulss   xmm1, [rbx+MJ_PIV+8]
    addss   xmm0, xmm1
    movss   xmm1, [rbx+MJ_PIV+rcx*4]
    subss   xmm1, xmm0
    movss   [r12+rdx+12], xmm1
    inc     ecx
    cmp     ecx, 3
    jb      5b
9:  add     rsp, 40
    pop     r12
    pop     rbx
    ret

.section .rodata
.align 4
mj_ident:       .float 1, 0, 0, 0,  0, 1, 0, 0,  0, 0, 1, 0
.text

# mech_eval - every joint's value, every part placed; collisions after a move
mech_eval:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    cmp     dword ptr [rip+mx_busy], 0
    jne     .Lme_ret
    mov     rbx, [rip+an_cur]
    test    rbx, rbx
    jz      .Lme_ret
    cmp     dword ptr [rbx+AN_NMJ_], 0
    je      .Lme_ret
    mov     dword ptr [rip+mx_busy], 1
    xor     r15d, r15d                  # moved
    xor     r12d, r12d
1:  cmp     r12d, [rbx+AN_NMJ_]
    jae     .Lme_done
    mov     esi, r12d
    call    mj_rec
    mov     r13, rax
    mov     eax, [r13+MJ_SRC]           # the value: from another joint,
    test    eax, eax
    jz      2f
    dec     eax
    xorps   xmm0, xmm0
    cmp     eax, r12d
    jae     3f
    mov     esi, eax
    call    mj_rec
    movss   xmm0, [rax+MJ_VAL]
    mulss   xmm0, [r13+MJ_RATIO]
    jmp     3f
2:  lea     rdi, [r13+MJ_EXPR]          #  or its expression
    call    mj_expr
3:  mov     dword ptr [r13+MJ_LIM], 0   # limits
    test    dword ptr [r13+MJ_FLAGS], 1
    jz      4f
    movss   xmm1, xmm0
    maxss   xmm0, [r13+MJ_MIN]
    minss   xmm0, [r13+MJ_MAX]
    ucomiss xmm0, xmm1
    je      4f
    mov     dword ptr [r13+MJ_LIM], 1
4:  movss   [r13+MJ_VAL], xmm0
    movss   [rsp], xmm0
    mov     edi, [r13+MJ_B]
    call    obj_by_uid
    test    rax, rax
    jz      8f
    mov     r14, rax
    movss   xmm0, [rsp]                 # M = joint x B at 0
    mov     rdi, r13
    lea     rsi, [rip+mx_j]
    call    mj_joint_mat
    lea     rdi, [r13+MJ_BREST-OB_LOC]
    lea     rsi, [rip+mx_m]
    call    obj_matrix
    lea     rdi, [rip+mx_m2]
    lea     rsi, [rip+mx_j]
    lea     rdx, [rip+mx_m]
    call    m_mul
    mov     edi, [r13+MJ_A]             # the parent's motion since: A A0^-1 M
    test    edi, edi
    jz      5f
    call    obj_by_uid
    test    rax, rax
    jz      5f
    mov     rdi, rax
    lea     rsi, [rip+mx_m]
    call    obj_matrix
    lea     rdi, [r13+MJ_AREST-OB_LOC]
    lea     rsi, [rip+mx_m3]
    call    obj_matrix
    lea     rdi, [rip+mx_j]
    lea     rsi, [rip+mx_m3]
    call    m_inv
    lea     rdi, [rip+mx_m3]
    lea     rsi, [rip+mx_m]
    lea     rdx, [rip+mx_j]
    call    m_mul
    lea     rdi, [rip+mx_m]
    lea     rsi, [rip+mx_m3]
    lea     rdx, [rip+mx_m2]
    call    m_mul
    lea     rsi, [rip+mx_m]
    lea     rdi, [rip+mx_m2]
    mov     ecx, 48
    rep     movsb
5:  lea     rdi, [rip+mx_e-60]          # loc rot scale (pose_from_mat: +60)
    lea     rsi, [rip+mx_m2]
    call    pose_from_mat
    lea     rsi, [rip+mx_e]
    lea     rdi, [r14+OB_LOC]
    mov     ecx, 36
    repe    cmpsb
    je      8f
    lea     rsi, [rip+mx_e]
    lea     rdi, [r14+OB_LOC]
    mov     ecx, 36
    rep     movsb
    mov     r15d, 1
8:  inc     r12d
    jmp     1b
.Lme_done:
    test    r15d, r15d
    jz      9f
    mov     dword ptr [rip+dirty], 1
    xor     edi, edi
    call    mech_collide
9:  mov     dword ptr [rip+mx_busy], 0
.Lme_ret:
    add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# mech_value(edi=joint, 0..) -> xmm0 = its value, eax = 1 (2: at a limit;
#   0: none)
mech_value:
    xorps   xmm0, xmm0
    xor     eax, eax
    mov     rcx, [rip+an_cur]
    test    rcx, rcx
    jz      9f
    cmp     edi, [rcx+AN_NMJ_]
    jae     9f
    imul    rax, rdi, MJ_SZ_
    lea     rax, [rcx+AN_MJ_+rax]
    movss   xmm0, [rax+MJ_VAL]
    mov     eax, [rax+MJ_LIM]
    inc     eax
9:  ret

# =============================================================================
#  Collisions
# =============================================================================
# mc_joined(edi=uid, esi=uid) -> eax = 1 when a joint ties them directly
mc_joined:
    mov     r8, [rip+an_cur]
    xor     ecx, ecx
1:  cmp     ecx, [r8+AN_NMJ_]
    jae     8f
    imul    rax, rcx, MJ_SZ_
    lea     rax, [r8+AN_MJ_+rax]
    cmp     [rax+MJ_A], edi
    jne     2f
    cmp     [rax+MJ_B], esi
    je      9f
2:  cmp     [rax+MJ_A], esi
    jne     3f
    cmp     [rax+MJ_B], edi
    je      9f
3:  inc     ecx
    jmp     1b
8:  xor     eax, eax
    ret
9:  mov     eax, 1
    ret

# mech_collide(edi=1 to report every pair, 0: the new ones) -> eax = pairs
#   colliding (mech_hits)
mech_collide:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    and     rsp, -16
    sub     rsp, 64 + 8*MC_MAXHIT
    mov     [rsp], edi
    mov     rbx, [rip+an_cur]
    xor     r12d, r12d                  # the moving parts (each once),
    xor     r13d, r13d
1:  cmp     r13d, [rbx+AN_NMJ_]
    jae     2f
    mov     esi, r13d
    call    mj_rec
    mov     edi, [rax+MJ_B]
    call    mc_part
    inc     r13d
    jmp     1b
2:  mov     [rsp+8], r12d
    xor     r13d, r13d                  #  then every other mesh
21: cmp     r13d, [rip+obj_count]
    jae     22f
    mov     edi, r13d
    call    obj_at
    cmp     dword ptr [rax+OB_TYPE], OT_MESH
    jne     23f
    mov     edi, [rax+OB_UID]
    call    mc_part
23: inc     r13d
    jmp     21b
22: mov     [rsp+4], r12d
    xor     r14d, r14d                  # hits now
    xor     r13d, r13d                  # i: a moving part
3:  cmp     r13d, [rsp+8]
    jae     6f
    lea     r15d, [r13+1]               # j: any after it
4:  cmp     r15d, [rsp+4]
    jae     5f
    lea     rax, [rip+mc_parts]
    mov     edi, [rax+r13*4]
    mov     esi, [rax+r15*4]
    call    mc_joined
    test    eax, eax
    jnz     41f
    lea     rax, [rip+mc_parts]
    mov     edi, [rax+r13*4]
    mov     esi, [rax+r15*4]
    call    mc_pair
    test    eax, eax
    jz      41f
    cmp     r14d, MC_MAXHIT
    jae     41f
    lea     rax, [rip+mc_parts]
    mov     ecx, [rax+r13*4]
    mov     [rsp+64+r14*8], ecx
    mov     ecx, [rax+r15*4]
    mov     [rsp+64+r14*8+4], ecx
    inc     r14d
41: inc     r15d
    jmp     4b
5:  inc     r13d
    jmp     3b
6:  xor     r13d, r13d                  # report: new pairs (or all)
7:  cmp     r13d, r14d
    jae     8f
    mov     rax, [rsp+64+r13*8]
    cmp     dword ptr [rsp], 0
    jne     72f
    xor     ecx, ecx
71: cmp     ecx, [rip+mc_n]
    jae     72f
    lea     rdx, [rip+mc_pairs]
    cmp     [rdx+rcx*8], rax
    je      73f
    inc     ecx
    jmp     71b
72: call    fmt_reset
    lea     rdi, [rip+s_col]
    call    fmt_str
    mov     edi, [rsp+64+r13*8]
    call    mc_fmt_name
    lea     rdi, [rip+s_col_and]
    call    fmt_str
    mov     edi, [rsp+64+r13*8+4]
    call    mc_fmt_name
    lea     rdi, [rip+fmt_buf]
    call    log_line
73: inc     r13d
    jmp     7b
8:  mov     [rip+mc_n], r14d            # remembered
    mov     [rip+mech_hits], r14d
    lea     rsi, [rsp+64]
    lea     rdi, [rip+mc_pairs]
    mov     ecx, r14d
    shl     ecx, 3
    rep     movsb
    mov     eax, r14d
    lea     rsp, [rbp-40]
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret
# mc_part(edi=uid; r12d = parts so far) - added unless 0 or there
mc_part:
    test    edi, edi
    jz      9f
    lea     rax, [rip+mc_parts]
    xor     ecx, ecx
1:  cmp     ecx, r12d
    jae     2f
    cmp     [rax+rcx*4], edi
    je      9f
    inc     ecx
    jmp     1b
2:  cmp     r12d, MC_MAXP
    jae     9f
    mov     [rax+r12*4], edi
    inc     r12d
9:  ret
# mc_fmt_name(edi=uid)
mc_fmt_name:
    sub     rsp, 8
    call    obj_by_uid
    lea     rdi, [rip+s_world]
    test    rax, rax
    jz      1f
    lea     rdi, [rax+OB_NAME]
1:  call    fmt_str
    add     rsp, 8
    ret

# mc_pair(edi=uid, esi=uid) -> eax = 1 when their meshes cross
.equ CP_MA,     0                       # mesh, its world points
.equ CP_PA,     8
.equ CP_MB,     16
.equ CP_PB,     24
.equ CP_LO,     32                      # where their bounds meet
.equ CP_HI,     48
.equ CP_MAP,    64                      # the scratch mapping, its size
.equ CP_SIZE,   72
.equ CP_TB,     80                      # B's triangles there, how many
.equ CP_NB,     88
mc_pair:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    and     rsp, -16
    sub     rsp, 256
    mov     [rsp+160], edi
    mov     [rsp+164], esi
    mov     dword ptr [rsp+168], 0      # crossing
    call    obj_by_uid
    test    rax, rax
    jz      .Lmp_out
    mov     r12, rax
    mov     edi, [rsp+164]
    call    obj_by_uid
    test    rax, rax
    jz      .Lmp_out
    mov     r13, rax
    cmp     dword ptr [r12+OB_TYPE], OT_MESH
    jne     .Lmp_out
    cmp     dword ptr [r13+OB_TYPE], OT_MESH
    jne     .Lmp_out
    mov     rdi, r12
    call    obj_eval
    test    rax, rax
    jz      .Lmp_out
    mov     [rsp+CP_MA], rax
    mov     rdi, r13
    call    obj_eval
    test    rax, rax
    jz      .Lmp_out
    mov     [rsp+CP_MB], rax
    # scratch: both meshes' points in the world (12 bytes each), B's list
    mov     rax, [rsp+CP_MA]
    mov     ecx, [rax+ME_NVERTS]
    mov     rax, [rsp+CP_MB]
    add     ecx, [rax+ME_NVERTS]
    imul    rsi, rcx, 12
    mov     eax, [rax+ME_NTRIS]
    lea     rsi, [rsi+rax*4+8192]
    add     rsi, 4095
    and     rsi, -4096
    mov     [rsp+CP_SIZE], rsi
    xor     edi, edi
    mov     edx, PROT_RW
    mov     r10d, 0x22
    mov     r8, -1
    xor     r9d, r9d
    call    plat_mmap
    cmp     rax, -4096
    jae     .Lmp_out
    mov     [rsp+CP_MAP], rax
    mov     [rsp+CP_PA], rax
    mov     rdi, r12                    # A's points
    lea     rsi, [rsp+176]
    call    obj_matrix
    mov     rdi, [rsp+CP_MA]
    mov     rsi, [rsp+CP_PA]
    lea     rdx, [rsp+176]
    call    mc_points                   # (xmm6 / xmm7: their bounds)
    movaps  [rsp+96], xmm6
    movaps  [rsp+112], xmm7
    mov     rax, [rsp+CP_MA]
    mov     ecx, [rax+ME_NVERTS]
    imul    rcx, rcx, 12
    add     rcx, [rsp+CP_PA]
    mov     [rsp+CP_PB], rcx
    mov     rdi, r13                    # B's
    lea     rsi, [rsp+176]
    call    obj_matrix
    mov     rdi, [rsp+CP_MB]
    mov     rsi, [rsp+CP_PB]
    lea     rdx, [rsp+176]
    call    mc_points
    movaps  xmm0, [rsp+96]              # where the bounds meet
    maxps   xmm0, xmm6
    movaps  xmm1, [rsp+112]
    minps   xmm1, xmm7
    movups  [rsp+CP_LO], xmm0
    movups  [rsp+CP_HI], xmm1
    cmpleps xmm0, xmm1
    movmskps eax, xmm0
    and     eax, 7
    cmp     eax, 7
    jne     .Lmp_free
    mov     rax, [rsp+CP_MB]            # B's triangles in it
    mov     ecx, [rax+ME_NVERTS]
    imul    rcx, rcx, 12
    add     rcx, [rsp+CP_PB]
    mov     [rsp+CP_TB], rcx
    xor     r14d, r14d
    xor     r15d, r15d
1:  mov     rax, [rsp+CP_MB]
    cmp     r15d, [rax+ME_NTRIS]
    jae     2f
    mov     rdi, rax
    mov     rsi, [rsp+CP_PB]
    mov     edx, r15d
    call    tri_box
    movups  xmm2, [rsp+CP_LO]
    movups  xmm3, [rsp+CP_HI]
    call    box_meets
    test    eax, eax
    jz      11f
    mov     rax, [rsp+CP_TB]
    mov     [rax+r14*4], r15d
    inc     r14d
11: inc     r15d
    jmp     1b
2:  mov     [rsp+CP_NB], r14d
    test    r14d, r14d
    jz      .Lmp_free
    xor     r15d, r15d                  # A's triangles there, against them
3:  mov     rax, [rsp+CP_MA]
    cmp     r15d, [rax+ME_NTRIS]
    jae     .Lmp_free
    mov     rdi, rax
    mov     rsi, [rsp+CP_PA]
    mov     edx, r15d
    call    tri_box
    movups  xmm2, [rsp+CP_LO]
    movups  xmm3, [rsp+CP_HI]
    call    box_meets
    test    eax, eax
    jz      5f
    movaps  [rsp+128], xmm0             # (A's triangle's bounds)
    movaps  [rsp+144], xmm1
    mov     rax, [rsp+CP_MA]            # its corners
    mov     rax, [rax+ME_TRIS]
    imul    rcx, r15, 12
    mov     rdx, [rsp+CP_PA]
    mov     ebx, [rax+rcx]
    imul    rbx, rbx, 12
    add     rbx, rdx
    mov     r12d, [rax+rcx+4]
    imul    r12, r12, 12
    add     r12, rdx
    mov     r13d, [rax+rcx+8]
    imul    r13, r13, 12
    add     r13, rdx
    xor     r14d, r14d
4:  cmp     r14d, [rsp+CP_NB]
    jae     5f
    mov     rax, [rsp+CP_TB]
    mov     edx, [rax+r14*4]
    mov     rdi, [rsp+CP_MB]
    mov     rsi, [rsp+CP_PB]
    call    tri_box
    movaps  xmm2, [rsp+128]
    movaps  xmm3, [rsp+144]
    call    box_meets
    test    eax, eax
    jz      41f
    mov     rax, [rsp+CP_MB]
    mov     rax, [rax+ME_TRIS]
    mov     rcx, [rsp+CP_TB]
    mov     ecx, [rcx+r14*4]
    imul    rcx, rcx, 12
    mov     rdx, [rsp+CP_PB]
    mov     edi, [rax+rcx]
    imul    rdi, rdi, 12
    add     rdi, rdx
    mov     esi, [rax+rcx+4]
    imul    rsi, rsi, 12
    add     rsi, rdx
    mov     r8d, [rax+rcx+8]
    imul    r8, r8, 12
    add     r8, rdx
    mov     [rsp+224], rdi
    mov     [rsp+232], rsi
    mov     [rsp+240], r8
    lea     rdi, [rsp+224]
    call    tris_cross
    test    eax, eax
    jz      41f
    mov     dword ptr [rsp+168], 1
    jmp     .Lmp_free
41: inc     r14d
    jmp     4b
5:  inc     r15d
    jmp     3b
.Lmp_free:
    mov     rdi, [rsp+CP_MAP]
    mov     rsi, [rsp+CP_SIZE]
    call    plat_munmap
.Lmp_out:
    mov     eax, [rsp+168]
    lea     rsp, [rbp-40]
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret

# mc_points(rdi=mesh, rsi=out (12 bytes a point), rdx=matrix) - its points
#   in the world -> xmm6 / xmm7 their bounds (low / high)
mc_points:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13, rdx
    movss   xmm6, [rip+mc_big]
    shufps  xmm6, xmm6, 0
    movaps  xmm7, xmm6
    xorps   xmm7, [rip+mc_negall]
    xor     r14d, r14d
1:  cmp     r14d, [rbx+ME_NVERTS]
    jae     9f
    imul    rsi, r14, 12
    add     rsi, [rbx+ME_POS]
    imul    rdx, r14, 12
    add     rdx, r12
    mov     rdi, r13
    call    xform_point
    imul    rax, r14, 12
    movsd   xmm0, [r12+rax]
    movss   xmm1, [r12+rax+8]
    movlhps xmm0, xmm1
    minps   xmm6, xmm0
    maxps   xmm7, xmm0
    inc     r14d
    jmp     1b
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# tri_box(rdi=mesh, rsi=its points, edx=triangle) -> xmm0 / xmm1 = bounds
tri_box:
    mov     rax, [rdi+ME_TRIS]
    imul    rcx, rdx, 12
    mov     edx, [rax+rcx]
    imul    rdx, rdx, 12
    movsd   xmm0, [rsi+rdx]
    movss   xmm2, [rsi+rdx+8]
    movlhps xmm0, xmm2
    movaps  xmm1, xmm0
    mov     edx, [rax+rcx+4]
    imul    rdx, rdx, 12
    movsd   xmm3, [rsi+rdx]
    movss   xmm2, [rsi+rdx+8]
    movlhps xmm3, xmm2
    minps   xmm0, xmm3
    maxps   xmm1, xmm3
    mov     edx, [rax+rcx+8]
    imul    rdx, rdx, 12
    movsd   xmm3, [rsi+rdx]
    movss   xmm2, [rsi+rdx+8]
    movlhps xmm3, xmm2
    minps   xmm0, xmm3
    maxps   xmm1, xmm3
    ret

# box_meets(xmm0/xmm1 = a box, xmm2/xmm3 = another) -> eax = 1 when they meet
box_meets:
    movaps  xmm4, xmm0
    cmpleps xmm4, xmm3
    movaps  xmm5, xmm2
    cmpleps xmm5, xmm1
    andps   xmm4, xmm5
    movmskps eax, xmm4
    and     eax, 7
    cmp     eax, 7
    sete    al
    movzx   eax, al
    ret

# tris_cross(rdi=B's corners (3 pointers); rbx, r12, r13 = A's) -> eax = 1
#   when an edge of either passes strictly through the other
tris_cross:
    push    r14
    push    r15
    sub     rsp, 8
    mov     r14, rdi
    mov     r15, [r14]                  # A's edges through B
    mov     rdi, rbx
    mov     rsi, r12
    call    seg_b
    jnz     8f
    mov     rdi, r12
    mov     rsi, r13
    call    seg_b
    jnz     8f
    mov     rdi, r13
    mov     rsi, rbx
    call    seg_b
    jnz     8f
    xor     ecx, ecx                    # B's edges through A
1:  cmp     ecx, 3
    jae     7f
    mov     rdi, [r14+rcx*8]
    lea     eax, [rcx+1]
    cmp     eax, 3
    jb      2f
    xor     eax, eax
2:  mov     rsi, [r14+rax*8]
    push    rcx
    push    rcx
    mov     rdx, rbx
    mov     rcx, r12
    mov     r8, r13
    call    seg_tri
    pop     rcx
    pop     rcx
    test    eax, eax
    jnz     8f
    inc     ecx
    jmp     1b
7:  xor     eax, eax
    jmp     9f
8:  mov     eax, 1
9:  add     rsp, 8
    pop     r15
    pop     r14
    ret
seg_b:                                  # (rdi, rsi through B: r14's corners)
    sub     rsp, 8
    mov     rdx, [r14]
    mov     rcx, [r14+8]
    mov     r8, [r14+16]
    call    seg_tri
    add     rsp, 8
    test    eax, eax
    ret

# ld3(reg=pointer) -> an xmm with the 3 floats
.macro LD3 x, p, t
    movsd   \x, [\p]
    movss   \t, [\p+8]
    movlhps \x, \t
.endm
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

# seg_tri(rdi=p0, rsi=p1, rdx=a, rcx=b, r8=c) -> eax = 1 when the segment
#   passes strictly through the triangle (both ends clearly apart from its
#   plane, the point clearly inside its edges)
seg_tri:
    LD3     xmm8, rdx, xmm0             # a
    LD3     xmm9, rcx, xmm0             # b
    LD3     xmm10, r8, xmm0             # c
    movaps  xmm1, xmm9
    subps   xmm1, xmm8
    movaps  xmm2, xmm10
    subps   xmm2, xmm8
    CROSS   xmm11, xmm1, xmm2, xmm3     # n
    movaps  xmm3, xmm11
    DOT3    xmm3, xmm3
    sqrtss  xmm3, xmm3
    comiss  xmm3, [rip+mx_tiny]
    jbe     8f
    shufps  xmm3, xmm3, 0
    divps   xmm11, xmm3                 # unit
    LD3     xmm12, rdi, xmm0            # p0
    LD3     xmm13, rsi, xmm0            # p1
    movaps  xmm4, xmm12
    subps   xmm4, xmm8
    DOT3    xmm4, xmm11                 # d0
    movaps  xmm5, xmm13
    subps   xmm5, xmm8
    DOT3    xmm5, xmm11                 # d1
    movss   xmm6, [rip+mx_eps]
    movaps  xmm7, xmm6
    xorps   xmm7, [rip+mc_negall]       # -eps
    comiss  xmm4, xmm6                  # d0 > eps and d1 < -eps, or turned
    jbe     1f
    comiss  xmm5, xmm7
    jae     8f
    jmp     2f
1:  comiss  xmm4, xmm7
    jae     8f
    comiss  xmm5, xmm6
    jbe     8f
2:  movss   xmm0, xmm4                  # q = p0 + d0 / (d0 - d1) (p1 - p0)
    subss   xmm4, xmm5
    divss   xmm0, xmm4
    shufps  xmm0, xmm0, 0
    movaps  xmm1, xmm13
    subps   xmm1, xmm12
    mulps   xmm1, xmm0
    addps   xmm1, xmm12                 # q
    movaps  xmm14, xmm1
    movaps  xmm0, xmm8                  # inside each edge, by a margin
    movaps  xmm15, xmm9
    call    st_edge
    jbe     8f
    movaps  xmm0, xmm9
    movaps  xmm15, xmm10
    call    st_edge
    jbe     8f
    movaps  xmm0, xmm10
    movaps  xmm15, xmm8
    call    st_edge
    jbe     8f
    mov     eax, 1
    ret
8:  xor     eax, eax
    ret
# st_edge(xmm0=from, xmm15=to, xmm14=q, xmm11=n) -> flags: above when q is
#   inside the edge by more than eps x its length
st_edge:
    movaps  xmm1, xmm15
    subps   xmm1, xmm0                  # e
    movaps  xmm2, xmm14
    subps   xmm2, xmm0
    CROSS   xmm3, xmm1, xmm2, xmm4
    DOT3    xmm3, xmm11
    DOT3    xmm1, xmm1
    sqrtss  xmm1, xmm1
    mulss   xmm1, [rip+mx_eps]
    comiss  xmm3, xmm1
    ret

.section .rodata
.align 16
mc_negall:      .long 0x80000000, 0x80000000, 0x80000000, 0x80000000
mc_big:         .float 1.0e30
.text

# =============================================================================
#  Parameters as animation channels (anim.s: K_PARAM)
# =============================================================================
# param_chan(edi=parameter, xmm0=value, esi=1 to set) -> xmm0 = its value,
#   eax = 1 (0: not there). A new value becomes its expression; the
#   sketches and features rebuild
param_chan:
    push    rbx
    push    r12
    sub     rsp, 24
    mov     ebx, edi
    mov     r12d, esi
    movss   [rsp], xmm0
    call    param_count
    cmp     ebx, eax
    jae     8f
    mov     edi, ebx
    call    param_value
    cvtsd2ss xmm0, xmm0
    test    r12d, r12d
    jz      7f
    ucomiss xmm0, [rsp]
    jne     1f
    jnp     7f
1:  movss   xmm0, [rsp]                 # the number as text
    lea     rdi, [rip+mx_numbuf]
    call    fmt_num6
    mov     edi, ebx
    call    param_rec                   # its name (param_set rewrites the record)
    mov     rsi, rax
    lea     rdi, [rip+mx_word]
    mov     ecx, 24
    rep     movsb
    lea     rdi, [rip+mx_word]
    lea     rsi, [rip+mx_numbuf]
    call    param_set
    call    cad_rebuild
    movss   xmm0, [rsp]
7:  mov     eax, 1
    jmp     9f
8:  xorps   xmm0, xmm0
    xor     eax, eax
9:  add     rsp, 24
    pop     r12
    pop     rbx
    ret

# fmt_num6(xmm0=float, rdi=out) - "-12.345678" (six decimals)
fmt_num6:
    cvtss2sd xmm0, xmm0
    xorpd   xmm1, xmm1
    comisd  xmm0, xmm1
    jae     1f
    mov     byte ptr [rdi], '-'
    inc     rdi
    subsd   xmm1, xmm0
    movsd   xmm0, xmm1
1:  mulsd   xmm0, [rip+mx_mill]         # in millionths, rounded
    addsd   xmm0, [rip+mx_dhalf]
    cvttsd2si rax, xmm0
    mov     rcx, 1000000
    xor     edx, edx
    div     rcx                         # rax = whole, rdx = millionths
    mov     r8, rdx
    lea     r9, [rsp-32]                # digits of the whole, backwards
    xor     ecx, ecx
2:  xor     edx, edx
    mov     r10, 10
    div     r10
    add     dl, '0'
    mov     [r9+rcx], dl
    inc     ecx
    test    rax, rax
    jnz     2b
3:  dec     ecx
    mov     al, [r9+rcx]
    mov     [rdi], al
    inc     rdi
    test    ecx, ecx
    jnz     3b
    mov     byte ptr [rdi], '.'
    inc     rdi
    mov     rax, r8
    mov     ecx, 6
4:  xor     edx, edx
    mov     r10, 10
    div     r10
    add     dl, '0'
    mov     [rdi+rcx-1], dl
    dec     ecx
    jnz     4b
    mov     byte ptr [rdi+6], 0
    ret

# =============================================================================
#  Operators
# =============================================================================
OPERATOR op_mj_add,  "mech.joint",  "Add Mechanism Joint", do_mj_add, flags=OPF_AI_SAFE|OPF_UNDO, doc="Join a part to its parent so it moves: mech.joint <revolute|slider> <part> <parent|world> [pivot x y z] [axis x y z] [min e] [max e] [gear <joint> <ratio>] [value <expression>] (the part as it is now is its place at 0; values: parameters, units, frame)", form=form_joint
OPERATOR op_mj_set,  "mech.set",    "Set Mechanism Joint", do_mj_set, flags=OPF_AI_SAFE|OPF_UNDO, doc="Change a joint (1..): mech.set <n> value <expression> | min <e> | max <e> | nolimits | gear <joint> <ratio>"
OPERATOR op_mj_rem,  "mech.remove", "Remove Mechanism Joint", do_mj_rem, flags=OPF_AI_SAFE|OPF_UNDO, doc="Remove a mechanism joint: mech.remove <n>"
OPERATOR op_mj_list, "mech.list",   "List Mechanism Joints", do_mj_list, flags=OPF_AI_SAFE|OPF_QUIET, doc="The mechanism's joints and their values, in the console"
OPERATOR op_mj_check,"mech.check",  "Check Collisions",    do_mj_check, flags=OPF_AI_SAFE|OPF_QUIET, doc="Which of the mechanism's parts collide now"

# mx_obj(rdi=name) -> rax = the object or 0
mx_obj:
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

# mx_num(rsi=text) -> xmm0, eax, rsi after (a plain number)
mx_num:
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

# mx_word_expr(rsi=text) -> xmm0 (an expression of one word), eax, rsi after
mx_word_expr:
    push    rbx
    call    im_next_word
    mov     rbx, rsi
    test    eax, eax
    jz      8f
    lea     rdi, [rip+im_word]
    call    mj_expr
    mov     rsi, rbx
    pop     rbx
    ret
8:  xor     eax, eax
    mov     rsi, rbx
    pop     rbx
    ret

# mj_option(rbx=record, r12=text after the keyword's word in im_word) ->
#   eax = 1 (understood), r12 after; a value takes the rest
mj_option:
    push    r13
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_value]
    call    str_eq
    test    eax, eax
    jz      2f
    mov     rsi, r12                    # the rest: the expression
1:  cmp     byte ptr [rsi], ' '
    jne     11f
    inc     rsi
    jmp     1b
11: lea     rdi, [rbx+MJ_EXPR]
    xor     ecx, ecx
12: mov     al, [rsi+rcx]
    mov     [rdi+rcx], al
    test    al, al
    jz      13f
    inc     ecx
    cmp     ecx, MJ_EXPRSZ-1
    jb      12b
    mov     byte ptr [rdi+rcx], 0
13: lea     r12, [rsi+rcx]
    mov     dword ptr [rbx+MJ_SRC], 0
    lea     rdi, [rbx+MJ_EXPR]          # it must work
    call    mj_expr
    jmp     9f
2:  lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_min]
    call    str_eq
    mov     r13d, MJ_MIN
    test    eax, eax
    jnz     3f
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_max]
    call    str_eq
    mov     r13d, MJ_MAX
    test    eax, eax
    jz      4f
3:  test    dword ptr [rbx+MJ_FLAGS], 1 # limits: both, wide open at first
    jnz     31f
    or      dword ptr [rbx+MJ_FLAGS], 1
    mov     dword ptr [rbx+MJ_MIN], 0xff7fffff
    mov     dword ptr [rbx+MJ_MAX], 0x7f7fffff
31: mov     rsi, r12
    call    mx_word_expr
    mov     r12, rsi
    test    eax, eax
    jz      9f
    movss   [rbx+r13], xmm0
    jmp     9f
4:  lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_free]
    call    str_eq
    test    eax, eax
    jz      5f
    and     dword ptr [rbx+MJ_FLAGS], ~1
    jmp     9f
5:  lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_gear]
    call    str_eq
    test    eax, eax
    jz      9f
    mov     rsi, r12                    # gear <joint> <ratio>
    call    mx_num
    test    eax, eax
    jz      9f
    cvttss2si eax, xmm0
    mov     [rbx+MJ_SRC], eax
    call    mx_num
    mov     r12, rsi
    test    eax, eax
    jz      9f
    movss   [rbx+MJ_RATIO], xmm0
    mov     byte ptr [rbx+MJ_EXPR], 0
    mov     eax, 1
9:  pop     r13
    ret

# mech.joint <type> <part> <parent|world> [options]
do_mj_add:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    lea     rbx, [rip+mj_new]
    mov     rdi, rbx
    xor     eax, eax
    mov     ecx, MJ_SZ_
    rep     stosb
    mov     dword ptr [rbx+MJ_AXIS+4], 0x3f800000
    mov     dword ptr [rbx+MJ_RATIO], 0x3f800000
    mov     rsi, [rip+op_arg]
    call    im_next_word
    mov     r12, rsi
    xor     ecx, ecx                    # the type
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+s_rev]
    call    str_eq
    mov     ecx, 1
    test    eax, eax
    jnz     1f
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+s_slider]
    call    str_eq
    mov     ecx, 2
    test    eax, eax
    jz      .Lma_bad
1:  mov     [rbx+MJ_TYPE], ecx
    mov     rsi, r12                    # the part
    call    im_next_word
    mov     r12, rsi
    lea     rdi, [rip+im_word]
    call    mx_obj
    test    rax, rax
    jz      .Lma_bad
    mov     r13, rax
    mov     eax, [r13+OB_UID]
    mov     [rbx+MJ_B], eax
    lea     rsi, [r13+OB_LOC]           # at 0: as it is; pivot: its place
    lea     rdi, [rbx+MJ_BREST]
    mov     ecx, 36
    rep     movsb
    mov     rax, [r13+OB_LOC]
    mov     [rbx+MJ_PIV], rax
    mov     eax, [r13+OB_LOC+8]
    mov     [rbx+MJ_PIV+8], eax
    mov     rsi, r12                    # the parent
    call    im_next_word
    mov     r12, rsi
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+s_world]
    call    str_eq
    test    eax, eax
    jnz     2f
    lea     rdi, [rip+im_word]
    call    mx_obj
    test    rax, rax
    jz      .Lma_bad
    cmp     rax, r13
    je      .Lma_bad
    mov     ecx, [rax+OB_UID]
    mov     [rbx+MJ_A], ecx
    lea     rsi, [rax+OB_LOC]
    lea     rdi, [rbx+MJ_AREST]
    mov     ecx, 36
    rep     movsb
2:  mov     rsi, r12                    # options
    call    im_next_word
    mov     r12, rsi
    test    eax, eax
    jz      .Lma_store
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_pivot]
    call    str_eq
    lea     r14, [rbx+MJ_PIV]
    test    eax, eax
    jnz     3f
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_axis]
    call    str_eq
    lea     r14, [rbx+MJ_AXIS]
    test    eax, eax
    jnz     3f
    call    mj_option
    test    eax, eax
    jz      .Lma_bad
    jmp     2b
3:  xor     r13d, r13d                  # x y z
31: mov     rsi, r12
    call    mx_word_expr
    mov     r12, rsi
    test    eax, eax
    jz      .Lma_bad
    movss   [r14+r13*4], xmm0
    inc     r13d
    cmp     r13d, 3
    jb      31b
    jmp     2b
.Lma_store:
    call    mj_unit_axis
    cmp     dword ptr [rbx+MJ_SRC], 0   # a gear from an earlier joint
    je      4f
    xor     edi, edi
    call    an_own_g
    test    rax, rax
    jz      .Lma_full
    mov     ecx, [rbx+MJ_SRC]
    cmp     ecx, [rax+AN_NMJ_]
    ja      .Lma_bad
4:  xor     edi, edi
    call    an_own_g
    test    rax, rax
    jz      .Lma_full
    mov     r13, rax
    mov     eax, [r13+AN_NMJ_]
    cmp     eax, MJ_MAX_
    jae     .Lma_full
    inc     dword ptr [r13+AN_NMJ_]
    imul    rdi, rax, MJ_SZ_
    lea     rdi, [r13+AN_MJ_+rdi]
    mov     rsi, rbx
    mov     ecx, MJ_SZ_
    rep     movsb
    mov     esi, [r13+AN_NMJ_]
    call    mj_log
    jmp     .Lma_out
.Lma_full:
    lea     rdi, [rip+s_mj_full]
    call    log_line
    call    undo_drop_last
    jmp     .Lma_out
.Lma_bad:
    lea     rdi, [rip+s_mj_bad]
    lea     rsi, [rip+im_word]
    call    log_pair
    call    undo_drop_last
.Lma_out:
    add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# mj_unit_axis(rbx=record) - its axis made unit (Y when none)
mj_unit_axis:
    movss   xmm0, [rbx+MJ_AXIS]
    mulss   xmm0, xmm0
    movss   xmm1, [rbx+MJ_AXIS+4]
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    movss   xmm1, [rbx+MJ_AXIS+8]
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    sqrtss  xmm0, xmm0
    comiss  xmm0, [rip+mx_tiny]
    ja      1f
    mov     dword ptr [rbx+MJ_AXIS], 0
    mov     dword ptr [rbx+MJ_AXIS+4], 0x3f800000
    mov     dword ptr [rbx+MJ_AXIS+8], 0
    ret
1:  movss   xmm1, [rip+mx_one]
    divss   xmm1, xmm0
    xor     ecx, ecx
2:  movss   xmm0, [rbx+MJ_AXIS+rcx*4]
    mulss   xmm0, xmm1
    movss   [rbx+MJ_AXIS+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      2b
    ret

# mj_log(esi=number 1..) - "  joint 2: revolute Gear2 on Gear1 = joint 1 x -0.5"
mj_log:
    push    rbx
    push    r12
    push    r13
    mov     r12d, esi
    mov     rbx, [rip+an_cur]
    lea     esi, [r12-1]
    call    mj_rec
    mov     r13, rax
    call    fmt_reset
    lea     rdi, [rip+s_mj]
    call    fmt_str
    mov     edi, r12d
    call    fmt_int
    lea     rdi, [rip+s_colon]
    call    fmt_str
    mov     eax, [r13+MJ_TYPE]
    dec     eax
    and     eax, 1
    lea     rcx, [rip+type_names]
    mov     rdi, [rcx+rax*8]
    call    fmt_str
    mov     edi, ' '
    call    fmt_char
    mov     edi, [r13+MJ_B]
    call    mc_fmt_name
    lea     rdi, [rip+s_col_and]
    call    fmt_str
    mov     edi, [r13+MJ_A]
    call    mc_fmt_name
    cmp     dword ptr [r13+MJ_SRC], 0
    je      1f
    lea     rdi, [rip+s_mj_from]
    call    fmt_str
    mov     edi, [r13+MJ_SRC]
    call    fmt_int
    lea     rdi, [rip+s_mj_x]
    call    fmt_str
    movss   xmm0, [r13+MJ_RATIO]
    call    fmt_val3
    jmp     2f
1:  cmp     byte ptr [r13+MJ_EXPR], 0
    je      2f
    lea     rdi, [rip+s_eq]
    call    fmt_str
    lea     rdi, [r13+MJ_EXPR]
    call    fmt_str
2:  lea     rdi, [rip+s_colon]
    call    fmt_str
    movss   xmm0, [r13+MJ_VAL]
    call    fmt_val3
    cmp     dword ptr [r13+MJ_LIM], 0
    je      3f
    lea     rdi, [rip+s_mj_lim]
    call    fmt_str
3:  lea     rdi, [rip+fmt_buf]
    call    log_line
    pop     r13
    pop     r12
    pop     rbx
    ret

# mech.set <n> <option ...>
do_mj_set:
    push    rbx
    push    r12
    push    r13
    xor     edi, edi
    call    an_own_g
    test    rax, rax
    jz      8f
    mov     r13, rax
    mov     rsi, [rip+op_arg]
    call    mx_num
    mov     r12, rsi
    test    eax, eax
    jz      8f
    cvttss2si eax, xmm0
    dec     eax
    cmp     eax, [r13+AN_NMJ_]
    jae     8f
    imul    rbx, rax, MJ_SZ_
    lea     rbx, [r13+AN_MJ_+rbx]
1:  mov     rsi, r12
    call    im_next_word
    mov     r12, rsi
    test    eax, eax
    jz      9f
    call    mj_option
    test    eax, eax
    jnz     1b
8:  lea     rdi, [rip+s_mj_none]
    lea     rsi, [rip+im_word]
    call    log_pair
    call    undo_drop_last
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# mech.remove <n>
do_mj_rem:
    push    rbx
    push    r12
    sub     rsp, 8
    xor     edi, edi
    call    an_own_g
    test    rax, rax
    jz      8f
    mov     rbx, rax
    mov     rsi, [rip+op_arg]
    call    mx_num
    test    eax, eax
    jz      8f
    cvttss2si eax, xmm0
    dec     eax
    cmp     eax, [rbx+AN_NMJ_]
    jae     8f
    mov     r12d, eax
    imul    rdi, rax, MJ_SZ_            # later ones down; gears after it renumbered
    lea     rdi, [rbx+AN_MJ_+rdi]
    lea     rsi, [rdi+MJ_SZ_]
    mov     ecx, [rbx+AN_NMJ_]
    sub     ecx, r12d
    dec     ecx
    imul    ecx, ecx, MJ_SZ_
    rep     movsb
    dec     dword ptr [rbx+AN_NMJ_]
    xor     ecx, ecx
1:  cmp     ecx, [rbx+AN_NMJ_]
    jae     9f
    imul    rax, rcx, MJ_SZ_
    lea     rax, [rbx+AN_MJ_+rax]
    mov     edx, [rax+MJ_SRC]
    lea     r8d, [r12+1]
    cmp     edx, r8d
    jne     2f
    mov     dword ptr [rax+MJ_SRC], 0   # its source went: still
    jmp     3f
2:  cmp     edx, r8d
    jbe     3f
    dec     dword ptr [rax+MJ_SRC]
3:  inc     ecx
    jmp     1b
8:  lea     rdi, [rip+s_mj_none]
    lea     rsi, [rip+im_word]
    call    log_pair
    call    undo_drop_last
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# mech.list
do_mj_list:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, [rip+an_cur]
    test    rbx, rbx
    jz      9f
    xor     r12d, r12d
1:  cmp     r12d, [rbx+AN_NMJ_]
    jae     9f
    inc     r12d
    mov     esi, r12d
    call    mj_log
    jmp     1b
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# mech.check
do_mj_check:
    sub     rsp, 8
    mov     rax, [rip+an_cur]
    test    rax, rax
    jz      1f
    cmp     dword ptr [rax+AN_NMJ_], 0
    je      1f
    mov     edi, 1
    call    mech_collide
    test    eax, eax
    jnz     9f
1:  lea     rdi, [rip+s_col_none]
    call    log_line
9:  add     rsp, 8
    ret

# =============================================================================
#  Mates (D4): place a component against another. A mate moves the part
#  once, as a placing tool (no constraint solver: run it again after a
#  part changes). References: a face number of the object's mesh (its
#  centre and normal: a plane, or the axis through it), or
#  "axis px py pz dx dy dz" in the object's own space (a hole, a shaft).
#    coincident  the faces' planes meet, facing each other
#    distance d  the same, with a gap of d
#    concentric  the axes on one line, pointing the same way
#  "flip" turns the part round. It turns about its origin by the shortest
#  arc, then moves the least: along the target's normal (coincident,
#  distance) or across its axis (concentric).
# =============================================================================
.section .rodata
s_coinc:        .asciz "coincident"
s_conc:         .asciz "concentric"
s_dist:         .asciz "distance"
s_flip:         .asciz "flip"
s_as_bad:       .asciz "  asm.mate <coincident|concentric|distance> <part> <face|axis px py pz dx dy dz> <target> <face|axis ...> [distance] [flip] - not understood: "
s_as_done:      .asciz "  mated: "
s_as_to:        .asciz " to "
.align 4
as_two:         .float 2.0
.section .bss
.align 16
as_p:           .skip 12                # the part's reference (its space)
as_n:           .skip 12
as_q:           .skip 12                # the target's
as_m:           .skip 12
as_pw:          .skip 12                # in the world
as_nw:          .skip 12
as_qw:          .skip 12
as_mw:          .skip 12
as_ax:          .skip 12
as_v:           .skip 12
as_eu:          .skip 12
as_R:           .skip 36
as_Rd:          .skip 36
as_M:           .skip 48
as_d:           .skip 4
as_flip:        .skip 4
as_type:        .skip 4                 # 1 coincident, 2 concentric, 3 distance
.text
OPERATOR op_asm_mate, "asm.mate", "Mate Parts", do_asm_mate, flags=OPF_AI_SAFE|OPF_UNDO, doc="Place a part against another: asm.mate <coincident|concentric|distance> <part> <face|axis px py pz dx dy dz> <target> <face|axis ...> [distance] [flip] (faces: centre and normal; axis: in the object's own space; the part moves, once)"

do_asm_mate:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     dword ptr [rip+as_d], 0
    mov     dword ptr [rip+as_flip], 0
    mov     rsi, [rip+op_arg]
    test    rsi, rsi
    jz      .Las_bad
    call    im_next_word                # the kind
    mov     r12, rsi
    mov     r14d, 1
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+s_coinc]
    call    str_eq
    test    eax, eax
    jnz     1f
    mov     r14d, 2
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+s_conc]
    call    str_eq
    test    eax, eax
    jnz     1f
    mov     r14d, 3
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+s_dist]
    call    str_eq
    test    eax, eax
    jz      .Las_bad
1:  mov     [rip+as_type], r14d
    mov     rsi, r12                    # the part and its reference
    call    im_next_word
    mov     r12, rsi
    lea     rdi, [rip+im_word]
    call    mx_obj
    test    rax, rax
    jz      .Las_bad
    mov     rbx, rax
    mov     rdi, rbx
    lea     rsi, [rip+as_p]
    lea     rdx, [rip+as_n]
    call    as_ref
    test    eax, eax
    jz      .Las_bad
    mov     rsi, r12                    # the target and its reference
    call    im_next_word
    mov     r12, rsi
    lea     rdi, [rip+im_word]
    call    mx_obj
    test    rax, rax
    jz      .Las_bad
    cmp     rax, rbx
    je      .Las_bad
    mov     r13, rax
    mov     rdi, r13
    lea     rsi, [rip+as_q]
    lea     rdx, [rip+as_m]
    call    as_ref
    test    eax, eax
    jz      .Las_bad
    cmp     r14d, 3                     # distance: its value
    jne     2f
    mov     rsi, r12
    call    mx_word_expr
    mov     r12, rsi
    test    eax, eax
    jz      .Las_bad
    movss   [rip+as_d], xmm0
2:  mov     rsi, r12                    # flip
    call    im_next_word
    mov     r12, rsi
    test    eax, eax
    jz      3f
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+s_flip]
    call    str_eq
    test    eax, eax
    jz      .Las_bad
    mov     dword ptr [rip+as_flip], 1
    jmp     2b
3:  mov     rdi, r13                    # the target in the world
    lea     rsi, [rip+as_q]
    lea     rdx, [rip+as_qw]
    call    as_wpoint
    mov     rdi, r13
    lea     rsi, [rip+as_m]
    lea     rdx, [rip+as_mw]
    call    as_wdir
    mov     rdi, rbx                    # the part's normal in the world
    lea     rsi, [rip+as_n]
    lea     rdx, [rip+as_nw]
    call    as_wdir
    xor     ecx, ecx                    # where it should point: the
    mov     eax, [rip+as_flip]          #  target's way (concentric) or
    cmp     r14d, 2                     #  against it, flip turning it round
    je      40f
    xor     eax, 1
40: lea     r8, [rip+as_mw]
    lea     r9, [rip+as_v]
4:  movss   xmm0, [r8+rcx*4]
    test    eax, eax
    jz      41f
    xorps   xmm1, xmm1
    subss   xmm1, xmm0
    movaps  xmm0, xmm1
41: movss   [r9+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      4b
    lea     rdi, [rip+as_nw]            # the turn: axis n x want, the angle
    lea     rsi, [rip+as_v]             #  atan2(|n x want|, n . want)
    lea     rdx, [rip+as_ax]
    call    as_cross
    lea     rdi, [rip+as_ax]
    call    as_len
    movss   [rsp], xmm0
    lea     rdi, [rip+as_nw]
    lea     rsi, [rip+as_v]
    call    as_dot
    movss   [rsp+4], xmm0
    movss   xmm0, [rsp]
    comiss  xmm0, [rip+mx_eps]
    ja      5f
    movss   xmm0, [rsp+4]               # parallel: done, or half a turn
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    ja      7f
    lea     rdi, [rip+as_nw]            #  about any axis across n
    call    as_perp
    mov     dword ptr [rsp+4], 0xbf800000
    mov     dword ptr [rsp], 0
5:  lea     rdi, [rip+as_ax]
    call    normalize
    fld     dword ptr [rsp]
    fld     dword ptr [rsp+4]
    fpatan
    fstp    dword ptr [rsp]
    movss   xmm0, [rsp]
    lea     rdi, [rip+as_ax]
    lea     rsi, [rip+as_Rd]
    call    o_axis_mat
    lea     rdi, [rbx+OB_ROT]           # R' = Rd R
    lea     rsi, [rip+as_R]
    call    o_euler_mat
    lea     rdi, [rip+as_Rd]
    lea     rsi, [rip+as_R]
    lea     rdx, [rip+as_R]
    call    o_mul
    lea     rdi, [rip+as_R]
    lea     rsi, [rip+as_eu]
    call    o_mat_euler
    mov     rax, [rip+as_eu]
    mov     [rbx+OB_ROT], rax
    mov     eax, [rip+as_eu+8]
    mov     [rbx+OB_ROT+8], eax
7:  mov     rdi, rbx                    # the part's point, turned
    lea     rsi, [rip+as_p]
    lea     rdx, [rip+as_pw]
    call    as_wpoint
    xor     ecx, ecx                    # v = target point - part point
    lea     r8, [rip+as_qw]
    lea     r9, [rip+as_pw]
    lea     r10, [rip+as_v]
8:  movss   xmm0, [r8+rcx*4]
    subss   xmm0, [r9+rcx*4]
    movss   [r10+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      8b
    lea     rdi, [rip+as_v]
    lea     rsi, [rip+as_mw]
    call    as_dot                      # xmm0 = v . m
    cmp     r14d, 2
    je      9f
    addss   xmm0, [rip+as_d]            # planes: along m by v.m + d
    xor     ecx, ecx
    lea     r8, [rip+as_mw]
81: movss   xmm1, [r8+rcx*4]
    mulss   xmm1, xmm0
    addss   xmm1, [rbx+OB_LOC+rcx*4]
    movss   [rbx+OB_LOC+rcx*4], xmm1
    inc     ecx
    cmp     ecx, 3
    jb      81b
    jmp     .Las_done
9:  xor     ecx, ecx                    # axes: by v less its part along m
    lea     r8, [rip+as_mw]
    lea     r9, [rip+as_v]
91: movss   xmm1, [r8+rcx*4]
    mulss   xmm1, xmm0
    movss   xmm2, [r9+rcx*4]
    subss   xmm2, xmm1
    addss   xmm2, [rbx+OB_LOC+rcx*4]
    movss   [rbx+OB_LOC+rcx*4], xmm2
    inc     ecx
    cmp     ecx, 3
    jb      91b
.Las_done:
    mov     dword ptr [rip+dirty], 1
    call    fmt_reset
    lea     rdi, [rip+s_as_done]
    call    fmt_str
    lea     rdi, [rbx+OB_NAME]
    call    fmt_str
    lea     rdi, [rip+s_as_to]
    call    fmt_str
    lea     rdi, [r13+OB_NAME]
    call    fmt_str
    lea     rdi, [rip+fmt_buf]
    call    log_line
    jmp     .Las_out
.Las_bad:
    lea     rdi, [rip+s_as_bad]
    lea     rsi, [rip+im_word]
    call    log_pair
    call    undo_drop_last
.Las_out:
    add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# as_ref(rdi=object, rsi=out point, rdx=out direction; r12=text) -> eax = 1
#   when read (r12 after it): a face of its mesh, or "axis px py pz dx dy dz"
as_ref:
    push    rbx
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    mov     rbx, rdi
    mov     r13, rsi
    mov     r14, rdx
    mov     rsi, r12
    call    im_next_word
    mov     [rsp], rsi
    test    eax, eax
    jz      8f
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_axis]
    call    str_eq
    test    eax, eax
    jz      3f
    xor     r15d, r15d                  # six values: the point, the way
    mov     rsi, [rsp]
1:  call    mx_word_expr
    test    eax, eax
    jz      8f
    lea     rax, [r13+r15*4]
    cmp     r15d, 3
    jb      2f
    lea     rax, [r14+r15*4-12]
2:  movss   [rax], xmm0
    inc     r15d
    cmp     r15d, 6
    jb      1b
    mov     r12, rsi
    mov     rdi, r14
    call    normalize
    jmp     7f
3:  cmp     dword ptr [rbx+OB_TYPE], OT_MESH   # a face: im_word is its number
    jne     8f
    mov     r15, [rbx+OB_MESH]
    test    r15, r15
    jz      8f
    mov     rsi, r12
    call    mx_num
    test    eax, eax
    jz      8f
    mov     r12, rsi
    cvttss2si eax, xmm0
    test    eax, eax
    js      8f
    cmp     eax, [r15+ME_NPOLYS]
    jae     8f
    mov     [rsp], eax
    mov     rdi, r15
    mov     esi, eax
    mov     rdx, r13
    call    poly_center
    mov     rdi, r15
    mov     esi, [rsp]
    call    poly_normal
    mov     rax, [rip+nrm]
    mov     [r14], rax
    mov     eax, [rip+nrm+8]
    mov     [r14+8], eax
    mov     rdi, r14
    call    normalize
7:  mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     rbx
    ret

# as_wpoint(rdi=object, rsi=point in its space, rdx=out) - in the world
as_wpoint:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rsi
    mov     r12, rdx
    lea     rsi, [rip+as_M]
    call    obj_matrix
    lea     rdx, [rip+as_M]
    xor     ecx, ecx
1:  movss   xmm0, [rdx+12]
    movss   xmm1, [rdx]
    mulss   xmm1, [rbx]
    addss   xmm0, xmm1
    movss   xmm1, [rdx+4]
    mulss   xmm1, [rbx+4]
    addss   xmm0, xmm1
    movss   xmm1, [rdx+8]
    mulss   xmm1, [rbx+8]
    addss   xmm0, xmm1
    movss   [r12+rcx*4], xmm0
    add     rdx, 16
    inc     ecx
    cmp     ecx, 3
    jb      1b
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# as_wdir(rdi=object, rsi=direction in its space, rdx=out) - in the world:
#   R (n / s), unit (a normal under the object's scale)
as_wdir:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12, rdx
    xor     ecx, ecx
1:  movss   xmm0, [rsi+rcx*4]
    movss   xmm1, [rbx+OB_SCALE+rcx*4]
    xorps   xmm2, xmm2
    comiss  xmm1, xmm2
    je      2f
    divss   xmm0, xmm1
2:  movss   [r12+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      1b
    lea     rdi, [rbx+OB_ROT]
    lea     rsi, [rip+as_Rd]
    call    o_euler_mat
    lea     rdi, [rip+as_Rd]
    mov     rsi, r12
    mov     rdx, r12
    call    o_mulv
    mov     rdi, r12
    call    normalize
    pop     r13
    pop     r12
    pop     rbx
    ret

# as_cross(rdi=a, rsi=b, rdx=out) ; as_dot(rdi=a, rsi=b) -> xmm0 ;
#   as_len(rdi=a) -> xmm0
as_cross:
    movss   xmm0, [rdi+4]
    mulss   xmm0, [rsi+8]
    movss   xmm1, [rdi+8]
    mulss   xmm1, [rsi+4]
    subss   xmm0, xmm1
    movss   [rdx], xmm0
    movss   xmm0, [rdi+8]
    mulss   xmm0, [rsi]
    movss   xmm1, [rdi]
    mulss   xmm1, [rsi+8]
    subss   xmm0, xmm1
    movss   [rdx+4], xmm0
    movss   xmm0, [rdi]
    mulss   xmm0, [rsi+4]
    movss   xmm1, [rdi+4]
    mulss   xmm1, [rsi]
    subss   xmm0, xmm1
    movss   [rdx+8], xmm0
    ret
as_dot:
    movss   xmm0, [rdi]
    mulss   xmm0, [rsi]
    movss   xmm1, [rdi+4]
    mulss   xmm1, [rsi+4]
    addss   xmm0, xmm1
    movss   xmm1, [rdi+8]
    mulss   xmm1, [rsi+8]
    addss   xmm0, xmm1
    ret
as_len:
    mov     rsi, rdi
    call    as_dot
    sqrtss  xmm0, xmm0
    ret

# as_perp(rdi=unit n) -> as_ax = an axis across it (n x X, or n x Z)
as_perp:
    sub     rsp, 24
    mov     dword ptr [rsp], 0x3f800000
    mov     dword ptr [rsp+4], 0
    mov     dword ptr [rsp+8], 0
    movss   xmm0, [rdi]
    andps   xmm0, [rip+as_absm]
    comiss  xmm0, [rip+as_09]
    jb      1f
    mov     dword ptr [rsp], 0
    mov     dword ptr [rsp+8], 0x3f800000
1:  lea     rsi, [rsp]
    lea     rdx, [rip+as_ax]
    call    as_cross
    add     rsp, 24
    ret
.section .rodata
.align 16
as_absm:        .long 0x7fffffff, 0x7fffffff, 0x7fffffff, 0x7fffffff
as_09:          .float 0.9
.text

.section .note.GNU-stack,"",@progbits
