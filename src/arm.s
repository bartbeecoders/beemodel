# =============================================================================
#  BeeModel - armatures and skinning.
#
#  An armature object (OT_ARMATURE) shows a display mesh - each bone an
#  octahedron from head to tail, posed - that carries the bones (ME_ARM):
#  up to 128, each a name, a parent, a rest head / tail / roll and a pose
#  (location, Euler rotation, scale, in the bone's own axes: Y along it).
#  Like curves, the block is shared with undo steps through the mesh and
#  copied with a new display mesh before a change.
#
#  Rest frame: Y = tail - head, X and Z square to it (rolled). A bone's
#  pose matrix M = M(parent) R(parent)^-1 R P (P from its location,
#  rotation and scale; parents come first), its skin matrix M R^-1.
#
#  An Armature modifier deforms a mesh by its skin weights (ME_WGT: four
#  bones and weights a vertex): linear blend of the skin matrices, or dual
#  quaternion blending (no candy wrapper at twisted joints), in parallel.
#  Automatic weights: heat diffusion over the mesh (each bone's heat
#  equation with the nearest bone as the source), the four largest kept.
# =============================================================================
.intel_syntax noprefix
.globl arm_mod_index
.include "const.inc"
.include "macros.inc"

.globl arm_ref
.globl arm_unref
.globl arm_of
.globl arm_rebuild
.globl arm_edit
.globl arm_create
.globl arm_chan
.globl arm_find_bone
.globl arm_skin
.globl arm_pose_mats
.globl arm_load
.globl arm_bone
.globl am_m
.globl am_r
.globl am_ov
.globl am_ovf
.globl am_owner
.globl m_mul
.globl m_inv
.globl pose_from_mat

.equ AR_REFS,   0
.equ AR_N,      4
.equ AR_ACT,    8                       # the active bone
.equ AR_BYTES,  16
.equ AR_BONES,  64
.equ AR_MAXB,   128
.equ BN_SZ,     128
.equ BN_NAME,   0                       # 24 bytes
.equ BN_PARENT, 24                      # -1: a root
.equ BN_HEAD,   28
.equ BN_TAIL,   40
.equ BN_ROLL,   52
.equ BN_SEL,    56                      # u8: 1 head, 2 tail, 4 the bone
.equ BN_CONN,   57                      # u8: its head is its parent's tail
.equ BN_LOC,    60                      # the pose: location,
.equ BN_ROT,    72                      #  Euler XYZ (radians),
.equ BN_SCALE,  84                      #  scale (as OB_LOC / ROT / SCALE)
.equ AR_SZ,     AR_BONES + AR_MAXB*BN_SZ
.equ MAP_ANON_PRIV, 0x22

# d = a x b (t: scratch; lane 3 stays 0 when a's and b's are)
.macro CROSSAM d, a, b, t
    movaps  \d, \b
    shufps  \d, \d, 0xC9
    mulps   \d, \a
    movaps  \t, \a
    shufps  \t, \t, 0xC9
    mulps   \t, \b
    subps   \d, \t
    shufps  \d, \d, 0xC9
.endm

.section .rodata
.align 16
am_one:         .float 1.0
am_half:        .float 0.5
am_tenth:       .float 0.1
am_tiny:        .float 1.0e-8
am_eps:         .float 1.0e-6
am_two:         .float 2.0
am_ident:       .float 1, 0, 0, 0,  0, 1, 0, 0,  0, 0, 1, 0
s_arm:          .asciz "Armature"
s_bone:         .asciz "Bone"

.section .bss
.align 16
am_m:           .skip 48*AR_MAXB        # pose matrices (armature space)
am_r:           .skip 48*AR_MAXB        # rest matrices
am_k:           .skip 48*AR_MAXB        # skin matrices (in the mesh's space)
am_ov:          .skip 48*AR_MAXB        # IK's poses (rig.s), used where
am_ovf:         .skip AR_MAXB           #  these are set
am_owner:       .skip 8                 # the armature object posed (IK), or 0
am_t:           .skip 64
am_t2:          .skip 64
.text

# -----------------------------------------------------------------------------
# 3x4 matrices (row-major, translation in the 4th column: obj_matrix's)
# -----------------------------------------------------------------------------
# m_mul(rdi=out, rsi=a, rdx=b) - out = a b (out may not be a or b)
m_mul:
    xor     ecx, ecx                    # row
1:  imul    r8, rcx, 16
    xor     r9d, r9d                    # column
2:  movss   xmm0, [rsi+r8]
    mulss   xmm0, [rdx+r9*4]
    movss   xmm1, [rsi+r8+4]
    mulss   xmm1, [rdx+r9*4+16]
    addss   xmm0, xmm1
    movss   xmm1, [rsi+r8+8]
    mulss   xmm1, [rdx+r9*4+32]
    addss   xmm0, xmm1
    cmp     r9d, 3
    jne     3f
    addss   xmm0, [rsi+r8+12]
3:  lea     rax, [rdi+r8]
    movss   [rax+r9*4], xmm0
    inc     r9d
    cmp     r9d, 4
    jb      2b
    inc     ecx
    cmp     ecx, 3
    jb      1b
    ret

# m_inv(rdi=out, rsi=a) - the inverse of an affine 3x4 (a general 3x3)
m_inv:
    push    rbx
    sub     rsp, 48
    mov     rbx, rsi
    # cofactors: c00 = a11 a22 - a12 a21 ...
    movss   xmm0, [rbx+20]
    mulss   xmm0, [rbx+40]
    movss   xmm1, [rbx+24]
    mulss   xmm1, [rbx+36]
    subss   xmm0, xmm1
    movss   [rsp], xmm0                 # c00
    movss   xmm0, [rbx+24]
    mulss   xmm0, [rbx+32]
    movss   xmm1, [rbx+16]
    mulss   xmm1, [rbx+40]
    subss   xmm0, xmm1
    movss   [rsp+4], xmm0               # c01
    movss   xmm0, [rbx+16]
    mulss   xmm0, [rbx+36]
    movss   xmm1, [rbx+20]
    mulss   xmm1, [rbx+32]
    subss   xmm0, xmm1
    movss   [rsp+8], xmm0               # c02
    movss   xmm2, [rbx]                 # det = a00 c00 + a01 c01 + a02 c02
    mulss   xmm2, [rsp]
    movss   xmm1, [rbx+4]
    mulss   xmm1, [rsp+4]
    addss   xmm2, xmm1
    movss   xmm1, [rbx+8]
    mulss   xmm1, [rsp+8]
    addss   xmm2, xmm1
    movss   xmm1, xmm2
    andps   xmm1, [rip+am_absm]
    comiss  xmm1, [rip+am_tiny]
    ja      1f
    lea     rsi, [rip+am_ident]         # singular: identity
    mov     ecx, 48
    rep     movsb
    jmp     9f
1:  movss   xmm3, [rip+am_one]
    divss   xmm3, xmm2                  # 1 / det
    # inverse row r, column c = cofactor(c, r) / det
    movss   xmm0, [rsp]
    mulss   xmm0, xmm3
    movss   [rdi], xmm0                 # i00 = c00
    movss   xmm0, [rbx+8]               # i01 = c10 = a02 a21 - a01 a22
    mulss   xmm0, [rbx+36]
    movss   xmm1, [rbx+4]
    mulss   xmm1, [rbx+40]
    subss   xmm0, xmm1
    mulss   xmm0, xmm3
    movss   [rdi+4], xmm0
    movss   xmm0, [rbx+4]               # i02 = c20 = a01 a12 - a02 a11
    mulss   xmm0, [rbx+24]
    movss   xmm1, [rbx+8]
    mulss   xmm1, [rbx+20]
    subss   xmm0, xmm1
    mulss   xmm0, xmm3
    movss   [rdi+8], xmm0
    movss   xmm0, [rsp+4]
    mulss   xmm0, xmm3
    movss   [rdi+16], xmm0              # i10 = c01
    movss   xmm0, [rbx]                 # i11 = c11 = a00 a22 - a02 a20
    mulss   xmm0, [rbx+40]
    movss   xmm1, [rbx+8]
    mulss   xmm1, [rbx+32]
    subss   xmm0, xmm1
    mulss   xmm0, xmm3
    movss   [rdi+20], xmm0
    movss   xmm0, [rbx+8]               # i12 = c21 = a02 a10 - a00 a12
    mulss   xmm0, [rbx+16]
    movss   xmm1, [rbx]
    mulss   xmm1, [rbx+24]
    subss   xmm0, xmm1
    mulss   xmm0, xmm3
    movss   [rdi+24], xmm0
    movss   xmm0, [rsp+8]
    mulss   xmm0, xmm3
    movss   [rdi+32], xmm0              # i20 = c02
    movss   xmm0, [rbx+4]               # i21 = c12 = a01 a20 - a00 a21
    mulss   xmm0, [rbx+32]
    movss   xmm1, [rbx]
    mulss   xmm1, [rbx+36]
    subss   xmm0, xmm1
    mulss   xmm0, xmm3
    movss   [rdi+36], xmm0
    movss   xmm0, [rbx]                 # i22 = c22 = a00 a11 - a01 a10
    mulss   xmm0, [rbx+20]
    movss   xmm1, [rbx+4]
    mulss   xmm1, [rbx+16]
    subss   xmm0, xmm1
    mulss   xmm0, xmm3
    movss   [rdi+40], xmm0
    xor     ecx, ecx                    # t' = -inv t
2:  imul    r8, rcx, 16
    movss   xmm0, [rdi+r8]
    mulss   xmm0, [rbx+12]
    movss   xmm1, [rdi+r8+4]
    mulss   xmm1, [rbx+28]
    addss   xmm0, xmm1
    movss   xmm1, [rdi+r8+8]
    mulss   xmm1, [rbx+44]
    addss   xmm0, xmm1
    xorps   xmm1, xmm1
    subss   xmm1, xmm0
    movss   [rdi+r8+12], xmm1
    inc     ecx
    cmp     ecx, 3
    jb      2b
9:  add     rsp, 48
    pop     rbx
    ret

# -----------------------------------------------------------------------------
# The block
# -----------------------------------------------------------------------------
arm_new:
    mov     esi, (AR_SZ+4095) & -4096
    xor     edi, edi
    mov     edx, PROT_RW
    mov     r10d, MAP_ANON_PRIV
    mov     r8, -1
    xor     r9d, r9d
    mov     eax, SYS_MMAP
    syscall
    cmp     rax, -4096
    jb      1f
    xor     eax, eax
    ret
1:  mov     qword ptr [rax+AR_BYTES], (AR_SZ+4095) & -4096
    mov     dword ptr [rax+AR_REFS], 1
    ret
arm_ref:
    test    rdi, rdi
    jz      1f
    inc     dword ptr [rdi+AR_REFS]
1:  ret
arm_unref:
    test    rdi, rdi
    jz      1f
    dec     dword ptr [rdi+AR_REFS]
    jnz     1f
    mov     rsi, [rdi+AR_BYTES]
    mov     eax, SYS_MUNMAP
    syscall
1:  ret
arm_copy:
    push    rbx
    mov     rbx, rdi
    call    arm_new
    test    rax, rax
    jz      9f
    lea     rsi, [rbx+AR_N]
    lea     rdi, [rax+AR_N]
    mov     ecx, 8
    rep     movsb
    lea     rsi, [rbx+AR_BONES]
    lea     rdi, [rax+AR_BONES]
    mov     ecx, AR_MAXB*BN_SZ
    rep     movsb
9:  pop     rbx
    ret

# arm_bone(rdi=block, esi=bone) -> rax = its record
arm_bone:
    imul    rax, rsi, BN_SZ
    lea     rax, [rdi+AR_BONES+rax]
    ret

# arm_of(rdi=object or 0) -> rax = its bones (an armature), or 0
arm_of:
    xor     eax, eax
    test    rdi, rdi
    jz      9f
    cmp     dword ptr [rdi+OB_TYPE], OT_ARMATURE
    jne     9f
    mov     rcx, [rdi+OB_MESH]
    test    rcx, rcx
    jz      9f
    mov     rax, [rcx+ME_ARM]
9:  ret

# arm_find_bone(rdi=block, rsi=name) -> eax = its index, or -1
arm_find_bone:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12, rsi
    xor     r13d, r13d
1:  cmp     r13d, [rbx+AR_N]
    jae     8f
    mov     rdi, rbx
    mov     esi, r13d
    call    arm_bone
    mov     rdi, rax
    mov     rsi, r12
    call    str_eq
    test    eax, eax
    jnz     2f
    inc     r13d
    jmp     1b
2:  mov     eax, r13d
    jmp     9f
8:  mov     eax, -1
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# rest_mat(rdi=bone, rsi=out) - its rest frame: Y head -> tail, X Z rolled
rest_mat:
    push    rbx
    push    r12
    sub     rsp, 40
    mov     rbx, rdi
    mov     r12, rsi
    movss   xmm0, [rbx+BN_TAIL]         # Y
    subss   xmm0, [rbx+BN_HEAD]
    movss   xmm1, [rbx+BN_TAIL+4]
    subss   xmm1, [rbx+BN_HEAD+4]
    movss   xmm2, [rbx+BN_TAIL+8]
    subss   xmm2, [rbx+BN_HEAD+8]
    call    norm3
    movss   [rsp], xmm0
    movss   [rsp+4], xmm1
    movss   [rsp+8], xmm2
    # X = Y x (0 0 1), or Y x (1 0 0) along Z
    movss   xmm3, xmm2
    andps   xmm3, [rip+am_absm]
    comiss  xmm3, [rip+am_near1]
    jae     1f
    movss   xmm3, xmm1                  # (y, -x, 0)
    xorps   xmm4, xmm4
    subss   xmm4, xmm0
    xorps   xmm5, xmm5
    jmp     2f
1:  xorps   xmm3, xmm3                  # (0, z, -y)
    movss   xmm4, xmm2
    xorps   xmm5, xmm5
    subss   xmm5, xmm1
2:  movss   xmm0, xmm3
    movss   xmm1, xmm4
    movss   xmm2, xmm5
    call    norm3
    movss   [rsp+12], xmm0              # X
    movss   [rsp+16], xmm1
    movss   [rsp+20], xmm2
    # Z = X x Y
    movss   xmm0, [rsp+16]
    mulss   xmm0, [rsp+8]
    movss   xmm1, [rsp+20]
    mulss   xmm1, [rsp+4]
    subss   xmm0, xmm1
    movss   [rsp+24], xmm0
    movss   xmm0, [rsp+20]
    mulss   xmm0, [rsp]
    movss   xmm1, [rsp+12]
    mulss   xmm1, [rsp+8]
    subss   xmm0, xmm1
    movss   [rsp+28], xmm0
    movss   xmm0, [rsp+12]
    mulss   xmm0, [rsp+4]
    movss   xmm1, [rsp+16]
    mulss   xmm1, [rsp]
    subss   xmm0, xmm1
    movss   [rsp+32], xmm0
    movss   xmm0, [rbx+BN_ROLL]         # roll: X' = X c + Z s, Z' = Z c - X s
    call    sincos
    xor     ecx, ecx
3:  movss   xmm2, [rsp+12+rcx*4]
    movss   xmm3, [rsp+24+rcx*4]
    movss   xmm4, xmm2
    mulss   xmm4, xmm1
    movss   xmm5, xmm3
    mulss   xmm5, xmm0
    addss   xmm4, xmm5
    mulss   xmm3, xmm1
    mulss   xmm2, xmm0
    subss   xmm3, xmm2
    imul    rdx, rcx, 16                # row c: X_c Y_c Z_c head_c
    movss   [r12+rdx], xmm4
    movss   xmm5, [rsp+rcx*4]
    movss   [r12+rdx+4], xmm5
    movss   [r12+rdx+8], xmm3
    movss   xmm5, [rbx+BN_HEAD+rcx*4]
    movss   [r12+rdx+12], xmm5
    inc     ecx
    cmp     ecx, 3
    jb      3b
    add     rsp, 40
    pop     r12
    pop     rbx
    ret

# norm3(xmm0..2) -> the same, unit (unchanged when ~0)
norm3:
    movss   xmm3, xmm0
    mulss   xmm3, xmm0
    movss   xmm4, xmm1
    mulss   xmm4, xmm1
    addss   xmm3, xmm4
    movss   xmm4, xmm2
    mulss   xmm4, xmm2
    addss   xmm3, xmm4
    sqrtss  xmm3, xmm3
    comiss  xmm3, [rip+am_tiny]
    jbe     1f
    divss   xmm0, xmm3
    divss   xmm1, xmm3
    divss   xmm2, xmm3
1:  ret

# arm_pose_mats(rdi=block) - am_r (rest) and am_m (pose) for every bone;
#   then, when am_owner has IK constraints, their chains solved (rig.s) and
#   the bones posed again with those poses
arm_pose_mats:
    push    rbx
    mov     rbx, rdi
    lea     rdi, [rip+am_ovf]
    xor     eax, eax
    mov     ecx, AR_MAXB
    rep     stosb
    mov     rdi, rbx
    call    pose_pass
    mov     rdi, rbx
    mov     rsi, [rip+am_owner]
    call    rig_ik
    test    eax, eax
    jz      1f
    mov     rdi, rbx
    call    pose_pass
1:  pop     rbx
    ret

pose_pass:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 112
    mov     rbx, rdi
    xor     r12d, r12d
1:  cmp     r12d, [rbx+AR_N]
    jae     9f
    mov     rdi, rbx
    mov     esi, r12d
    call    arm_bone
    mov     r13, rax
    imul    rsi, r12, 48                # rest
    lea     rax, [rip+am_r]
    add     rsi, rax
    mov     rdi, r13
    call    rest_mat
    lea     rax, [rip+am_ovf]
    cmp     byte ptr [rax+r12], 0
    jne     4f
    lea     rdi, [r13+BN_LOC-OB_LOC]    # P (obj_matrix reads the same layout)
    lea     rsi, [rsp]
    call    obj_matrix
    jmp     5f
4:  imul    rsi, r12, 48                # (IK's)
    lea     rax, [rip+am_ov]
    add     rsi, rax
    lea     rdi, [rsp]
    mov     ecx, 48
    rep     movsb
5:
    imul    rdx, r12, 48
    lea     rax, [rip+am_r]
    add     rdx, rax
    lea     rdi, [rsp+48]               # R P
    lea     rsi, [rdx]
    lea     rdx, [rsp]
    call    m_mul
    imul    rdi, r12, 48
    lea     rax, [rip+am_m]
    add     rdi, rax
    mov     eax, [r13+BN_PARENT]
    test    eax, eax
    js      2f
    cmp     eax, r12d
    jae     2f
    # M = M(parent) R(parent)^-1 (R P)
    imul    rsi, rax, 48
    lea     rcx, [rip+am_r]
    add     rsi, rcx
    push    rdi
    push    rax
    lea     rdi, [rip+am_t]
    call    m_inv
    pop     rax
    imul    rsi, rax, 48
    lea     rcx, [rip+am_m]
    add     rsi, rcx
    lea     rdi, [rip+am_t2]
    lea     rdx, [rip+am_t]
    call    m_mul
    pop     rdi
    lea     rsi, [rip+am_t2]
    lea     rdx, [rsp+48]
    call    m_mul
    jmp     3f
2:  lea     rsi, [rsp+48]               # a root: M = R P
    mov     ecx, 48
    rep     movsb
3:  inc     r12d
    jmp     1b
9:  add     rsp, 112
    pop     r13
    pop     r12
    pop     rbx
    ret

# -----------------------------------------------------------------------------
# The display mesh: an octahedron a bone, posed
# -----------------------------------------------------------------------------
# arm_mesh(rdi=block) -> rax = the mesh (carrying the block), or 0
arm_mesh:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 72
    mov     rbx, rdi
    call    arm_pose_mats
    mov     edi, [rbx+AR_N]
    imul    edi, edi, 6
    inc     edi
    mov     esi, [rbx+AR_N]
    imul    esi, esi, 24
    inc     esi
    mov     edx, [rbx+AR_N]
    shl     edx, 3
    inc     edx
    call    mesh_new
    test    rax, rax
    jz      9f
    mov     r12, rax
    xor     r13d, r13d
1:  cmp     r13d, [rbx+AR_N]
    jae     8f
    mov     rdi, rbx
    mov     esi, r13d
    call    arm_bone
    movss   xmm0, [rax+BN_TAIL]         # its length
    subss   xmm0, [rax+BN_HEAD]
    mulss   xmm0, xmm0
    movss   xmm1, [rax+BN_TAIL+4]
    subss   xmm1, [rax+BN_HEAD+4]
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    movss   xmm1, [rax+BN_TAIL+8]
    subss   xmm1, [rax+BN_HEAD+8]
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    sqrtss  xmm0, xmm0
    movss   [rsp+60], xmm0
    mov     r14d, [r12+ME_NVERTS]       # six corners in the bone's frame
    xor     ecx, ecx
2:  cmp     ecx, 6
    jae     3f
    mov     [rsp+64], ecx
    lea     rax, [rip+oct_pts]
    imul    edx, ecx, 12
    movss   xmm0, [rax+rdx]
    mulss   xmm0, [rsp+60]
    movss   [rsp+48], xmm0
    movss   xmm0, [rax+rdx+4]
    mulss   xmm0, [rsp+60]
    movss   [rsp+52], xmm0
    movss   xmm0, [rax+rdx+8]
    mulss   xmm0, [rsp+60]
    movss   [rsp+56], xmm0
    imul    rdi, r13, 48
    lea     rax, [rip+am_m]
    add     rdi, rax
    lea     rsi, [rsp+48]
    lea     rdx, [rsp]
    call    xform_point
    movss   xmm0, [rsp]
    movss   xmm1, [rsp+4]
    movss   xmm2, [rsp+8]
    mov     rdi, r12
    call    mesh_add_vert
    mov     ecx, [rsp+64]
    inc     ecx
    jmp     2b
3:  xor     ecx, ecx                    # eight faces
4:  cmp     ecx, 8
    jae     5f
    mov     [rsp+64], ecx
    lea     rax, [rip+oct_faces]
    lea     edx, [rcx*2+rcx]
    movzx   r8d, byte ptr [rax+rdx]
    add     r8d, r14d
    mov     [rsp], r8d
    movzx   r8d, byte ptr [rax+rdx+1]
    add     r8d, r14d
    mov     [rsp+4], r8d
    movzx   r8d, byte ptr [rax+rdx+2]
    add     r8d, r14d
    mov     [rsp+8], r8d
    mov     rdi, r12
    lea     rsi, [rsp]
    mov     edx, 3
    call    mesh_add_poly
    mov     ecx, [rsp+64]
    inc     ecx
    jmp     4b
5:  inc     r13d
    jmp     1b
8:  mov     rdi, r12
    call    mesh_finish
    mov     [r12+ME_ARM], rbx
    inc     dword ptr [rbx+AR_REFS]
    mov     rax, r12
9:  add     rsp, 72
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# arm_rebuild(rdi=object) - its display mesh made again (from its bones)
arm_rebuild:
    push    rbx
    mov     rbx, rdi
    mov     [rip+am_owner], rdi
    call    arm_of
    test    rax, rax
    jz      9f
    mov     rdi, rax
    call    arm_mesh
    test    rax, rax
    jz      9f
    mov     rdi, [rbx+OB_MESH]
    mov     [rbx+OB_MESH], rax
    call    mesh_unref
    inc     dword ptr [rip+arm_ver]     # (skinned meshes evaluate again)
    mov     dword ptr [rip+dirty], 1
9:  pop     rbx
    ret

# arm_edit(rdi=object) -> rax = its bones, ready to change in place (copied
#   with a new display mesh when an undo step or another object shares it)
arm_edit:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    mov     [rip+am_owner], rdi
    call    arm_of
    test    rax, rax
    jz      9f
    mov     r12, rax
    mov     rcx, [rbx+OB_MESH]
    cmp     dword ptr [rcx+ME_REFS], 1
    jne     1f
    cmp     dword ptr [r12+AR_REFS], 1
    jne     1f
    mov     rax, r12
    jmp     9f
1:  mov     rdi, r12
    call    arm_copy
    test    rax, rax
    jz      9f
    mov     r12, rax
    mov     rdi, rax
    call    arm_mesh
    push    rax
    push    rax
    mov     rdi, r12
    call    arm_unref                   # (its mesh holds it)
    pop     rax
    pop     rax
    test    rax, rax
    jz      9f
    mov     rdi, [rbx+OB_MESH]
    mov     [rbx+OB_MESH], rax
    call    mesh_unref
    inc     dword ptr [rip+arm_ver]
    mov     rax, r12
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# arm_add_bone(rdi=block, rsi=name or 0, edx=parent (-1), rcx=head, r8=tail)
#   -> eax = its index, or -1 (full, or the parent is not there)
arm_add_bone:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13d, edx
    mov     r14, rcx
    mov     r15, r8
    mov     eax, [rbx+AR_N]
    cmp     eax, AR_MAXB
    jae     8f
    cmp     r13d, eax
    jge     8f
    mov     rdi, rbx
    mov     esi, eax
    call    arm_bone
    mov     rdi, rax
    push    rax
    xor     eax, eax
    mov     ecx, BN_SZ
    rep     stosb
    pop     rdi
    mov     [rdi+BN_PARENT], r13d
    mov     rax, [r14]
    mov     [rdi+BN_HEAD], rax
    mov     eax, [r14+8]
    mov     [rdi+BN_HEAD+8], eax
    mov     rax, [r15]
    mov     [rdi+BN_TAIL], rax
    mov     eax, [r15+8]
    mov     [rdi+BN_TAIL+8], eax
    mov     eax, [rip+am_one]
    mov     [rdi+BN_SCALE], eax
    mov     [rdi+BN_SCALE+4], eax
    mov     [rdi+BN_SCALE+8], eax
    test    r12, r12                    # its name (or "Bone.n")
    jz      1f
    mov     rsi, r12
    mov     ecx, 23
2:  mov     al, [rsi]
    mov     [rdi], al
    test    al, al
    jz      3f
    inc     rsi
    inc     rdi
    dec     ecx
    jnz     2b
    jmp     3f
1:  push    rdi
    push    rdi
    call    fmt_reset
    lea     rdi, [rip+s_bone]
    call    fmt_str
    mov     eax, [rbx+AR_N]
    test    eax, eax
    jz      11f
    mov     edi, '.'
    call    fmt_char
    mov     edi, [rbx+AR_N]
    call    fmt_int
11: pop     rdi
    pop     rdi
    lea     rsi, [rip+fmt_buf]
    mov     ecx, 23
    rep     movsb
3:  mov     eax, [rbx+AR_N]
    mov     [rbx+AR_ACT], eax
    inc     dword ptr [rbx+AR_N]
    jmp     9f
8:  mov     eax, -1
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# arm_create(rsi=name or 0) -> eax = a new armature object (one bone, up 1)
arm_create:
    push    rbx
    push    r12
    sub     rsp, 40
    mov     r12, rsi
    test    r12, r12
    jnz     1f
    lea     r12, [rip+s_arm]
1:  call    arm_new
    test    rax, rax
    jz      8f
    mov     rbx, rax
    mov     qword ptr [rip+am_owner], 0
    xorps   xmm0, xmm0
    movups  [rsp], xmm0
    movups  [rsp+16], xmm0
    mov     eax, [rip+am_one]
    mov     [rsp+16+4], eax             # tail (0 1 0)
    mov     rdi, rbx
    xor     esi, esi
    mov     edx, -1
    lea     rcx, [rsp]
    lea     r8, [rsp+16]
    call    arm_add_bone
    mov     rdi, rbx
    call    arm_mesh
    push    rax
    push    rax
    mov     rdi, rbx
    call    arm_unref
    pop     rdx
    pop     rdx
    test    rdx, rdx
    jz      8f
    mov     edi, OT_ARMATURE
    mov     rsi, r12
    call    obj_new
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 40
    pop     r12
    pop     rbx
    ret

# arm_chan(edi=armature uid, esi=bone, edx=property 0..8 (loc, rot, scale),
#   xmm0=value, ecx=1 to set) -> xmm0 = its value, eax = 1 (0: not there).
#   A set copies the bones when shared and marks the armature to show anew
arm_chan:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 24
    movss   [rsp], xmm0
    mov     r12d, esi
    mov     r13d, edx
    mov     r14d, ecx
    call    obj_by_uid
    test    rax, rax
    jz      8f
    mov     rbx, rax
    cmp     r13d, 9
    jae     8f
    mov     rdi, rbx
    call    arm_of
    test    rax, rax
    jz      8f
    cmp     r12d, [rax+AR_N]
    jae     8f
    test    r14d, r14d
    jz      1f
    mov     rdi, rbx
    call    arm_edit
    test    rax, rax
    jz      8f
    mov     rdi, rax
    mov     esi, r12d
    call    arm_bone
    movss   xmm0, [rsp]
    movss   [rax+BN_LOC+r13*4], xmm0
    or      dword ptr [rbx+OB_FLAGS], OBF_ARM_DIRTY
    mov     eax, 1
    jmp     9f
1:  mov     rdi, rax
    mov     esi, r12d
    call    arm_bone
    movss   xmm0, [rax+BN_LOC+r13*4]
    mov     eax, 1
    jmp     9f
8:  xorps   xmm0, xmm0
    xor     eax, eax
9:  add     rsp, 24
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# arm_refresh - armatures whose pose changed show it (after a frame)
.globl arm_refresh
arm_refresh:
    push    rbx
    push    r12
    sub     rsp, 8
    xor     ebx, ebx
1:  cmp     ebx, [rip+obj_count]
    jae     9f
    mov     edi, ebx
    call    obj_at
    test    dword ptr [rax+OB_FLAGS], OBF_ARM_DIRTY
    jz      2f
    and     dword ptr [rax+OB_FLAGS], ~OBF_ARM_DIRTY
    mov     rdi, rax
    call    arm_rebuild
2:  inc     ebx
    jmp     1b
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

.section .rodata
.align 4
oct_pts:        .float 0, 0, 0,  0, 1, 0,  0.1, 0.1, 0,  0, 0.1, 0.1,  -0.1, 0.1, 0,  0, 0.1, -0.1
oct_faces:      .byte 0, 3, 2,  0, 4, 3,  0, 5, 4,  0, 2, 5,  1, 2, 3,  1, 3, 4,  1, 4, 5,  1, 5, 2
.align 16
am_absm:        .long 0x7fffffff, 0, 0, 0
am_near1:       .float 0.99
.text

# -----------------------------------------------------------------------------
# Skinning
# -----------------------------------------------------------------------------
.section .bss
.align 16
sk_dq:          .skip 32*AR_MAXB        # dual quaternions: real xyzw, dual xyzw
sk_in:          .skip 8                 # the mesh deformed,
sk_out:         .skip 8                 #  its copy,
sk_mode:        .skip 4                 #  0 linear, 1 dual quaternion
sk_nb:          .skip 4
.text

# arm_skin(rdi=mesh, rsi=mesh object, edx=armature object handle, ecx=mode)
#   -> rax = a deformed copy, or 0 (no armature, no weights)
arm_skin:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 104
    mov     rbx, rdi
    mov     r12, rsi
    mov     [rip+sk_mode], ecx
    mov     edi, edx
    call    obj_get
    test    rax, rax
    jz      8f
    mov     r13, rax                    # the armature object
    mov     [rip+am_owner], rax
    mov     rdi, rax
    call    arm_of
    test    rax, rax
    jz      8f
    mov     r14, rax
    cmp     qword ptr [rbx+ME_WGT], 0
    je      8f
    mov     rdi, r14
    call    arm_pose_mats
    mov     eax, [r14+AR_N]
    mov     [rip+sk_nb], eax
    mov     rdi, r12                    # mesh -> armature space and back
    lea     rsi, [rsp]
    call    obj_matrix
    mov     rdi, r13
    lea     rsi, [rsp+48]
    call    obj_matrix
    lea     rdi, [rip+am_t]             # A^-1 Mesh
    lea     rsi, [rsp+48]
    call    m_inv
    lea     rdi, [rip+am_t2]
    lea     rsi, [rip+am_t]
    lea     rdx, [rsp]
    call    m_mul
    lea     rdi, [rsp+48]               # (A^-1 Mesh)^-1 at rsp+48 (no A)
    lea     rsi, [rip+am_t2]
    call    m_inv
    xor     ecx, ecx                    # S = (A^-1 Mesh)^-1 M R^-1 (A^-1 Mesh)
1:  cmp     ecx, [r14+AR_N]
    jae     2f
    mov     [rsp+96], ecx
    imul    rsi, rcx, 48
    lea     rax, [rip+am_r]
    add     rsi, rax
    lea     rdi, [rip+am_t]
    call    m_inv
    mov     ecx, [rsp+96]
    imul    rsi, rcx, 48
    lea     rax, [rip+am_m]
    add     rsi, rax
    lea     rdi, [rsp]                  # (M R^-1) at rsp (the mesh matrix is used)
    lea     rdx, [rip+am_t]
    call    m_mul
    lea     rdi, [rip+am_t]
    lea     rsi, [rsp]
    lea     rdx, [rip+am_t2]
    call    m_mul
    mov     ecx, [rsp+96]
    imul    rdi, rcx, 48
    lea     rax, [rip+am_k]
    add     rdi, rax
    lea     rsi, [rsp+48]
    lea     rdx, [rip+am_t]
    call    m_mul
    mov     ecx, [rsp+96]
    cmp     dword ptr [rip+sk_mode], 0
    je      11f
    imul    rdi, rcx, 48
    lea     rax, [rip+am_k]
    add     rdi, rax
    imul    rsi, rcx, 32
    lea     rax, [rip+sk_dq]
    add     rsi, rax
    call    mat_dq
11: mov     ecx, [rsp+96]
    inc     ecx
    jmp     1b
2:  mov     rdi, rbx                    # a copy, then its points moved
    call    mesh_copy
    test    rax, rax
    jz      8f
    mov     [rip+sk_out], rax
    mov     [rip+sk_in], rbx
    lea     rdi, [rip+sk_job]
    xor     esi, esi
    mov     edx, [rbx+ME_NVERTS]
    mov     ecx, 4096
    call    parallel_for
    mov     rdi, [rip+sk_out]
    call    mesh_bbox
    mov     rax, [rip+sk_out]
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 104
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# sk_job(esi=begin, edx=end) - those vertices skinned
sk_job:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 80
    mov     r12d, esi
    mov     r13d, edx
    mov     r14, [rip+sk_in]
    mov     r15, [rip+sk_out]
.Lsj_v:
    cmp     r12d, r13d
    jae     .Lsj_out
    imul    rbx, r12, 20
    add     rbx, [r14+ME_WGT]           # its bones and weights
    imul    rax, r12, 12
    add     rax, [r14+ME_POS]
    movss   xmm0, [rax]
    movss   [rsp], xmm0
    movss   xmm0, [rax+4]
    movss   [rsp+4], xmm0
    movss   xmm0, [rax+8]
    movss   [rsp+8], xmm0
    cmp     dword ptr [rip+sk_mode], 0
    jne     .Lsj_dq
    xorps   xmm0, xmm0                  # linear: sum w (S p)
    movss   [rsp+16], xmm0
    movss   [rsp+20], xmm0
    movss   [rsp+24], xmm0
    movss   [rsp+28], xmm0              # sum w
    xor     ecx, ecx
1:  cmp     ecx, 4
    jae     2f
    movzx   eax, byte ptr [rbx+rcx]
    cmp     eax, [rip+sk_nb]
    jae     11f
    movss   xmm7, [rbx+4+rcx*4]
    xorps   xmm6, xmm6
    comiss  xmm7, xmm6
    jbe     11f
    imul    rdi, rax, 48
    lea     rdx, [rip+am_k]
    add     rdi, rdx
    lea     rsi, [rsp]
    lea     rdx, [rsp+32]
    push    rcx
    push    rcx
    call    xform_point
    pop     rcx
    pop     rcx
    movss   xmm7, [rbx+4+rcx*4]
    xor     edx, edx
12: movss   xmm0, [rsp+32+rdx*4]
    mulss   xmm0, xmm7
    addss   xmm0, [rsp+16+rdx*4]
    movss   [rsp+16+rdx*4], xmm0
    inc     edx
    cmp     edx, 3
    jb      12b
    addss   xmm7, [rsp+28]
    movss   [rsp+28], xmm7
11: inc     ecx
    jmp     1b
2:  movss   xmm7, [rsp+28]
    comiss  xmm7, [rip+am_eps]
    jbe     .Lsj_next                   # no bones: as it was
    imul    rax, r12, 12
    add     rax, [r15+ME_POS]
    xor     edx, edx
3:  movss   xmm0, [rsp+16+rdx*4]
    divss   xmm0, xmm7
    movss   [rax+rdx*4], xmm0
    inc     edx
    cmp     edx, 3
    jb      3b
    jmp     .Lsj_next
.Lsj_dq:                                # dual quaternions: blend, normalize
    xorps   xmm0, xmm0
    movups  [rsp+16], xmm0              # real
    movups  [rsp+32], xmm0              # dual
    mov     dword ptr [rsp+48], -1      # the first bone (for signs)
    xor     ecx, ecx
4:  cmp     ecx, 4
    jae     5f
    movzx   eax, byte ptr [rbx+rcx]
    cmp     eax, [rip+sk_nb]
    jae     41f
    movss   xmm7, [rbx+4+rcx*4]
    xorps   xmm6, xmm6
    comiss  xmm7, xmm6
    jbe     41f
    imul    rdx, rax, 32
    lea     rsi, [rip+sk_dq]
    add     rsi, rdx
    movups  xmm1, [rsi]
    movups  xmm2, [rsi+16]
    cmp     dword ptr [rsp+48], -1
    jne     42f
    mov     [rsp+48], eax
    movups  [rsp+64], xmm1              # (the first one's real part)
42: movups  xmm3, [rsp+64]
    dpps    xmm3, xmm1, 0xf1
    xorps   xmm4, xmm4
    comiss  xmm3, xmm4
    jae     43f
    xorps   xmm7, [rip+am_neg]          # opposite hemisphere: negative weight
43: shufps  xmm7, xmm7, 0
    mulps   xmm1, xmm7
    mulps   xmm2, xmm7
    movups  xmm3, [rsp+16]
    addps   xmm3, xmm1
    movups  [rsp+16], xmm3
    movups  xmm3, [rsp+32]
    addps   xmm3, xmm2
    movups  [rsp+32], xmm3
41: inc     ecx
    jmp     4b
5:  cmp     dword ptr [rsp+48], -1
    je      .Lsj_next
    movups  xmm1, [rsp+16]              # normalize by |real|
    movaps  xmm3, xmm1
    dpps    xmm3, xmm1, 0xff
    sqrtps  xmm3, xmm3
    movss   xmm4, xmm3
    comiss  xmm4, [rip+am_eps]
    jbe     .Lsj_next
    divps   xmm1, xmm3
    movups  xmm2, [rsp+32]
    divps   xmm2, xmm3
    lea     rdi, [rsp]                  # p' = r p r* + t
    imul    rsi, r12, 12
    add     rsi, [r15+ME_POS]
    call    dq_apply
.Lsj_next:
    inc     r12d
    jmp     .Lsj_v
.Lsj_out:
    add     rsp, 80
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# dq_apply(xmm1=real (x y z w), xmm2=dual, rdi=point, rsi=out)
dq_apply:
    sub     rsp, 72
    movups  [rsp], xmm1
    movups  [rsp+16], xmm2
    # rotate: p + 2 r x (r x p + w p)
    movss   xmm0, [rdi]
    insertps xmm0, [rdi+4], 0x10
    insertps xmm0, [rdi+8], 0x20        # p (lane 3 zero)
    movaps  [rsp+32], xmm0
    movaps  xmm3, xmm1                  # r.xyz (w out)
    insertps xmm3, xmm3, 0x08
    movaps  [rsp+48], xmm3
    movaps  xmm4, xmm3
    CROSSAM xmm5, xmm4, xmm0, xmm6      # r x p
    movss   xmm6, [rsp+12]              # + w p
    shufps  xmm6, xmm6, 0
    mulps   xmm6, xmm0
    addps   xmm5, xmm6
    movaps  xmm4, [rsp+48]
    CROSSAM xmm6, xmm4, xmm5, xmm7      # r x (...)
    addps   xmm6, xmm6
    addps   xmm0, xmm6
    # t = 2 (w_r d.xyz - w_d r.xyz + r.xyz x d.xyz)
    movups  xmm2, [rsp+16]
    movaps  xmm3, xmm2
    insertps xmm3, xmm3, 0x08           # d.xyz
    movss   xmm4, [rsp+12]
    shufps  xmm4, xmm4, 0
    mulps   xmm4, xmm3                  # w_r d
    movss   xmm5, [rsp+28]
    shufps  xmm5, xmm5, 0
    mulps   xmm5, [rsp+48]              # w_d r
    subps   xmm4, xmm5
    movaps  xmm5, [rsp+48]
    CROSSAM xmm6, xmm5, xmm3, xmm7
    addps   xmm4, xmm6
    addps   xmm4, xmm4
    addps   xmm0, xmm4
    movss   [rsi], xmm0
    extractps dword ptr [rsi+4], xmm0, 1
    extractps dword ptr [rsi+8], xmm0, 2
    add     rsp, 72
    ret

# mat_dq(rdi=3x4, rsi=out real xyzw, dual xyzw) - its rotation (columns made
#   unit) as a quaternion, its translation as the dual part
mat_dq:
    push    rbx
    sub     rsp, 48
    mov     rbx, rdi
    xor     ecx, ecx                    # columns, unit: m[r][c] / |column c|
1:  movss   xmm0, [rbx+rcx*4]
    mulss   xmm0, xmm0
    movss   xmm1, [rbx+16+rcx*4]
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    movss   xmm1, [rbx+32+rcx*4]
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    sqrtss  xmm0, xmm0
    maxss   xmm0, [rip+am_tiny]
    movss   xmm1, [rbx+rcx*4]
    divss   xmm1, xmm0
    movss   [rsp+rcx*4], xmm1
    movss   xmm1, [rbx+16+rcx*4]
    divss   xmm1, xmm0
    movss   [rsp+12+rcx*4], xmm1
    movss   xmm1, [rbx+32+rcx*4]
    divss   xmm1, xmm0
    movss   [rsp+24+rcx*4], xmm1
    inc     ecx
    cmp     ecx, 3
    jb      1b
    # m00 [rsp] m01 [rsp+4] m02 [rsp+8] / m10 +12 m11 +16 m12 +20 / m20 +24 m21 +28 m22 +32
    movss   xmm0, [rsp]                 # trace
    addss   xmm0, [rsp+16]
    addss   xmm0, [rsp+32]
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    jbe     2f
    addss   xmm0, [rip+am_one]          # s = 2 sqrt(1 + tr)
    sqrtss  xmm0, xmm0
    addss   xmm0, xmm0
    movss   xmm1, xmm0
    mulss   xmm1, [rip+am_quarter]
    movss   [rsi+12], xmm1              # w = s / 4
    movss   xmm1, [rsp+28]              # x = (m21 - m12) / s
    subss   xmm1, [rsp+20]
    divss   xmm1, xmm0
    movss   [rsi], xmm1
    movss   xmm1, [rsp+8]               # y = (m02 - m20) / s
    subss   xmm1, [rsp+24]
    divss   xmm1, xmm0
    movss   [rsi+4], xmm1
    movss   xmm1, [rsp+12]              # z = (m10 - m01) / s
    subss   xmm1, [rsp+4]
    divss   xmm1, xmm0
    movss   [rsi+8], xmm1
    jmp     5f
2:  movss   xmm0, [rsp]                 # the largest diagonal leads
    movss   xmm1, [rsp+16]
    movss   xmm2, [rsp+32]
    comiss  xmm0, xmm1
    jb      3f
    comiss  xmm0, xmm2
    jb      4f
    addss   xmm0, [rip+am_one]          # x: s = 2 sqrt(1 + m00 - m11 - m22)
    subss   xmm0, xmm1
    subss   xmm0, xmm2
    sqrtss  xmm0, xmm0
    addss   xmm0, xmm0
    movss   xmm3, xmm0
    mulss   xmm3, [rip+am_quarter]
    movss   [rsi], xmm3
    movss   xmm3, [rsp+28]
    subss   xmm3, [rsp+20]
    divss   xmm3, xmm0
    movss   [rsi+12], xmm3
    movss   xmm3, [rsp+4]
    addss   xmm3, [rsp+12]
    divss   xmm3, xmm0
    movss   [rsi+4], xmm3
    movss   xmm3, [rsp+8]
    addss   xmm3, [rsp+24]
    divss   xmm3, xmm0
    movss   [rsi+8], xmm3
    jmp     5f
3:  comiss  xmm1, xmm2
    jb      4f
    movss   xmm3, [rip+am_one]          # y: s = 2 sqrt(1 + m11 - m00 - m22)
    addss   xmm3, xmm1
    subss   xmm3, xmm0
    subss   xmm3, xmm2
    sqrtss  xmm3, xmm3
    addss   xmm3, xmm3
    movss   xmm4, xmm3
    mulss   xmm4, [rip+am_quarter]
    movss   [rsi+4], xmm4
    movss   xmm4, [rsp+8]
    subss   xmm4, [rsp+24]
    divss   xmm4, xmm3
    movss   [rsi+12], xmm4
    movss   xmm4, [rsp+4]
    addss   xmm4, [rsp+12]
    divss   xmm4, xmm3
    movss   [rsi], xmm4
    movss   xmm4, [rsp+20]
    addss   xmm4, [rsp+28]
    divss   xmm4, xmm3
    movss   [rsi+8], xmm4
    jmp     5f
4:  movss   xmm3, [rip+am_one]          # z: s = 2 sqrt(1 + m22 - m00 - m11)
    addss   xmm3, xmm2
    subss   xmm3, xmm0
    subss   xmm3, xmm1
    sqrtss  xmm3, xmm3
    addss   xmm3, xmm3
    movss   xmm4, xmm3
    mulss   xmm4, [rip+am_quarter]
    movss   [rsi+8], xmm4
    movss   xmm4, [rsp+12]
    subss   xmm4, [rsp+4]
    divss   xmm4, xmm3
    movss   [rsi+12], xmm4
    movss   xmm4, [rsp+8]
    addss   xmm4, [rsp+24]
    divss   xmm4, xmm3
    movss   [rsi], xmm4
    movss   xmm4, [rsp+20]
    addss   xmm4, [rsp+28]
    divss   xmm4, xmm3
    movss   [rsi+4], xmm4
5:  # dual = 0.5 (0, t) q: (t w + t x q.xyz) / 2, w: -(t . q.xyz) / 2
    movss   xmm0, [rbx+12]              # t
    insertps xmm0, [rbx+28], 0x10
    insertps xmm0, [rbx+44], 0x20
    movups  xmm1, [rsi]                 # q
    movaps  xmm2, xmm1
    insertps xmm2, xmm2, 0x08           # q.xyz
    movaps  xmm3, xmm1
    shufps  xmm3, xmm3, 0xff            # w
    movaps  xmm4, xmm0
    mulps   xmm4, xmm3                  # t w
    CROSSAM xmm5, xmm0, xmm2, xmm6      # t x q
    addps   xmm4, xmm5
    movaps  xmm5, xmm0
    dpps    xmm5, xmm2, 0x71
    xorps   xmm6, xmm6
    subss   xmm6, xmm5
    insertps xmm4, xmm6, 0x30           # w
    mulps   xmm4, [rip+am_halfv]
    movups  [rsi+16], xmm4
    add     rsp, 48
    pop     rbx
    ret

.section .rodata
.align 16
am_neg:         .long 0x80000000, 0, 0, 0
am_halfv:       .float 0.5, 0.5, 0.5, 0.5
am_quarter:     .float 0.25
.text

# -----------------------------------------------------------------------------
# Weights
# -----------------------------------------------------------------------------
.globl arm_paint_bone
.globl arm_mod_target
.globl do_arm_pose
.globl arm_auto_weights
.equ MT_ARMATURE_, 11
.equ MB_COUNT_, 4
.equ MB_HDR_,   16
.equ MOD_SZ_,   48
.equ MD_P_,     8
.equ HW_ITERS,  400

.section .bss
.align 8
hw_mesh:        .skip 8
hw_w:           .skip 8                 # weights: bone-major, a float a vertex
hw_h:           .skip 8                 # heat a vertex (to its nearest bone)
hw_near:        .skip 8                 # its nearest bone (u8)
hw_nb:          .skip 4
hw_seg:         .skip 8                 # bone segments in the mesh's space
.text

# arm_mod_target(rdi=mesh object) -> rax = the armature object its first
#   Armature modifier names, or 0
arm_mod_target:
    mov     rax, [rdi+OB_MODS]
    test    rax, rax
    jz      8f
    xor     ecx, ecx
1:  cmp     ecx, [rax+MB_COUNT_]
    jae     8f
    imul    edx, ecx, MOD_SZ_
    cmp     dword ptr [rax+MB_HDR_+rdx], MT_ARMATURE_
    je      2f
    inc     ecx
    jmp     1b
2:  mov     edi, [rax+MB_HDR_+rdx+MD_P_]
    sub     rsp, 8
    call    obj_get
    add     rsp, 8
    test    rax, rax
    jz      8f
    cmp     dword ptr [rax+OB_TYPE], OT_ARMATURE
    jne     8f
    ret
8:  xor     eax, eax
    ret

# arm_paint_bone(rdi=mesh object) -> eax = the bone weight paint paints (its
#   armature's active one), -1 when it has no armature
arm_paint_bone:
    sub     rsp, 8
    call    arm_mod_target
    test    rax, rax
    jz      8f
    mov     rdi, rax
    call    arm_of
    test    rax, rax
    jz      8f
    mov     eax, [rax+AR_ACT]
    add     rsp, 8
    ret
8:  mov     eax, -1
    add     rsp, 8
    ret

# seg_dist2(rsi=segment a b (6 floats), rdi=point) -> xmm0 = squared distance
seg_dist2:
    movss   xmm0, [rsi+12]              # d = b - a
    subss   xmm0, [rsi]
    movss   xmm1, [rsi+16]
    subss   xmm1, [rsi+4]
    movss   xmm2, [rsi+20]
    subss   xmm2, [rsi+8]
    movss   xmm3, [rdi]                 # e = p - a
    subss   xmm3, [rsi]
    movss   xmm4, [rdi+4]
    subss   xmm4, [rsi+4]
    movss   xmm5, [rdi+8]
    subss   xmm5, [rsi+8]
    movss   xmm6, xmm0                  # t = e.d / d.d, clamped
    mulss   xmm6, xmm3
    movss   xmm7, xmm1
    mulss   xmm7, xmm4
    addss   xmm6, xmm7
    movss   xmm7, xmm2
    mulss   xmm7, xmm5
    addss   xmm6, xmm7
    movss   xmm7, xmm0
    mulss   xmm7, xmm0
    movss   xmm8, xmm1
    mulss   xmm8, xmm1
    addss   xmm7, xmm8
    movss   xmm8, xmm2
    mulss   xmm8, xmm2
    addss   xmm7, xmm8
    maxss   xmm7, [rip+am_tiny]
    divss   xmm6, xmm7
    xorps   xmm8, xmm8
    maxss   xmm6, xmm8
    minss   xmm6, [rip+am_one]
    mulss   xmm0, xmm6                  # e - t d
    mulss   xmm1, xmm6
    mulss   xmm2, xmm6
    subss   xmm3, xmm0
    subss   xmm4, xmm1
    subss   xmm5, xmm2
    mulss   xmm3, xmm3
    mulss   xmm4, xmm4
    mulss   xmm5, xmm5
    addss   xmm3, xmm4
    addss   xmm3, xmm5
    movss   xmm0, xmm3
    ret

# arm_auto_weights(rdi=mesh object, rsi=armature object) -> eax = 1: its
#   mesh's weights by bone heat (the mesh must not be shared: the caller
#   copies it)
arm_auto_weights:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 136
    mov     r12, rdi
    mov     r13, rsi
    mov     rdi, rsi
    call    arm_of
    test    rax, rax
    jz      .Law_fail
    mov     r14, rax                    # the bones
    mov     eax, [r14+AR_N]
    test    eax, eax
    jz      .Law_fail
    mov     [rip+hw_nb], eax
    mov     rbx, [r12+OB_MESH]
    mov     [rip+hw_mesh], rbx
    cmp     dword ptr [rbx+ME_NVERTS], 0
    je      .Law_fail
    mov     rdi, rbx
    call    mesh_wgt_alloc
    test    rax, rax
    jz      .Law_fail
    # bone segments in the mesh's space: (Mesh^-1 Arm) x
    mov     rdi, r12
    lea     rsi, [rsp]
    call    obj_matrix
    lea     rdi, [rsp+48]
    lea     rsi, [rsp]
    call    m_inv
    mov     rdi, r13
    lea     rsi, [rsp]
    call    obj_matrix
    lea     rdi, [rsp+96-96+0]          # (reuse: Q at am_t)
    lea     rdi, [rip+am_t]
    lea     rsi, [rsp+48]
    lea     rdx, [rsp]
    call    m_mul
    mov     edi, [r14+AR_N]
    imul    edi, edi, 24
    add     edi, 16
    call    hw_fa
    test    rax, rax
    jz      .Law_fail
    mov     [rip+hw_seg], rax
    xor     r15d, r15d
1:  cmp     r15d, [r14+AR_N]
    jae     2f
    mov     rdi, r14
    mov     esi, r15d
    call    arm_bone
    mov     rbp, rax
    imul    rdx, r15, 24
    add     rdx, [rip+hw_seg]
    push    rdx
    push    rdx
    lea     rdi, [rip+am_t]
    lea     rsi, [rbp+BN_HEAD]
    call    xform_point
    pop     rdx
    pop     rdx
    add     rdx, 12
    lea     rdi, [rip+am_t]
    lea     rsi, [rbp+BN_TAIL]
    call    xform_point
    inc     r15d
    jmp     1b
2:  # the average edge: the heat's scale
    xorps   xmm0, xmm0
    movss   [rsp+96], xmm0
    xor     ecx, ecx
3:  cmp     ecx, [rbx+ME_NEDGES]
    jae     4f
    mov     rax, [rbx+ME_EDGES]
    mov     edx, [rax+rcx*8]
    mov     r8d, [rax+rcx*8+4]
    mov     r9, [rbx+ME_POS]
    imul    rdx, rdx, 12
    imul    r8, r8, 12
    movss   xmm1, [r9+rdx]
    subss   xmm1, [r9+r8]
    mulss   xmm1, xmm1
    movss   xmm2, [r9+rdx+4]
    subss   xmm2, [r9+r8+4]
    mulss   xmm2, xmm2
    addss   xmm1, xmm2
    movss   xmm2, [r9+rdx+8]
    subss   xmm2, [r9+r8+8]
    mulss   xmm2, xmm2
    addss   xmm1, xmm2
    sqrtss  xmm1, xmm1
    addss   xmm1, [rsp+96]
    movss   [rsp+96], xmm1
    inc     ecx
    jmp     3b
4:  mov     eax, [rbx+ME_NEDGES]
    cmp     eax, 1
    jge     41f
    mov     eax, 1
41: cvtsi2ss xmm0, eax
    movss   xmm1, [rsp+96]
    divss   xmm1, xmm0
    maxss   xmm1, [rip+am_eps]
    mulss   xmm1, xmm1
    movss   [rsp+100], xmm1             # edge^2
    # per vertex: the nearest bone, the heat (edge / distance)^2
    mov     edi, [rbx+ME_NVERTS]
    shl     edi, 2
    add     edi, 16
    call    hw_fa
    test    rax, rax
    jz      .Law_fail
    mov     [rip+hw_h], rax
    mov     edi, [rbx+ME_NVERTS]
    add     edi, 16
    call    hw_fa
    test    rax, rax
    jz      .Law_fail
    mov     [rip+hw_near], rax
    mov     edi, [rbx+ME_NVERTS]
    imul    edi, [r14+AR_N]
    shl     rdi, 2
    add     edi, 16
    call    hw_fa
    test    rax, rax
    jz      .Law_fail
    mov     [rip+hw_w], rax
    mov     rdi, rax                    # weights start at 0
    mov     ecx, [rbx+ME_NVERTS]
    imul    ecx, [r14+AR_N]
    xor     eax, eax
    rep     stosd
    xor     r15d, r15d
5:  cmp     r15d, [rbx+ME_NVERTS]
    jae     7f
    mov     eax, [rip+am_big]
    mov     [rsp+104], eax
    mov     dword ptr [rsp+108], 0
    xor     ebp, ebp
6:  cmp     ebp, [r14+AR_N]
    jae     61f
    imul    rsi, rbp, 24
    add     rsi, [rip+hw_seg]
    imul    rdi, r15, 12
    add     rdi, [rbx+ME_POS]
    call    seg_dist2
    comiss  xmm0, [rsp+104]
    jae     62f
    movss   [rsp+104], xmm0
    mov     [rsp+108], ebp
62: inc     ebp
    jmp     6b
61: mov     eax, [rsp+108]
    mov     rcx, [rip+hw_near]
    mov     [rcx+r15], al
    movss   xmm0, [rsp+100]             # (edge / d)^2, at most 1000
    movss   xmm1, [rsp+104]
    maxss   xmm1, [rip+am_eps]
    divss   xmm0, xmm1
    minss   xmm0, [rip+am_1000]
    mov     rcx, [rip+hw_h]
    movss   [rcx+r15*4], xmm0
    mov     eax, [rsp+108]              # the source: its own bone at 1
    imul    eax, [rbx+ME_NVERTS]
    add     eax, r15d
    mov     rcx, [rip+hw_w]
    mov     edx, [rip+am_one]
    mov     [rcx+rax*4], edx
    inc     r15d
    jmp     5b
7:  push    rbx                         # neighbours (edit.s), then diffuse
    call    build_adj
    pop     rbx
    test    eax, eax
    jz      .Law_fail
    lea     rdi, [rip+hw_job]
    xor     esi, esi
    mov     edx, [r14+AR_N]
    mov     ecx, 1
    call    parallel_for
    # the four heaviest bones a vertex, normalized
    xor     r15d, r15d
8:  cmp     r15d, [rbx+ME_NVERTS]
    jae     .Law_ok
    imul    rbp, r15, 20
    add     rbp, [rbx+ME_WGT]
    mov     dword ptr [rbp], -1
    xorps   xmm0, xmm0
    movups  [rbp+4], xmm0
    xor     ecx, ecx                    # each bone: into the lightest slot
81: cmp     ecx, [r14+AR_N]
    jae     84f
    mov     eax, ecx
    imul    eax, [rbx+ME_NVERTS]
    add     eax, r15d
    mov     rdx, [rip+hw_w]
    movss   xmm1, [rdx+rax*4]
    comiss  xmm1, [rip+am_hundredth]
    jbe     83f
    xor     edx, edx                    # the lightest slot
    xor     r8d, r8d
    movss   xmm2, [rbp+4]
82: inc     r8d
    cmp     r8d, 4
    jae     821f
    comiss  xmm2, [rbp+4+r8*4]
    jbe     82b
    movss   xmm2, [rbp+4+r8*4]
    mov     edx, r8d
    jmp     82b
821:comiss  xmm1, xmm2
    jbe     83f
    mov     [rbp+rdx], cl
    movss   [rbp+4+rdx*4], xmm1
83: inc     ecx
    jmp     81b
84: xorps   xmm0, xmm0                  # normalize
    addss   xmm0, [rbp+4]
    addss   xmm0, [rbp+8]
    addss   xmm0, [rbp+12]
    addss   xmm0, [rbp+16]
    comiss  xmm0, [rip+am_eps]
    jbe     86f
    xor     ecx, ecx
85: movss   xmm1, [rbp+4+rcx*4]
    divss   xmm1, xmm0
    movss   [rbp+4+rcx*4], xmm1
    inc     ecx
    cmp     ecx, 4
    jb      85b
    jmp     87f
86: mov     rcx, [rip+hw_near]          # (no heat reached it: its nearest)
    movzx   eax, byte ptr [rcx+r15]
    mov     [rbp], al
    mov     eax, [rip+am_one]
    mov     [rbp+4], eax
87: inc     r15d
    jmp     8b
.Law_ok:
    inc     dword ptr [rbx+ME_VER]
    call    eval_flush
    mov     dword ptr [rip+dirty], 1
    mov     eax, 1
    jmp     .Law_out
.Law_fail:
    xor     eax, eax
.Law_out:
    add     rsp, 136
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

hw_fa:
    mov     esi, edi
    lea     rdi, [rip+frame_arena]
    jmp     arena_alloc

# hw_job(esi=first bone, edx=end) - each bone's heat: Gauss-Seidel on
#   (L + H) w = H p (p: 1 where it is the nearest bone)
hw_job:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 8
    mov     r12d, esi
    mov     r13d, edx
    mov     rbx, [rip+hw_mesh]
.Lhj_bone:
    cmp     r12d, r13d
    jae     .Lhj_out
    mov     eax, r12d
    imul    eax, [rbx+ME_NVERTS]
    mov     r14, [rip+hw_w]
    lea     r14, [r14+rax*4]            # this bone's weights
    mov     r15d, HW_ITERS
.Lhj_iter:
    xor     ebp, ebp
1:  cmp     ebp, [rbx+ME_NVERTS]
    jae     5f
    mov     rcx, [rip+adj_off]
    mov     edx, [rcx+rbp*4]
    mov     r8d, [rcx+rbp*4+4]
    xorps   xmm0, xmm0                  # neighbours' sum, degree
    mov     r9, [rip+adj_nb]
    mov     r10d, r8d
    sub     r10d, edx
2:  cmp     edx, r8d
    jae     3f
    mov     eax, [r9+rdx*4]
    addss   xmm0, [r14+rax*4]
    inc     edx
    jmp     2b
3:  cvtsi2ss xmm1, r10d
    mov     rcx, [rip+hw_h]
    movss   xmm2, [rcx+rbp*4]           # H
    addss   xmm1, xmm2
    mov     rcx, [rip+hw_near]
    movzx   eax, byte ptr [rcx+rbp]
    cmp     eax, r12d
    jne     4f
    addss   xmm0, xmm2                  # + H p
4:  maxss   xmm1, [rip+am_eps]
    divss   xmm0, xmm1
    movss   [r14+rbp*4], xmm0
    inc     ebp
    jmp     1b
5:  dec     r15d
    jnz     .Lhj_iter
    inc     r12d
    jmp     .Lhj_bone
.Lhj_out:
    add     rsp, 8
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.section .rodata
.align 4
am_big:         .float 1.0e30
am_1000:        .float 1000.0
am_hundredth:   .float 0.01
.text

# -----------------------------------------------------------------------------
# Operators
# -----------------------------------------------------------------------------
OPERATOR op_add_armature, "create.armature", "Armature", do_arm_add, flags=OPF_AI_SAFE|OPF_UNDO, doc="Add an armature (one bone) at the 3D cursor"
OPERATOR op_arm_bone,  "arm.bone",    "Add Bone",       do_arm_bone, flags=OPF_AI_SAFE|OPF_UNDO, doc="A bone in the active armature: arm.bone <name> <parent|-> <head x y z> <tail x y z> (armature space; a head on the parent's tail joins them)"
OPERATOR op_arm_pose,  "arm.pose",    "Pose Bone",      do_arm_pose, flags=OPF_AI_SAFE|OPF_UNDO, doc="Pose a bone of the active armature: arm.pose <bone> <loc|rot|scale> <x> <y> <z> (rot in degrees, in the bone's own axes; Y along it)"
OPERATOR op_arm_sel,   "arm.select_bone", "Select Bone", do_arm_sel, flags=OPF_AI_SAFE|OPF_QUIET, doc="Make a bone of the active armature the active one: arm.select_bone <bone> [extend]"
OPERATOR op_arm_parent,"arm.parent",  "Parent to Armature", do_arm_parent, flags=OPF_AI_SAFE|OPF_UNDO, doc="Skin a mesh to an armature with automatic weights: arm.parent <mesh> <armature> [dual]", form=form_parent
OPERATOR op_arm_autow, "arm.auto_weights", "Automatic Weights", do_arm_autow, flags=OPF_AI_SAFE|OPF_UNDO, doc="A mesh's skin weights by bone heat again: arm.auto_weights <mesh>"
OPERATOR op_arm_clear, "arm.clear_pose", "Clear Pose", do_arm_clear, flags=OPF_AI_SAFE|OPF_UNDO, doc="Back to the rest pose: the selected bones of the active armature (all when none is)"

.section .rodata
k_loc:          .asciz "loc"
k_rot:          .asciz "rot"
k_scale:        .asciz "scale"
k_dash:         .asciz "-"
k_dual:         .asciz "dual"
k_extend:       .asciz "extend"
s_arm_none:     .asciz "  not an armature (create.armature makes one)"
s_arm_bad:      .asciz "  arm.bone <name> <parent|-> <hx hy hz> <tx ty tz>"
s_arm_nobone:   .asciz "  no bone named "
s_arm_pbad:     .asciz "  arm.parent <mesh> <armature> [dual]"
s_arm_added:    .asciz "  added "
s_arm_weights:  .asciz "  automatic weights: "
s_arm_noweights:.asciz "  no weights: the mesh needs an Armature modifier (arm.parent)"
.text

# arm_target -> rax = the active object when it is an armature (logs and 0)
arm_target:
    sub     rsp, 8
    mov     edi, [rip+active_obj]
    call    obj_get
    test    rax, rax
    jz      8f
    cmp     dword ptr [rax+OB_TYPE], OT_ARMATURE
    jne     8f
    add     rsp, 8
    ret
8:  lea     rdi, [rip+s_arm_none]
    call    log_line
    xor     eax, eax
    add     rsp, 8
    ret

# a3(rsi=text, rdi=out float[3]) -> eax = 1 with three numbers, rsi after
a3:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     r12, rdi
    xor     ebx, ebx
1:  cmp     ebx, 3
    jae     2f
    call    im_next_word
    test    eax, eax
    jz      8f
    push    rsi
    sub     rsp, 8
    lea     rsi, [rip+im_word]
    lea     rdx, [rsi+rax]
    call    parse_float
    add     rsp, 8
    pop     rsi
    test    eax, eax
    jz      8f
    movss   [r12+rbx*4], xmm0
    inc     ebx
    jmp     1b
2:  mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

do_arm_add:
    push    rbx
    xor     esi, esi
    call    arm_create
    test    eax, eax
    jz      9f
    mov     ebx, eax
    mov     edi, eax
    xor     esi, esi
    call    obj_click_select
    mov     edi, ebx
    call    obj_get
    mov     rcx, [rip+cursor_pos]
    mov     [rax+OB_LOC], rcx
    mov     ecx, [rip+cursor_pos+8]
    mov     [rax+OB_LOC+8], ecx
    cmp     dword ptr [rip+op_quiet], 0
    jne     9f
    mov     rsi, rax
    lea     rdi, [rip+s_arm_added]
    call    log_pair
9:  pop     rbx
    ret

# arm.bone <name> <parent|-> <hx hy hz> <tx ty tz>
do_arm_bone:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 88
    call    arm_target
    test    rax, rax
    jz      .Lab_out
    mov     rbx, rax
    mov     rsi, [rip+op_arg]
    call    im_next_word
    test    eax, eax
    jz      .Lab_bad
    mov     r12, rsi
    lea     rdi, [rsp+40]               # the name
    lea     rsi, [rip+im_word]
    mov     ecx, 24
    rep     movsb
    mov     byte ptr [rsp+63], 0
    mov     rsi, r12
    call    im_next_word
    test    eax, eax
    jz      .Lab_bad
    mov     r12, rsi
    mov     r13d, -1                    # the parent
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_dash]
    call    str_eq
    test    eax, eax
    jnz     1f
    mov     rdi, rbx
    call    arm_of
    mov     rdi, rax
    lea     rsi, [rip+im_word]
    call    arm_find_bone
    test    eax, eax
    js      .Lab_nobone
    mov     r13d, eax
1:  mov     rsi, r12
    lea     rdi, [rsp]
    call    a3
    test    eax, eax
    jz      .Lab_bad
    lea     rdi, [rsp+16]
    call    a3
    test    eax, eax
    jz      .Lab_bad
    mov     rdi, rbx
    call    arm_edit
    test    rax, rax
    jz      .Lab_out
    mov     r14, rax
    mov     rdi, rax
    lea     rsi, [rsp+40]
    mov     edx, r13d
    lea     rcx, [rsp]
    lea     r8, [rsp+16]
    call    arm_add_bone
    test    eax, eax
    js      .Lab_bad
    test    r13d, r13d                  # its head on the parent's tail: joined
    js      2f
    mov     r12d, eax
    mov     rdi, r14
    mov     esi, r13d
    call    arm_bone
    mov     rcx, rax
    mov     rdi, r14
    mov     esi, r12d
    call    arm_bone
    xor     edx, edx
3:  movss   xmm0, [rax+BN_HEAD+rdx*4]
    subss   xmm0, [rcx+BN_TAIL+rdx*4]
    andps   xmm0, [rip+am_absm]
    comiss  xmm0, [rip+am_conn]
    ja      2f
    inc     edx
    cmp     edx, 3
    jb      3b
    mov     byte ptr [rax+BN_CONN], 1
2:  mov     rdi, rbx
    call    arm_rebuild
    jmp     .Lab_out
.Lab_nobone:
    lea     rdi, [rip+s_arm_nobone]
    lea     rsi, [rip+im_word]
    call    log_pair
    call    undo_drop_last
    jmp     .Lab_out
.Lab_bad:
    lea     rdi, [rip+s_arm_bad]
    call    log_line
    call    undo_drop_last
.Lab_out:
    add     rsp, 88
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# arm.pose <bone> <loc|rot|scale> <x> <y> <z>
do_arm_pose:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 32
    call    arm_target
    test    rax, rax
    jz      .Lap_out
    mov     rbx, rax
    mov     rsi, [rip+op_arg]
    call    im_next_word
    test    eax, eax
    jz      .Lap_bad
    mov     r12, rsi
    mov     rdi, rbx
    call    arm_of
    mov     rdi, rax
    lea     rsi, [rip+im_word]
    call    arm_find_bone
    test    eax, eax
    js      .Lap_bad
    mov     r13d, eax
    mov     rsi, r12
    call    im_next_word
    mov     r12, rsi
    xor     ecx, ecx                    # loc 0, rot 1, scale 2
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_rot]
    push    rcx
    push    rcx
    call    str_eq
    pop     rcx
    pop     rcx
    test    eax, eax
    jz      1f
    mov     ecx, 1
1:  push    rcx
    push    rcx
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_scale]
    call    str_eq
    pop     rcx
    pop     rcx
    test    eax, eax
    jz      2f
    mov     ecx, 2
2:  mov     [rsp+16], ecx
    mov     rsi, r12
    lea     rdi, [rsp]
    call    a3
    test    eax, eax
    jz      .Lap_bad
    cmp     dword ptr [rsp+16], 1       # degrees -> radians
    jne     3f
    xor     ecx, ecx
31: movss   xmm0, [rsp+rcx*4]
    mulss   xmm0, [rip+am_deg]
    movss   [rsp+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      31b
3:  mov     rdi, rbx
    call    arm_edit
    test    rax, rax
    jz      .Lap_out
    mov     rdi, rax
    mov     esi, r13d
    call    arm_bone
    mov     ecx, [rsp+16]
    imul    ecx, ecx, 12
    lea     rax, [rax+BN_LOC+rcx]
    mov     rcx, [rsp]
    mov     [rax], rcx
    mov     ecx, [rsp+8]
    mov     [rax+8], ecx
    mov     rdi, rbx
    call    arm_rebuild
    jmp     .Lap_out
.Lap_bad:
    lea     rdi, [rip+s_arm_nobone]
    lea     rsi, [rip+im_word]
    call    log_pair
    call    undo_drop_last
.Lap_out:
    add     rsp, 32
    pop     r13
    pop     r12
    pop     rbx
    ret

# arm.select_bone <bone> [extend]
do_arm_sel:
    push    rbx
    push    r12
    push    r13
    call    arm_target
    test    rax, rax
    jz      9f
    mov     rdi, rax
    call    arm_of
    mov     rbx, rax
    mov     rsi, [rip+op_arg]
    call    im_next_word
    mov     r12, rsi
    mov     rdi, rbx
    lea     rsi, [rip+im_word]
    call    arm_find_bone
    test    eax, eax
    js      9f
    mov     r13d, eax
    mov     rsi, r12
    call    im_next_word
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_extend]
    call    str_eq
    test    eax, eax
    jnz     2f
    xor     ecx, ecx                    # the others unselected
1:  cmp     ecx, [rbx+AR_N]
    jae     2f
    imul    rax, rcx, BN_SZ
    mov     byte ptr [rbx+AR_BONES+rax+BN_SEL], 0
    inc     ecx
    jmp     1b
2:  imul    rax, r13, BN_SZ
    mov     byte ptr [rbx+AR_BONES+rax+BN_SEL], 7
    mov     [rbx+AR_ACT], r13d
    mov     dword ptr [rip+dirty], 1
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# arm_mesh_own(rdi=mesh object) -> rax = its mesh, unshared (copied)
arm_mesh_own:
    push    rbx
    mov     rbx, rdi
    mov     rdi, [rbx+OB_MESH]
    cmp     dword ptr [rdi+ME_REFS], 1
    jbe     1f
    call    mesh_copy
    test    rax, rax
    jz      9f
    mov     rdi, [rbx+OB_MESH]
    mov     [rbx+OB_MESH], rax
    call    mesh_unref
1:  mov     rax, [rbx+OB_MESH]
9:  pop     rbx
    ret

# arm.parent <mesh> <armature> [dual] - an Armature modifier, auto weights
do_arm_parent:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     rsi, [rip+op_arg]
    call    im_next_word
    test    eax, eax
    jz      .Lpa_bad
    mov     r12, rsi
    lea     rdi, [rip+im_word]
    call    obj_find
    test    eax, eax
    jz      .Lpa_bad
    mov     edi, eax
    call    obj_get
    cmp     dword ptr [rax+OB_TYPE], OT_MESH
    jne     .Lpa_bad
    mov     rbx, rax
    mov     rsi, r12
    call    im_next_word
    test    eax, eax
    jz      .Lpa_bad
    mov     r12, rsi
    lea     rdi, [rip+im_word]
    call    obj_find
    test    eax, eax
    jz      .Lpa_bad
    mov     r13d, eax                   # the armature's handle
    mov     edi, eax
    call    obj_get
    cmp     dword ptr [rax+OB_TYPE], OT_ARMATURE
    jne     .Lpa_bad
    mov     r14, rax
    xor     eax, eax
    mov     rsi, r12
    call    im_next_word
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_dual]
    call    str_eq
    mov     r12d, eax                   # mode
    mov     rdi, rbx                    # its Armature modifier (made if none)
    call    arm_mod_index
    test    eax, eax
    jns     1f
    mov     rdi, rbx
    mov     esi, MT_ARMATURE_
    call    mod_add
    test    eax, eax
    js      .Lpa_bad
1:  mov     [rsp], eax
    mov     rdi, rbx
    mov     esi, eax
    xor     edx, edx
    mov     ecx, r13d
    call    mod_param_set_obj
    cvtsi2ss xmm0, r12d
    mov     rdi, rbx
    mov     esi, [rsp]
    mov     edx, 1
    call    mod_param_set
    mov     rdi, rbx
    call    arm_mesh_own
    mov     rdi, rbx
    mov     rsi, r14
    call    arm_auto_weights
    lea     rdi, [rip+s_arm_weights]
    mov     rsi, rbx
    call    log_pair
    jmp     9f
.Lpa_bad:
    lea     rdi, [rip+s_arm_pbad]
    call    log_line
    call    undo_drop_last
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# arm_mod_index(rdi=mesh object) -> eax = its first Armature modifier, -1
arm_mod_index:
    mov     rax, [rdi+OB_MODS]
    test    rax, rax
    jz      8f
    xor     ecx, ecx
1:  cmp     ecx, [rax+MB_COUNT_]
    jae     8f
    imul    edx, ecx, MOD_SZ_
    cmp     dword ptr [rax+MB_HDR_+rdx], MT_ARMATURE_
    je      2f
    inc     ecx
    jmp     1b
2:  mov     eax, ecx
    ret
8:  mov     eax, -1
    ret

# arm.auto_weights <mesh>
do_arm_autow:
    push    rbx
    mov     rsi, [rip+op_arg]
    call    im_next_word
    test    eax, eax
    jz      8f
    lea     rdi, [rip+im_word]
    call    obj_find
    test    eax, eax
    jz      8f
    mov     edi, eax
    call    obj_get
    mov     rbx, rax
    mov     rdi, rax
    call    arm_mod_target
    test    rax, rax
    jz      7f
    push    rax
    push    rax
    mov     rdi, rbx
    call    arm_mesh_own
    pop     rsi
    pop     rsi
    mov     rdi, rbx
    call    arm_auto_weights
    jmp     9f
7:  lea     rdi, [rip+s_arm_noweights]
    call    log_line
8:  call    undo_drop_last
9:  pop     rbx
    ret

do_arm_clear:
    push    rbx
    push    r12
    push    r13
    call    arm_target
    test    rax, rax
    jz      9f
    mov     r12, rax
    mov     rdi, rax
    call    arm_edit
    test    rax, rax
    jz      9f
    mov     rbx, rax
    xor     r13d, r13d                  # any selected?
    xor     ecx, ecx
1:  cmp     ecx, [rbx+AR_N]
    jae     2f
    imul    rax, rcx, BN_SZ
    or      r13b, [rbx+AR_BONES+rax+BN_SEL]
    inc     ecx
    jmp     1b
2:  xor     ecx, ecx
3:  cmp     ecx, [rbx+AR_N]
    jae     5f
    imul    rax, rcx, BN_SZ
    lea     rax, [rbx+AR_BONES+rax]
    test    r13b, r13b
    jz      4f
    cmp     byte ptr [rax+BN_SEL], 0
    je      41f
4:  xor     edx, edx
    mov     [rax+BN_LOC], rdx
    mov     [rax+BN_LOC+8], rdx
    mov     [rax+BN_LOC+16], rdx
    mov     edx, [rip+am_one]
    mov     [rax+BN_SCALE], edx
    mov     [rax+BN_SCALE+4], edx
    mov     [rax+BN_SCALE+8], edx
41: inc     ecx
    jmp     3b
5:  mov     rdi, r12
    call    arm_rebuild
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# -----------------------------------------------------------------------------
# Files: the ARMT chunk = per mesh (mesh_tab) with bones: index, the block
#   from its bone count on; weights in MWGT (mesh, vertices, records)
# -----------------------------------------------------------------------------
# arm_load(rsi=data (AR_N on), edx=bytes) -> rax = a block, or 0
arm_load:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     r12, rsi
    cmp     edx, AR_SZ-4
    jb      8f
    mov     eax, [r12]
    cmp     eax, AR_MAXB
    ja      8f
    call    arm_new
    test    rax, rax
    jz      8f
    mov     rbx, rax
    lea     rdi, [rbx+4]
    mov     rsi, r12
    mov     ecx, AR_SZ-4
    rep     movsb
    mov     qword ptr [rbx+AR_BYTES], (AR_SZ+4095) & -4096
    mov     dword ptr [rbx+AR_REFS], 1
    xor     ecx, ecx                    # parents come first
1:  cmp     ecx, [rbx+AR_N]
    jae     2f
    imul    rax, rcx, BN_SZ
    mov     edx, [rbx+AR_BONES+rax+BN_PARENT]
    cmp     edx, ecx
    jl      11f
    mov     dword ptr [rbx+AR_BONES+rax+BN_PARENT], -1
11: inc     ecx
    jmp     1b
2:  mov     rax, rbx
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

.section .rodata
.align 4
am_deg:         .float 0.017453292
am_conn:        .float 1.0e-4
.text

# =============================================================================
#  Armature edit mode (Tab: the rest bones' joints) and pose mode (Ctrl+Tab:
#  the bones' poses): picking, the overlay, transforms, keys
# =============================================================================
.globl arm_mode
.globl arm_obj
.globl arm_tab
.globl arm_ctrl_tab
.globl arm_click
.globl arm_overlay
.globl arm_tm_snapshot
.globl arm_tm_restore
.globl arm_tm_grab
.globl arm_tm_rotate
.globl arm_tm_scale
.globl arm_median
.globl arm_tm_end
.equ AT_MAX,    256
.equ AT_SZ,     112                     # bone, part (0 head 1 tail 2 pose),
                                        #  world, local, pose (36), F (48)
.equ COL_BONE,    0xc8ccd4
.equ COL_BONE_SEL, 0xffa030
.equ COL_BONE_ACT, 0xffd27a
.equ KEY_E_,    18
.equ KEY_X_,    45
.equ KEY_A_,    30
.equ KEY_I_,    23
.equ KEY_R_,    19

OPERATOR op_arm_extrude, "arm.extrude", "Extrude Bone", do_arm_extrude, key=KEY_E_, flags=OPF_AI_SAFE|OPF_UNDO|OPF_ARM, doc="Armature edit mode: a new bone from each selected tail (joined), then move it"
OPERATOR op_arm_delete,  "arm.delete_bones", "Delete Bones", do_arm_delete, key=KEY_X_, flags=OPF_AI_SAFE|OPF_UNDO|OPF_ARM, doc="Armature edit mode: remove the selected bones (children move up; skin weights follow)"
OPERATOR op_arm_selall,  "arm.select_all", "Select All Bones", do_arm_selall, key=KEY_A_, flags=OPF_AI_SAFE|OPF_QUIET|OPF_ARM, doc="Armature modes: every bone, or none when some are"
OPERATOR op_arm_key,     "arm.insert_key", "Key Pose", do_arm_key, key=KEY_I_, flags=OPF_AI_SAFE|OPF_UNDO|OPF_ARM, doc="Pose mode: key the selected bones' location, rotation and scale at the frame"
OPERATOR op_arm_clearr,  "arm.clear_pose_key", "Clear Pose", do_arm_clear, key=KEY_R_|KM_ALT, flags=OPF_AI_SAFE|OPF_UNDO|OPF_ARM|OPF_HIDDEN, doc="Pose mode: the selected bones back to rest"

.section .data
.align 4
.globl arm_ver
arm_ver:        .long 0                 # bumped by every rebuild
arm_mode:       .long 0                 # 1 armature edit mode, 2 pose mode
arm_obj:        .long 0
.section .bss
.align 16
at_buf:         .skip AT_MAX*AT_SZ
at_n:           .skip 4
.align 16
au_a:           .skip 48                # the armature object's matrix
au_ai:          .skip 48                #  and its inverse
au_m:           .skip 48
au_w:           .skip 16
au_rw:          .skip 48
.section .rodata
s_arm_edit:     .asciz "  armature edit mode (Tab leaves; click joints, G/R/S, E extrude, X delete)"
s_arm_posem:    .asciz "  pose mode (Ctrl+Tab leaves; click bones, G/R/S, I key, Alt+R clear)"
s_arm_extr:     .asciz "  select a bone's tail to extrude from"
.text

# arm_get -> rax = the object in an armature mode (leaves it when it went)
arm_get:
    mov     edi, [rip+arm_obj]
    test    edi, edi
    jz      8f
    cmp     dword ptr [rip+arm_mode], 0
    je      8f
    sub     rsp, 8
    call    obj_get
    add     rsp, 8
    test    rax, rax
    jz      7f
    cmp     dword ptr [rax+OB_TYPE], OT_ARMATURE
    jne     7f
    ret
7:  mov     dword ptr [rip+arm_mode], 0
8:  xor     eax, eax
    ret

# arm_enter(edi=mode) -> eax = 1 when Tab / Ctrl+Tab meant an armature mode
arm_enter:
    push    rbx
    mov     ebx, edi
    cmp     dword ptr [rip+arm_mode], 0
    je      1f
    cmp     [rip+arm_mode], ebx         # the same: leave; the other: switch
    jne     2f
    mov     dword ptr [rip+arm_mode], 0
    jmp     7f
1:  mov     edi, [rip+active_obj]
    call    obj_get
    test    rax, rax
    jz      8f
    cmp     dword ptr [rax+OB_TYPE], OT_ARMATURE
    jne     8f
    mov     eax, [rip+active_obj]
    mov     [rip+arm_obj], eax
2:  mov     [rip+arm_mode], ebx
    lea     rdi, [rip+s_arm_edit]
    cmp     ebx, 1
    je      3f
    lea     rdi, [rip+s_arm_posem]
3:  call    log_line
7:  mov     dword ptr [rip+dirty], 1
    mov     eax, 1
    pop     rbx
    ret
8:  xor     eax, eax
    pop     rbx
    ret
arm_tab:
    mov     edi, 1
    jmp     arm_enter
arm_ctrl_tab:
    mov     edi, 2
    jmp     arm_enter

# au_setup(rdi=object) - au_a / au_ai, and the bones' matrices
au_setup:
    push    rbx
    mov     rbx, rdi
    mov     [rip+am_owner], rdi
    lea     rsi, [rip+au_a]
    call    obj_matrix
    lea     rdi, [rip+au_ai]
    lea     rsi, [rip+au_a]
    call    m_inv
    mov     rdi, rbx
    call    arm_of
    test    rax, rax
    jz      9f
    mov     rdi, rax
    call    arm_pose_mats
9:  pop     rbx
    ret

# au_joint(rdi=block, esi=bone, edx=0 head / 1 tail, rcx=out world) - where it
#   is shown: rest (edit mode) or posed (pose mode)
au_joint:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 32
    mov     r12d, esi
    mov     r13d, edx
    mov     rbx, rcx
    call    arm_bone
    cmp     dword ptr [rip+arm_mode], 2
    je      1f
    lea     rsi, [rax+BN_HEAD]          # rest: head / tail
    test    r13d, r13d
    jz      2f
    lea     rsi, [rax+BN_TAIL]
    jmp     2f
1:  movss   xmm0, [rax+BN_TAIL]         # posed: M (0 0 0) / M (0 len 0)
    subss   xmm0, [rax+BN_HEAD]
    mulss   xmm0, xmm0
    movss   xmm1, [rax+BN_TAIL+4]
    subss   xmm1, [rax+BN_HEAD+4]
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    movss   xmm1, [rax+BN_TAIL+8]
    subss   xmm1, [rax+BN_HEAD+8]
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    sqrtss  xmm0, xmm0
    xorps   xmm1, xmm1
    movss   [rsp], xmm1
    movss   [rsp+4], xmm1
    movss   [rsp+8], xmm1
    test    r13d, r13d
    jz      11f
    movss   [rsp+4], xmm0
11: imul    rdi, r12, 48
    lea     rax, [rip+am_m]
    add     rdi, rax
    lea     rsi, [rsp]
    lea     rdx, [rsp+16]
    call    xform_point
    lea     rsi, [rsp+16]
2:  lea     rdi, [rip+au_a]
    mov     rdx, rbx
    call    xform_point
    add     rsp, 32
    pop     r13
    pop     r12
    pop     rbx
    ret

# arm_overlay - the bones as lines (selected orange, the active brighter),
#   joints as dots in edit mode
arm_overlay:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 48
    call    arm_get
    test    rax, rax
    jz      9f
    mov     rdi, rax
    push    rax
    call    au_setup
    pop     rdi
    call    arm_of
    mov     rbx, rax
    xor     r12d, r12d
1:  cmp     r12d, [rbx+AR_N]
    jae     9f
    mov     rdi, rbx
    mov     esi, r12d
    xor     edx, edx
    lea     rcx, [rip+lp0]
    call    au_joint
    mov     rdi, rbx
    mov     esi, r12d
    mov     edx, 1
    lea     rcx, [rip+lp1]
    call    au_joint
    mov     rdi, rbx
    mov     esi, r12d
    call    arm_bone
    mov     r13, rax
    mov     edx, COL_BONE
    test    byte ptr [r13+BN_SEL], 4
    jz      2f
    mov     edx, COL_BONE_SEL
    cmp     r12d, [rbx+AR_ACT]
    jne     2f
    mov     edx, COL_BONE_ACT
2:  call    line3d
    cmp     dword ptr [rip+arm_mode], 1
    jne     4f
    xor     ecx, ecx                    # joints
3:  mov     [rsp], ecx
    lea     rdi, [rip+lp0]
    test    ecx, ecx
    jz      31f
    lea     rdi, [rip+lp1]
31: call    world_px
    xorps   xmm3, xmm3
    comiss  xmm2, xmm3
    jbe     32f
    mov     ecx, [rsp]
    mov     edx, COL_BONE
    inc     ecx
    test    byte ptr [r13+BN_SEL], cl
    jz      33f
    mov     edx, COL_BONE_SEL
33: mov     ecx, 7
    call    dot
32: mov     ecx, [rsp]
    inc     ecx
    cmp     ecx, 2
    jb      3b
4:  inc     r12d
    jmp     1b
9:  add     rsp, 48
    pop     r13
    pop     r12
    pop     rbx
    ret

# arm_click(edi=x, esi=y logical, edx=modifiers) -> eax = 1 when in a mode:
#   the nearest joint (edit mode) or bone; Shift toggles, else it alone
arm_click:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 64
    mov     [rsp+40], edx
    call    arm_get
    test    rax, rax
    jz      .Lac_no
    mov     rbx, rax
    mov     edi, [rsp+40]
    call    to_px_xy                    # (x, y given again: in rsp+44, +48)
    mov     rdi, rbx
    call    au_setup
    mov     rdi, rbx
    call    arm_of
    mov     r12, rax
    mov     dword ptr [rsp+52], -1      # best bone, its bits, distance^2
    mov     dword ptr [rsp+56], 0
    mov     dword ptr [rsp+60], 14*14
    xor     r13d, r13d
1:  cmp     r13d, [r12+AR_N]
    jae     5f
    mov     rdi, r12                    # the joints' screen points
    mov     esi, r13d
    xor     edx, edx
    lea     rcx, [rsp]
    call    au_joint
    mov     rdi, r12
    mov     esi, r13d
    mov     edx, 1
    lea     rcx, [rsp+12]
    call    au_joint
    lea     rdi, [rsp]
    call    world_px
    movss   [rsp+24], xmm0
    movss   [rsp+28], xmm1
    lea     rdi, [rsp+12]
    call    world_px
    movss   [rsp+32], xmm0
    movss   [rsp+36], xmm1
    cmp     dword ptr [rip+arm_mode], 1
    jne     3f
    xor     r14d, r14d                  # edit mode: joints first
2:  movss   xmm0, [rsp+24+r14*8]
    subss   xmm0, [rsp+44]
    mulss   xmm0, xmm0
    movss   xmm1, [rsp+28+r14*8]
    subss   xmm1, [rsp+48]
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    cvttss2si eax, xmm0
    cmp     eax, [rsp+60]
    jge     21f
    mov     [rsp+60], eax
    mov     [rsp+52], r13d
    lea     eax, [r14+1]                # 1 head, 2 tail
    mov     [rsp+56], eax
21: inc     r14d
    cmp     r14d, 2
    jb      2b
3:  # the bone: distance to its segment on screen (worse than a joint)
    movss   xmm0, [rsp+32]              # d = b - a
    subss   xmm0, [rsp+24]
    movss   xmm1, [rsp+36]
    subss   xmm1, [rsp+28]
    movss   xmm2, [rsp+44]              # e = p - a
    subss   xmm2, [rsp+24]
    movss   xmm3, [rsp+48]
    subss   xmm3, [rsp+28]
    movss   xmm4, xmm0
    mulss   xmm4, xmm2
    movss   xmm5, xmm1
    mulss   xmm5, xmm3
    addss   xmm4, xmm5
    movss   xmm5, xmm0
    mulss   xmm5, xmm0
    movss   xmm6, xmm1
    mulss   xmm6, xmm1
    addss   xmm5, xmm6
    maxss   xmm5, [rip+am_eps]
    divss   xmm4, xmm5
    xorps   xmm6, xmm6
    maxss   xmm4, xmm6
    minss   xmm4, [rip+am_one]
    mulss   xmm0, xmm4
    mulss   xmm1, xmm4
    subss   xmm2, xmm0
    subss   xmm3, xmm1
    mulss   xmm2, xmm2
    mulss   xmm3, xmm3
    addss   xmm2, xmm3
    cvttss2si eax, xmm2
    add     eax, 30                     # (a joint wins when as near)
    cmp     eax, [rsp+60]
    jge     4f
    mov     [rsp+60], eax
    mov     [rsp+52], r13d
    mov     dword ptr [rsp+56], 7
4:  inc     r13d
    jmp     1b
5:  test    dword ptr [rsp+40], MOD_SHIFT
    jnz     6f
    xor     ecx, ecx                    # it alone
51: cmp     ecx, [r12+AR_N]
    jae     6f
    imul    rax, rcx, BN_SZ
    mov     byte ptr [r12+AR_BONES+rax+BN_SEL], 0
    inc     ecx
    jmp     51b
6:  mov     eax, [rsp+52]
    test    eax, eax
    js      .Lac_yes
    imul    rcx, rax, BN_SZ
    lea     rcx, [r12+AR_BONES+rcx]
    mov     edx, [rsp+56]
    test    dword ptr [rsp+40], MOD_SHIFT
    jz      7f
    xor     [rcx+BN_SEL], dl
    jmp     8f
7:  mov     [rcx+BN_SEL], dl
8:  mov     [r12+AR_ACT], eax
.Lac_yes:
    mov     dword ptr [rip+dirty], 1
    mov     eax, 1
    jmp     9f
.Lac_no:
    xor     eax, eax
9:  add     rsp, 64
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
# to_px_xy(edi=modifiers) - (the pointer: arm_pt_x / y) as physical floats
#   into the caller's rsp+44 / +48 (called from arm_click's frame)
to_px_xy:
    mov     edi, [rip+arm_pt_x]
    call    to_px
    cvtsi2ss xmm0, eax
    movss   [rsp+8+44], xmm0
    mov     edi, [rip+arm_pt_y]
    call    to_px
    cvtsi2ss xmm0, eax
    movss   [rsp+8+48], xmm0
    ret

# arm_click_at(edi=x, esi=y, edx=modifiers) - the entry from the viewport
.globl arm_click_at
arm_click_at:
    mov     [rip+arm_pt_x], edi
    mov     [rip+arm_pt_y], esi
    jmp     arm_click

.section .bss
arm_pt_x:       .skip 4
arm_pt_y:       .skip 4
.text

# arm_median(rdi=out world) -> eax = parts selected (their middle)
arm_median:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 40
    mov     r14, rdi
    xorps   xmm0, xmm0
    movups  [rsp], xmm0
    xor     r13d, r13d
    call    arm_get
    test    rax, rax
    jz      8f
    mov     rdi, rax
    push    rax
    call    au_setup
    pop     rdi
    call    arm_of
    mov     rbx, rax
    xor     r12d, r12d
1:  cmp     r12d, [rbx+AR_N]
    jae     8f
    mov     rdi, rbx
    mov     esi, r12d
    call    arm_bone
    movzx   eax, byte ptr [rax+BN_SEL]
    test    eax, eax
    jz      2f
    mov     rdi, rbx                    # (its head, or its tail alone)
    mov     esi, r12d
    xor     edx, edx
    cmp     eax, 2
    jne     11f
    mov     edx, 1
11: lea     rcx, [rsp+16]
    call    au_joint
    movss   xmm0, [rsp+16]
    insertps xmm0, [rsp+20], 0x10
    insertps xmm0, [rsp+24], 0x20
    movups  xmm1, [rsp]
    addps   xmm0, xmm1
    movups  [rsp], xmm0
    inc     r13d
2:  inc     r12d
    jmp     1b
8:  movups  xmm0, [rsp]
    test    r13d, r13d
    jz      9f
    cvtsi2ss xmm1, r13d
    shufps  xmm1, xmm1, 0
    divps   xmm0, xmm1
9:  movss   [r14], xmm0
    extractps dword ptr [r14+4], xmm0, 1
    extractps dword ptr [r14+8], xmm0, 2
    mov     eax, r13d
    add     rsp, 40
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# arm_tm_snapshot(rdi=pivot out) -> eax = parts that move. Edit mode: each
#   selected joint; pose mode: each selected bone (its pose, and F: the
#   frame its pose sits in, M = F P)
arm_tm_snapshot:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 48
    mov     r15, rdi
    mov     dword ptr [rip+at_n], 0
    call    arm_get
    test    rax, rax
    jz      .Lts_zero
    mov     r14, rax
    mov     rdi, rax
    call    arm_edit
    test    rax, rax
    jz      .Lts_zero
    mov     rbx, rax
    mov     rdi, r15
    call    arm_median
    mov     rdi, r14
    call    au_setup
    xor     r12d, r12d
1:  cmp     r12d, [rbx+AR_N]
    jae     .Lts_done
    mov     rdi, rbx
    mov     esi, r12d
    call    arm_bone
    mov     r13, rax
    movzx   eax, byte ptr [r13+BN_SEL]
    test    eax, eax
    jz      5f
    cmp     dword ptr [rip+arm_mode], 2
    je      4f
    test    eax, 1                      # edit mode: the joints
    jz      2f
    xor     esi, esi
    call    .Lts_joint
2:  test    byte ptr [r13+BN_SEL], 2
    jz      5f
    mov     esi, 1
    call    .Lts_joint
    jmp     5f
4:  call    .Lts_pose
5:  inc     r12d
    jmp     1b
.Lts_joint:                             # esi = 0 head / 1 tail of r12
    mov     eax, [rip+at_n]
    cmp     eax, AT_MAX
    jae     9f
    imul    rax, rax, AT_SZ
    lea     rdi, [rip+at_buf]
    add     rdi, rax
    mov     [rdi], r12d
    mov     [rdi+4], esi
    lea     rax, [r13+BN_HEAD]
    test    esi, esi
    jz      1f
    lea     rax, [r13+BN_TAIL]
1:  mov     rcx, [rax]
    mov     [rdi+20], rcx
    mov     ecx, [rax+8]
    mov     [rdi+28], ecx
    lea     rdx, [rdi+8]
    mov     rsi, rax
    lea     rdi, [rip+au_a]
    call    xform_point
    inc     dword ptr [rip+at_n]
9:  ret
.Lts_pose:                              # r12 = a selected bone
    mov     eax, [rip+at_n]
    cmp     eax, AT_MAX
    jae     9f
    imul    rax, rax, AT_SZ
    lea     rdi, [rip+at_buf]
    add     rdi, rax
    mov     [rdi], r12d
    mov     dword ptr [rdi+4], 2
    lea     rsi, [r13+BN_LOC]           # its pose (36 bytes at +32)
    push    rdi
    lea     rdi, [rdi+32]
    mov     ecx, 36
    rep     movsb
    pop     rdi
    push    rdi                         # F = M P^-1 at +64 (48 bytes)
    push    rdi
    lea     rdi, [r13+BN_LOC-OB_LOC]
    lea     rsi, [rip+au_m]
    call    obj_matrix
    lea     rdi, [rip+am_t]
    lea     rsi, [rip+au_m]
    call    m_inv
    pop     rdi
    pop     rdi
    lea     rdi, [rdi+64]
    imul    rsi, r12, 48
    lea     rax, [rip+am_m]
    add     rsi, rax
    lea     rdx, [rip+am_t]
    call    m_mul
    inc     dword ptr [rip+at_n]
9:  ret
.Lts_done:
    mov     eax, [rip+at_n]
    jmp     9f
.Lts_zero:
    xor     eax, eax
9:  add     rsp, 48
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# at_block -> rbx = the bones (in place: the snapshot made them unshared),
#   r14 = the object; 0 when not in a mode
at_block:
    call    arm_get
    test    rax, rax
    jz      9f
    mov     r14, rax
    mov     rdi, rax
    call    arm_of
    mov     rbx, rax
9:  ret

# at_finish - joined joints follow, the display mesh shows it
at_finish:
    push    rbx
    push    r14
    sub     rsp, 8
    call    at_block
    test    rax, rax
    jz      9f
    cmp     dword ptr [rip+arm_mode], 1
    jne     8f
    xor     ecx, ecx                    # a joined bone's head = its parent's tail
1:  cmp     ecx, [rbx+AR_N]
    jae     8f
    imul    rax, rcx, BN_SZ
    lea     rax, [rbx+AR_BONES+rax]
    cmp     byte ptr [rax+BN_CONN], 0
    je      3f
    mov     edx, [rax+BN_PARENT]
    test    edx, edx
    js      3f
    imul    rdx, rdx, BN_SZ
    lea     rdx, [rbx+AR_BONES+rdx]
    test    byte ptr [rax+BN_SEL], 1    # the child's head moved: the parent's
    jz      2f                          #  tail with it
    test    byte ptr [rdx+BN_SEL], 2
    jnz     2f
    mov     r8, [rax+BN_HEAD]
    mov     [rdx+BN_TAIL], r8
    mov     r8d, [rax+BN_HEAD+8]
    mov     [rdx+BN_TAIL+8], r8d
    jmp     3f
2:  mov     r8, [rdx+BN_TAIL]
    mov     [rax+BN_HEAD], r8
    mov     r8d, [rdx+BN_TAIL+8]
    mov     [rax+BN_HEAD+8], r8d
3:  inc     ecx
    jmp     1b
8:  mov     rdi, r14
    call    arm_rebuild
9:  add     rsp, 8
    pop     r14
    pop     rbx
    ret

# at_store(r12=entry, xmm0..2 = world) - edit mode: the joint, armature space
at_store:
    sub     rsp, 24
    movss   [rsp], xmm0
    movss   [rsp+4], xmm1
    movss   [rsp+8], xmm2
    mov     rdi, rbx
    mov     esi, [r12]
    call    arm_bone
    lea     rdx, [rax+BN_HEAD]
    cmp     dword ptr [r12+4], 0
    je      1f
    lea     rdx, [rax+BN_TAIL]
1:  lea     rdi, [rip+au_ai]
    lea     rsi, [rsp]
    call    xform_point
    add     rsp, 24
    ret

# at_restore_pose(r12=entry) -> rax = its bone with the snapshotted pose
at_restore_pose:
    mov     rdi, rbx
    mov     esi, [r12]
    call    arm_bone
    push    rax
    lea     rdi, [rax+BN_LOC]
    lea     rsi, [r12+32]
    mov     ecx, 36
    rep     movsb
    pop     rax
    ret

arm_tm_restore:
    push    rbx
    push    r12
    push    r14
    call    at_block
    test    rax, rax
    jz      9f
    lea     r12, [rip+at_buf]
    xor     ecx, ecx
1:  cmp     ecx, [rip+at_n]
    jae     8f
    push    rcx
    sub     rsp, 8
    cmp     dword ptr [r12+4], 2
    je      2f
    movss   xmm0, [r12+8]
    movss   xmm1, [r12+12]
    movss   xmm2, [r12+16]
    call    at_store
    jmp     3f
2:  call    at_restore_pose
3:  add     rsp, 8
    pop     rcx
    add     r12, AT_SZ
    inc     ecx
    jmp     1b
8:  call    at_finish
9:  pop     r14
    pop     r12
    pop     rbx
    ret

# arm_tm_grab(rdi=world delta)
arm_tm_grab:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 40
    mov     r13, rdi
    call    at_block
    test    rax, rax
    jz      9f
    lea     r12, [rip+at_buf]
    xor     ecx, ecx
1:  cmp     ecx, [rip+at_n]
    jae     8f
    mov     [rsp+32], ecx
    cmp     dword ptr [r12+4], 2
    je      2f
    movss   xmm0, [r12+8]               # a joint: world + delta
    addss   xmm0, [r13]
    movss   xmm1, [r12+12]
    addss   xmm1, [r13+4]
    movss   xmm2, [r12+16]
    addss   xmm2, [r13+8]
    call    at_store
    jmp     3f
2:  call    at_restore_pose             # a bone: delta into F's axes
    mov     [rsp+24], rax
    xor     ecx, ecx                    # armature space (A's inverse, 3x3)
21: imul    rdx, rcx, 16
    lea     rax, [rip+au_ai]
    movss   xmm0, [rax+rdx]
    mulss   xmm0, [r13]
    movss   xmm1, [rax+rdx+4]
    mulss   xmm1, [r13+4]
    addss   xmm0, xmm1
    movss   xmm1, [rax+rdx+8]
    mulss   xmm1, [r13+8]
    addss   xmm0, xmm1
    movss   [rsp+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      21b
    lea     rdi, [rip+am_t]             # F's 3x3 inverse
    lea     rsi, [r12+64]
    call    m_inv
    mov     rax, [rsp+24]
    xor     ecx, ecx
22: imul    rdx, rcx, 16
    lea     r8, [rip+am_t]
    movss   xmm0, [r8+rdx]
    mulss   xmm0, [rsp]
    movss   xmm1, [r8+rdx+4]
    mulss   xmm1, [rsp+4]
    addss   xmm0, xmm1
    movss   xmm1, [r8+rdx+8]
    mulss   xmm1, [rsp+8]
    addss   xmm0, xmm1
    addss   xmm0, [rax+BN_LOC+rcx*4]
    movss   [rax+BN_LOC+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      22b
3:  add     r12, AT_SZ
    mov     ecx, [rsp+32]
    inc     ecx
    jmp     1b
8:  call    at_finish
9:  add     rsp, 40
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# arm_tm_rotate(edi=axis 1..3, xmm0=sin, xmm1=cos, rsi=pivot) - joints about
#   the pivot; bones about their own heads (their pose's rotation)
arm_tm_rotate:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 64
    movss   [rsp], xmm0
    movss   [rsp+4], xmm1
    mov     r15, rsi
    mov     r13d, edi                   # a = axis (3 -> 0), b = a + 1
    cmp     r13d, 3
    jb      1f
    xor     r13d, r13d
1:  lea     eax, [r13+1]
    cmp     eax, 3
    jb      2f
    xor     eax, eax
2:  mov     [rsp+8], eax
    call    at_block
    test    rax, rax
    jz      9f
    lea     rdi, [rip+au_rw]            # Rw: the world rotation
    lea     rsi, [rip+am_ident]
    mov     ecx, 48
    rep     movsb
    lea     rdx, [rip+au_rw]
    imul    eax, r13d, 20               # [a][a] = c, [a][b] = -s, [b][a] = s, [b][b] = c
    movss   xmm0, [rsp+4]
    movss   [rdx+rax], xmm0
    mov     ecx, [rsp+8]
    imul    eax, ecx, 20
    movss   [rdx+rax], xmm0
    mov     eax, r13d
    shl     eax, 4
    lea     eax, [rax+rcx*4]
    xorps   xmm0, xmm0
    subss   xmm0, [rsp]
    movss   [rdx+rax], xmm0
    shl     ecx, 4
    lea     eax, [rcx+r13*4]
    movss   xmm0, [rsp]
    movss   [rdx+rax], xmm0
    lea     r12, [rip+at_buf]
    xor     r14d, r14d
3:  cmp     r14d, [rip+at_n]
    jae     8f
    cmp     dword ptr [r12+4], 2
    je      5f
    xor     ecx, ecx                    # a joint about the pivot
4:  movss   xmm0, [r12+8+rcx*4]
    subss   xmm0, [r15+rcx*4]
    movss   [rsp+16+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      4b
    lea     rdi, [rip+au_rw]
    lea     rsi, [rsp+16]
    lea     rdx, [rsp+32]
    call    xform_point
    movss   xmm0, [rsp+32]
    addss   xmm0, [r15]
    movss   xmm1, [rsp+36]
    addss   xmm1, [r15+4]
    movss   xmm2, [rsp+40]
    addss   xmm2, [r15+8]
    call    at_store
    jmp     7f
5:  call    at_restore_pose             # a bone: P' = F^-1 Ra (F P), Euler
    mov     [rsp+48], rax
    lea     rdi, [rip+au_m]             # Ra = A^-1 Rw A (rotation)
    lea     rsi, [rip+au_rw]
    lea     rdx, [rip+au_a]
    call    m_mul
    lea     rdi, [rip+am_t2]
    lea     rsi, [rip+au_ai]
    lea     rdx, [rip+au_m]
    call    m_mul
    mov     rax, [rsp+48]               # the current M = F P
    lea     rdi, [rax+BN_LOC-OB_LOC]
    lea     rsi, [rip+au_m]
    call    obj_matrix
    lea     rdi, [rip+am_t]
    lea     rsi, [r12+64]
    lea     rdx, [rip+au_m]
    call    m_mul                       # M at am_t
    xor     ecx, ecx                    # Ra M's rotation (keep M's head)
51: imul    rdx, rcx, 16
    lea     r8, [rip+am_t]
    mov     eax, [r8+rdx+12]
    mov     [rsp+16+rcx*4], eax
    lea     r8, [rip+am_t2]
    mov     dword ptr [r8+rdx+12], 0    # (Ra: no translation)
    inc     ecx
    cmp     ecx, 3
    jb      51b
    lea     rdi, [rip+au_m]
    lea     rsi, [rip+am_t2]
    lea     rdx, [rip+am_t]
    call    m_mul
    xor     ecx, ecx
52: imul    rdx, rcx, 16
    mov     eax, [rsp+16+rcx*4]
    lea     r8, [rip+au_m]
    mov     [r8+rdx+12], eax
    inc     ecx
    cmp     ecx, 3
    jb      52b
    lea     rdi, [rip+am_t]             # P' = F^-1 M'
    lea     rsi, [r12+64]
    call    m_inv
    lea     rdi, [rip+am_t2]
    lea     rsi, [rip+am_t]
    lea     rdx, [rip+au_m]
    call    m_mul
    mov     rdi, [rsp+48]
    lea     rsi, [rip+am_t2]
    call    pose_from_mat
7:  add     r12, AT_SZ
    inc     r14d
    jmp     3b
8:  call    at_finish
9:  add     rsp, 64
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# pose_from_mat(rdi=bone, rsi=3x4 P) - location, scale (column lengths),
#   Euler XYZ of R = Rz Ry Rx: y = asin(-m20), x = atan2(m21, m22),
#   z = atan2(m10, m00)
pose_from_mat:
    push    rbx
    push    r12
    sub     rsp, 56
    mov     rbx, rdi
    mov     r12, rsi
    mov     eax, [r12+12]
    mov     [rbx+BN_LOC], eax
    mov     eax, [r12+28]
    mov     [rbx+BN_LOC+4], eax
    mov     eax, [r12+44]
    mov     [rbx+BN_LOC+8], eax
    xor     ecx, ecx                    # scale, the rotation unit
1:  movss   xmm0, [r12+rcx*4]
    mulss   xmm0, xmm0
    movss   xmm1, [r12+16+rcx*4]
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    movss   xmm1, [r12+32+rcx*4]
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    sqrtss  xmm0, xmm0
    maxss   xmm0, [rip+am_tiny]
    movss   [rbx+BN_SCALE+rcx*4], xmm0
    movss   xmm1, [r12+rcx*4]
    divss   xmm1, xmm0
    movss   [rsp+rcx*4], xmm1           # row 0
    movss   xmm1, [r12+16+rcx*4]
    divss   xmm1, xmm0
    movss   [rsp+12+rcx*4], xmm1        # row 1
    movss   xmm1, [r12+32+rcx*4]
    divss   xmm1, xmm0
    movss   [rsp+24+rcx*4], xmm1        # row 2
    inc     ecx
    cmp     ecx, 3
    jb      1b
    xorps   xmm0, xmm0                  # y = atan2(-m20, sqrt(m00^2 + m10^2))
    subss   xmm0, [rsp+24]
    movss   xmm1, [rsp]
    mulss   xmm1, xmm1
    movss   xmm2, [rsp+12]
    mulss   xmm2, xmm2
    addss   xmm1, xmm2
    sqrtss  xmm1, xmm1
    call    at2
    movss   [rbx+BN_ROT+4], xmm0
    movss   xmm0, [rsp+28]              # x = atan2(m21, m22)
    movss   xmm1, [rsp+32]
    call    at2
    movss   [rbx+BN_ROT], xmm0
    movss   xmm0, [rsp+12]              # z = atan2(m10, m00)
    movss   xmm1, [rsp]
    call    at2
    movss   [rbx+BN_ROT+8], xmm0
    add     rsp, 56
    pop     r12
    pop     rbx
    ret
at2:
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

# arm_tm_scale(xmm0=factor, edi=axis 0 all / 1..3, rsi=pivot)
arm_tm_scale:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 48
    movss   [rsp], xmm0
    mov     r13d, edi
    mov     r15, rsi
    call    at_block
    test    rax, rax
    jz      9f
    lea     r12, [rip+at_buf]
    xor     r14d, r14d
1:  cmp     r14d, [rip+at_n]
    jae     8f
    cmp     dword ptr [r12+4], 2
    je      4f
    xor     ecx, ecx                    # a joint from the pivot
2:  movss   xmm0, [r12+8+rcx*4]
    test    r13d, r13d
    jz      21f
    lea     eax, [rcx+1]
    cmp     eax, r13d
    jne     22f
21: subss   xmm0, [r15+rcx*4]
    mulss   xmm0, [rsp]
    addss   xmm0, [r15+rcx*4]
22: movss   [rsp+16+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      2b
    movss   xmm0, [rsp+16]
    movss   xmm1, [rsp+20]
    movss   xmm2, [rsp+24]
    call    at_store
    jmp     7f
4:  call    at_restore_pose             # a bone: its pose scale
    xor     ecx, ecx
5:  test    r13d, r13d
    jz      51f
    lea     edx, [rcx+1]
    cmp     edx, r13d
    jne     52f
51: movss   xmm0, [rax+BN_SCALE+rcx*4]
    mulss   xmm0, [rsp]
    movss   [rax+BN_SCALE+rcx*4], xmm0
52: inc     ecx
    cmp     ecx, 3
    jb      5b
7:  add     r12, AT_SZ
    inc     r14d
    jmp     1b
8:  call    at_finish
9:  add     rsp, 48
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ---- mode operators ---------------------------------------------------------------
# arm.extrude: a new bone from each selected tail (as long, the same way)
do_arm_extrude:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 48
    xor     r15d, r15d
    call    arm_get
    test    rax, rax
    jz      8f
    cmp     dword ptr [rip+arm_mode], 1
    jne     8f
    mov     r14, rax
    mov     rdi, rax
    call    arm_edit
    test    rax, rax
    jz      8f
    mov     rbx, rax
    mov     r13d, [rbx+AR_N]
    xor     r12d, r12d
1:  cmp     r12d, r13d
    jae     5f
    mov     rdi, rbx
    mov     esi, r12d
    call    arm_bone
    test    byte ptr [rax+BN_SEL], 2
    jz      4f
    mov     byte ptr [rax+BN_SEL], 0
    xor     ecx, ecx                    # head = tail, tail = tail + (tail - head)
2:  movss   xmm0, [rax+BN_TAIL+rcx*4]
    movss   [rsp+rcx*4], xmm0
    addss   xmm0, xmm0
    subss   xmm0, [rax+BN_HEAD+rcx*4]
    movss   [rsp+16+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      2b
    mov     rdi, rbx
    xor     esi, esi
    mov     edx, r12d
    lea     rcx, [rsp]
    lea     r8, [rsp+16]
    call    arm_add_bone
    test    eax, eax
    js      4f
    mov     rdi, rbx
    mov     esi, eax
    call    arm_bone
    mov     byte ptr [rax+BN_CONN], 1
    mov     byte ptr [rax+BN_SEL], 2    # its tail, ready to move
    inc     r15d
4:  inc     r12d
    jmp     1b
5:  test    r15d, r15d
    jz      7f
    mov     rdi, r14
    call    arm_rebuild
    call    interactive
    test    eax, eax
    jz      9f
    mov     dword ptr [rip+tm_noundo], 1
    mov     edi, 1
    xor     esi, esi
    xor     edx, edx
    call    tm_start
    jmp     9f
7:  lea     rdi, [rip+s_arm_extr]
    call    log_line
8:  call    undo_drop_last
9:  add     rsp, 48
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# arm.delete_bones: the selected bones go; their children take their
#   parent; every mesh skinned by this armature has its weights renumbered
do_arm_delete:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, AR_MAXB+16
    call    arm_get
    test    rax, rax
    jz      8f
    cmp     dword ptr [rip+arm_mode], 1
    jne     8f
    mov     r14, rax
    mov     rdi, rax
    call    arm_edit
    test    rax, rax
    jz      8f
    mov     rbx, rax
    xor     r12d, r12d                  # map: old -> new (0xff gone)
    xor     r13d, r13d
1:  cmp     r12d, [rbx+AR_N]
    jae     2f
    mov     rdi, rbx
    mov     esi, r12d
    call    arm_bone
    mov     byte ptr [rsp+r12], 0xff
    test    byte ptr [rax+BN_SEL], 4
    jnz     11f
    mov     [rsp+r12], r13b
    inc     r13d
11: inc     r12d
    jmp     1b
2:  cmp     r13d, [rbx+AR_N]
    je      8f                          # (nothing selected)
    test    r13d, r13d
    jz      8f                          # (not every bone)
    xor     r12d, r12d                  # parents up past deleted ones
3:  cmp     r12d, [rbx+AR_N]
    jae     4f
    mov     rdi, rbx
    mov     esi, r12d
    call    arm_bone
    mov     r15, rax
31: mov     eax, [r15+BN_PARENT]
    test    eax, eax
    js      32f
    cmp     byte ptr [rsp+rax], 0xff
    jne     32f
    imul    rcx, rax, BN_SZ
    mov     eax, [rbx+AR_BONES+rcx+BN_PARENT]
    mov     [r15+BN_PARENT], eax
    mov     byte ptr [r15+BN_CONN], 0
    jmp     31b
32: inc     r12d
    jmp     3b
4:  xor     r12d, r12d                  # compact, parents renumbered
    xor     r13d, r13d
41: cmp     r12d, [rbx+AR_N]
    jae     5f
    cmp     byte ptr [rsp+r12], 0xff
    je      44f
    mov     rdi, rbx
    mov     esi, r12d
    call    arm_bone
    mov     rsi, rax
    mov     ecx, [rsi+BN_PARENT]
    test    ecx, ecx
    js      42f
    movzx   ecx, byte ptr [rsp+rcx]
    mov     [rsi+BN_PARENT], ecx
42: mov     rdi, rbx
    push    rsi
    mov     esi, r13d
    call    arm_bone
    pop     rsi
    cmp     rax, rsi
    je      43f
    mov     rdi, rax
    mov     ecx, BN_SZ
    rep     movsb
43: inc     r13d
44: inc     r12d
    jmp     41b
5:  mov     [rbx+AR_N], r13d
    mov     dword ptr [rbx+AR_ACT], 0
    mov     rdi, r14
    call    arm_rebuild
    xor     r12d, r12d                  # the skinned meshes' weights
6:  cmp     r12d, [rip+obj_count]
    jae     9f
    mov     edi, r12d
    call    obj_at
    mov     r15, rax
    mov     rdi, rax
    call    arm_mod_target
    cmp     rax, r14
    jne     65f
    mov     rdi, [r15+OB_MESH]
    cmp     qword ptr [rdi+ME_WGT], 0
    je      65f
    mov     rdi, r15
    call    arm_mesh_own
    mov     rdx, [rax+ME_WGT]
    xor     ecx, ecx
61: cmp     ecx, [rax+ME_NVERTS]
    jae     64f
    imul    r8, rcx, 20
    add     r8, rdx
    xor     r9d, r9d
62: cmp     r9d, 4
    jae     63f
    movzx   r10d, byte ptr [r8+r9]
    cmp     r10d, 0xff
    je      621f
    movzx   r10d, byte ptr [rsp+r10]
    mov     [r8+r9], r10b
    cmp     r10d, 0xff
    jne     621f
    mov     dword ptr [r8+4+r9*4], 0
621:inc     r9d
    jmp     62b
63: inc     ecx
    jmp     61b
64: inc     dword ptr [rax+ME_VER]
65: inc     r12d
    jmp     6b
8:  call    undo_drop_last
9:  call    eval_flush
    add     rsp, AR_MAXB+16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

do_arm_selall:
    sub     rsp, 8
    call    arm_get
    test    rax, rax
    jz      9f
    mov     rdi, rax
    call    arm_of
    xor     ecx, ecx
    xor     edx, edx
1:  cmp     ecx, [rax+AR_N]
    jae     2f
    imul    r8, rcx, BN_SZ
    or      dl, [rax+AR_BONES+r8+BN_SEL]
    inc     ecx
    jmp     1b
2:  mov     r9d, 7
    test    dl, dl
    jz      3f
    xor     r9d, r9d
3:  xor     ecx, ecx
4:  cmp     ecx, [rax+AR_N]
    jae     9f
    imul    r8, rcx, BN_SZ
    mov     [rax+AR_BONES+r8+BN_SEL], r9b
    inc     ecx
    jmp     4b
9:  mov     dword ptr [rip+dirty], 1
    add     rsp, 8
    ret

# arm.insert_key: pose mode, the selected bones' nine channels at the frame
do_arm_key:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    call    arm_get
    test    rax, rax
    jz      8f
    cmp     dword ptr [rip+arm_mode], 2
    jne     8f
    mov     r14, rax
    mov     rdi, rax
    call    arm_of
    mov     rbx, rax
    xor     r12d, r12d
1:  cmp     r12d, [rbx+AR_N]
    jae     9f
    mov     rdi, rbx
    mov     esi, r12d
    call    arm_bone
    cmp     byte ptr [rax+BN_SEL], 0
    je      3f
    xor     r13d, r13d
2:  cmp     r13d, 9
    jae     3f
    mov     edi, [r14+OB_UID]
    mov     esi, r12d
    mov     edx, r13d
    call    an_bone_key
    mov     rdi, r14                    # (the bones may be a copy now)
    call    arm_of
    mov     rbx, rax
    inc     r13d
    jmp     2b
3:  inc     r12d
    jmp     1b
8:  call    undo_drop_last
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

arm_tm_end:
    ret
