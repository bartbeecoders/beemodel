# =============================================================================
#  BeeModel - OpenUSD physics (UsdPhysics) on import: rigid bodies and
#  joints, made with BeeModel's own rigid.add and rigid.joint (rbody.s), so
#  they behave as hand-made ones do.
#
#  A prim with PhysicsRigidBodyAPI is a body; the objects imported under it
#  are its parts (more than one - one a material: the others joined to the
#  first by fixed joints). Its mass: physics:mass (MassAPI) on the body or
#  summed over its meshes (else BeeModel's density), shared by its parts;
#  no part lighter than 1/10 of the heaviest (joint chains with 1000:1
#  mass ratios do not hold together in an iterative solver). Its shape from the
#  meshes' physics:approximation: convexHull -> hull, boundingCube -> box,
#  boundingSphere -> sphere, the rest (sdf, convexDecomposition,
#  meshSimplification, none) -> compound. kinematicEnabled -> passive.
#  Friction and bounce: the physics material bound (material:binding:
#  physics on a mesh or the body): dynamicFriction, restitution.
#  Joints (PhysicsRevoluteJoint -> hinge, PrismaticJoint -> slider,
#  FixedJoint -> fixed, SphericalJoint -> point): body0 / body1 (no body:
#  the world), the pivot localPos0 in body0's frame, the axis (X / Y / Z
#  through localRot0), limits (degrees for hinges, metres for sliders); a
#  joint with a drive (PhysicsDriveAPI) is held where it starts (limits 0 0:
#  BeeModel's motors are no position springs); disabled ones are left out.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"
.include "usd.inc"

.globl usdphys_reset
.globl usdphys_enter
.globl usdphys_leave
.globl usdphys_object
.globl usdphys_finish
.globl usd_nbodies
.globl usd_njoints

.equ UP_MAXB,  1024                     # bodies an import
.equ UP_MAXO,  4096                     # objects in bodies
.equ UP_MAXJ,  1024                     # joints

# a body
.equ PB_PRIM,   0
.equ PB_FIRST,  4                       # its first object (handle), 0
.equ PB_NOBJ,   8
.equ PB_SHAPE,  12                      # 0 compound 1 hull 2 box 3 sphere
.equ PB_MASS,   16                      # (double) 0: not given
.equ PB_PMAT,   24                      # its physics material (stage path)
.equ PB_LASTM,  32                      # the last mesh prim counted
.equ PB_PASS,   36                      # kinematic: passive
.equ PB_W,      40                      # its world matrix (stage, 16 doubles)
.equ PB_SZ,     168

.section .rodata
.align 8
a_api:      .asciz "apiSchemas"
v_rbapi:    .asciz "PhysicsRigidBodyAPI"
a_rben:     .asciz "physics:rigidBodyEnabled"
a_kin:      .asciz "physics:kinematicEnabled"
a_mass:     .asciz "physics:mass"
a_approx:   .asciz "physics:approximation"
r_pmat:     .asciz "material:binding:physics"
a_dfric:    .asciz "physics:dynamicFriction"
a_rest:     .asciz "physics:restitution"
f_default:  .asciz "default"
f_tname:    .asciz "typeName"
t_revolute: .asciz "PhysicsRevoluteJoint"
t_prism:    .asciz "PhysicsPrismaticJoint"
t_fixed:    .asciz "PhysicsFixedJoint"
t_sphere:   .asciz "PhysicsSphericalJoint"
r_body0:    .asciz "physics:body0"
r_body1:    .asciz "physics:body1"
a_lpos0:    .asciz "physics:localPos0"
a_lrot0:    .asciz "physics:localRot0"
a_axis:     .asciz "physics:axis"
a_lower:    .asciz "physics:lowerLimit"
a_upper:    .asciz "physics:upperLimit"
a_jen:      .asciz "physics:jointEnabled"
v_hull:     .asciz "convexHull"
v_bcube:    .asciz "boundingCube"
v_bsph:     .asciz "boundingSphere"
v_drivel:   .asciz "PhysicsDriveAPI:linear"
v_drivea:   .asciz "PhysicsDriveAPI:angular"
s_shapes:   .quad s_compound, s_hull, s_box, s_sphere
s_compound: .asciz "compound"
s_hull:     .asciz "hull"
s_box:      .asciz "box"
s_sphere:   .asciz "sphere"
s_jtypes:   .quad s_hinge, s_slider, s_jfixed, s_point
s_hinge:    .asciz "hinge"
s_slider:   .asciz "slider"
s_jfixed:   .asciz "fixed"
s_point:    .asciz "point"
s_active:   .asciz "active "
s_passive:  .asciz "passive "
s_k_mass:   .asciz " mass "
s_k_fric:   .asciz " friction "
s_k_bounce: .asciz " bounce "
s_k_group:  .asciz " group "
s_k_coll:   .asciz " collide "
s_k_pivot:  .asciz " pivot "
s_k_axis:   .asciz " axis "
s_k_lim:    .asciz " limits "
s_world:    .asciz "world"
s_rbadd:    .asciz "rigid.add"
s_rbjoint:  .asciz "rigid.joint"
.align 8
d_lim:      .double 1.0e30              # limits beyond: none
d_deg:      .double 1.0
d_ratio:    .double 0.1                 # parts weigh at least 1/10 of the
                                        #  heaviest (joint chains stay stable)

.section .bss
.align 8
up_b:       .skip PB_SZ*UP_MAXB
up_nb:      .skip 4
up_cur:     .skip 4                     # the body being walked, -1
up_obj:     .skip 8*UP_MAXO             # objects: handle, body
up_no:      .skip 4
up_j:       .skip 4*UP_MAXJ             # joint prims
up_nj:      .skip 4
usd_nbodies: .skip 4                    # made by the last import
usd_njoints: .skip 4
up_txt:     .skip 512
up_group:   .skip 4                     # the import's collision group (1 .. 15)
up_ngrp:    .skip 4                     # (the next one: imports take turns)

.text

usdphys_reset:
    mov     eax, [rip+up_ngrp]          # this import's group: its parts meet
    inc     eax                         #  everything but each other (they
    cmp     eax, 15                     #  overlap where they join, as PhysX
    jbe     1f                          #  articulations let them)
    mov     eax, 1
1:  mov     [rip+up_ngrp], eax
    mov     [rip+up_group], eax
    mov     dword ptr [rip+up_nb], 0
    mov     dword ptr [rip+up_no], 0
    mov     dword ptr [rip+up_nj], 0
    mov     dword ptr [rip+up_cur], -1
    mov     dword ptr [rip+usd_nbodies], 0
    mov     dword ptr [rip+usd_njoints], 0
    ret

# up_has_api(edi=prim, rsi=schema) -> eax = 1 when its apiSchemas (any
#   opinion: they add up) list it
up_has_api:
    mov     rdx, rsi
    lea     rsi, [rip+a_api]
    jmp     us_pany

# up_attr(edi=prim, rsi=attribute) -> rax = its default value (0)
up_attr:
    lea     rdx, [rip+f_default]
    jmp     us_aget

# up_isdbl(rax=value) -> xmm0 = it as a double, eax = 1 (0: not a number)
up_isdbl:
    test    rax, rax
    jz      8f
    cmp     dword ptr [rax+UV_T], UT_DBL
    jne     1f
    movsd   xmm0, [rax+UV_D]
    mov     eax, 1
    ret
1:  cmp     dword ptr [rax+UV_T], UT_INT
    jne     8f
    cvtsi2sd xmm0, qword ptr [rax+UV_D]
    mov     eax, 1
    ret
8:  xor     eax, eax
    ret

# usdphys_enter(edi=prim, rsi=its world matrix (stage)) -> eax = the body
#   that was current (for usdphys_leave). A body or a joint is noted.
usdphys_enter:
    push    rbx
    push    r12
    push    r13
    mov     ebx, edi
    mov     r12, rsi
    mov     r13d, [rip+up_cur]
    mov     edi, ebx                    # a joint?
    call    up_jointkind
    test    eax, eax
    js      1f
    mov     ecx, [rip+up_nj]
    cmp     ecx, UP_MAXJ
    jae     7f
    lea     rax, [rip+up_j]
    mov     [rax+rcx*4], ebx
    inc     dword ptr [rip+up_nj]
    jmp     7f
1:  mov     edi, ebx                    # a body?
    lea     rsi, [rip+v_rbapi]
    call    up_has_api
    test    eax, eax
    jz      7f
    mov     edi, ebx
    lea     rsi, [rip+a_rben]
    call    up_attr
    test    rax, rax
    jz      2f
    cmp     dword ptr [rax+UV_T], UT_INT
    jne     2f
    cmp     qword ptr [rax+UV_D], 0
    je      7f
2:  mov     ecx, [rip+up_nb]
    cmp     ecx, UP_MAXB
    jae     7f
    imul    rdi, rcx, PB_SZ
    lea     rax, [rip+up_b]
    add     rdi, rax
    push    rdi
    push    rcx
    xor     eax, eax                    # (a clean record)
    mov     ecx, PB_SZ/8
    rep     stosq
    pop     rcx
    pop     rdi
    mov     [rdi+PB_PRIM], ebx
    mov     dword ptr [rdi+PB_LASTM], -1
    push    rdi
    push    rcx
    lea     rdi, [rdi+PB_W]
    mov     rsi, r12
    call    m4_copy
    pop     rcx
    pop     rdi
    mov     [rip+up_cur], ecx
    inc     dword ptr [rip+up_nb]
    push    rdi                         # its own mass, kinematic, material
    push    rdi
    mov     edi, ebx
    lea     rsi, [rip+a_mass]
    call    up_attr
    call    up_isdbl
    pop     rdi
    pop     rdi
    test    eax, eax
    jz      3f
    movsd   [rdi+PB_MASS], xmm0
    mov     dword ptr [rdi+PB_LASTM], ebx
3:  push    rdi
    push    rdi
    mov     edi, ebx
    lea     rsi, [rip+a_kin]
    call    up_attr
    pop     rdi
    pop     rdi
    test    rax, rax
    jz      4f
    cmp     dword ptr [rax+UV_T], UT_INT
    jne     4f
    cmp     qword ptr [rax+UV_D], 0
    je      4f
    mov     dword ptr [rdi+PB_PASS], 1
4:  push    rdi
    push    rdi
    mov     edi, ebx
    lea     rsi, [rip+r_pmat]
    call    us_rel
    pop     rdi
    pop     rdi
    mov     [rdi+PB_PMAT], rax
7:  mov     eax, r13d
    pop     r13
    pop     r12
    pop     rbx
    ret

# usdphys_leave(edi=the body usdphys_enter gave)
usdphys_leave:
    mov     [rip+up_cur], edi
    ret

# up_jointkind(edi=prim) -> eax = 0 hinge, 1 slider, 2 fixed, 3 point; -1
up_jointkind:
    push    rbx
    sub     rsp, 16
    lea     rsi, [rip+f_tname]
    call    us_pget
    test    rax, rax
    jz      8f
    cmp     dword ptr [rax+UV_T], UT_STR
    jne     8f
    mov     rbx, [rax+UV_P]
    xor     ecx, ecx
1:  cmp     ecx, 4
    jae     8f
    mov     [rsp], ecx
    lea     rax, [rip+up_jnames]
    mov     rsi, [rax+rcx*8]
    mov     rdi, rbx
    call    str_eq
    mov     ecx, [rsp]
    test    eax, eax
    jnz     9f
    inc     ecx
    jmp     1b
8:  mov     ecx, -1
9:  mov     eax, ecx
    add     rsp, 16
    pop     rbx
    ret

.section .rodata
.align 8
up_jnames:  .quad t_revolute, t_prism, t_fixed, t_sphere
.text

# usdphys_object(edi=mesh prim, rsi=object record, edx=its handle) - a
#   part of the current body (if there is one): its mesh's mass,
#   approximation and physics material
usdphys_object:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     ebx, edi
    mov     r13d, edx
    mov     eax, [rip+up_cur]
    test    eax, eax
    js      9f
    imul    r14, rax, PB_SZ
    lea     rcx, [rip+up_b]
    add     r14, rcx
    mov     ecx, [rip+up_no]
    cmp     ecx, UP_MAXO
    jae     9f
    lea     rdx, [rip+up_obj]
    mov     [rdx+rcx*8], r13d
    mov     [rdx+rcx*8+4], eax
    inc     dword ptr [rip+up_no]
    inc     dword ptr [r14+PB_NOBJ]
    cmp     dword ptr [r14+PB_FIRST], 0
    jne     1f
    mov     [r14+PB_FIRST], r13d
1:  cmp     [r14+PB_LASTM], ebx         # (a mesh split by material: once)
    je      9f
    mov     [r14+PB_LASTM], ebx
    mov     edi, ebx                    # its mass, added
    lea     rsi, [rip+a_mass]
    call    up_attr
    call    up_isdbl
    test    eax, eax
    jz      2f
    addsd   xmm0, [r14+PB_MASS]
    movsd   [r14+PB_MASS], xmm0
2:  mov     edi, ebx                    # its approximation
    lea     rsi, [rip+a_approx]
    call    up_attr
    test    rax, rax
    jz      3f
    cmp     dword ptr [rax+UV_T], UT_STR
    jne     3f
    mov     r12, [rax+UV_P]
    mov     rdi, r12
    lea     rsi, [rip+v_hull]
    call    str_eq
    mov     ecx, 1
    test    eax, eax
    jnz     21f
    mov     rdi, r12
    lea     rsi, [rip+v_bcube]
    call    str_eq
    mov     ecx, 2
    test    eax, eax
    jnz     21f
    mov     rdi, r12
    lea     rsi, [rip+v_bsph]
    call    str_eq
    mov     ecx, 3
    test    eax, eax
    jnz     21f
    xor     ecx, ecx
21: mov     [r14+PB_SHAPE], ecx
3:  cmp     qword ptr [r14+PB_PMAT], 0  # its physics material
    jne     9f
    mov     edi, ebx
    lea     rsi, [rip+r_pmat]
    call    us_rel
    mov     [r14+PB_PMAT], rax
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Making them
# =============================================================================
# up_run(rdi=operator name, rsi=argument text) - the operator's exec, as
#   run_op does (aligned stack, scratch memory) but quietly, inside the
#   import's undo step
up_run:
    push    rbx
    push    r12
    push    rbp
    mov     r12, rsi
    call    find_op_by_name
    test    rax, rax
    jz      9f
    mov     rbx, rax
    mov     rax, [rip+op_arg]
    push    rax
    mov     [rip+op_arg], r12
    sub     rsp, 8
    call    fa_mark
    add     rsp, 8
    mov     rbp, rsp
    and     rsp, -16
    mov     rdi, [rbx+OP_ARG]
    mov     rsi, rbx
    call    [rbx+OP_EXEC]
    mov     rsp, rbp
    sub     rsp, 8
    call    fa_release
    add     rsp, 8
    pop     rax
    mov     [rip+op_arg], rax
9:  pop     rbp
    pop     r12
    pop     rbx
    ret

# up_select(edi=body) - exactly its objects selected (the first active)
up_select:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     ebx, edi
    call    select_none
    xor     r12d, r12d
1:  cmp     r12d, [rip+up_no]
    jae     9f
    lea     rax, [rip+up_obj]
    cmp     [rax+r12*8+4], ebx
    jne     2f
    mov     edi, [rax+r12*8]
    call    obj_get
    test    rax, rax
    jz      2f
    or      dword ptr [rax+OB_FLAGS], OBF_SELECTED
2:  inc     r12d
    jmp     1b
9:  imul    rax, rbx, PB_SZ
    lea     rcx, [rip+up_b]
    mov     eax, [rcx+rax+PB_FIRST]
    mov     [rip+active_obj], eax
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# up_f(xmm0=double) - " x" (6 decimals) into the text being made
up_f:
    sub     rsp, 8
    cvtsd2ss xmm0, xmm0
    movss   [rsp], xmm0
    call    wb_float
    add     rsp, 8
    ret

# up_name(edi=object handle) - its name into the text
up_name:
    sub     rsp, 8
    call    obj_get
    test    rax, rax
    jz      9f
    lea     rsi, [rax+OB_NAME]
    call    wb_str
9:  add     rsp, 8
    ret

# usdphys_finish - the bodies and joints of the import made
usdphys_finish:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 64
    xorpd   xmm2, xmm2                  # the heaviest part (mass / parts)
    xor     ebx, ebx
1:  cmp     ebx, [rip+up_nb]
    jae     2f
    imul    r12, rbx, PB_SZ
    lea     rax, [rip+up_b]
    add     r12, rax
    inc     ebx
    cmp     dword ptr [r12+PB_NOBJ], 0
    je      1b
    movsd   xmm0, [r12+PB_MASS]
    cvtsi2sd xmm1, dword ptr [r12+PB_NOBJ]
    divsd   xmm0, xmm1
    maxsd   xmm2, xmm0
    jmp     1b
2:  mulsd   xmm2, [rip+d_ratio]
    movsd   [rsp+8], xmm2               # the lightest a part may be
    xor     ebx, ebx
.Lpf_body:
    cmp     ebx, [rip+up_nb]
    jae     .Lpf_joints
    imul    r12, rbx, PB_SZ
    lea     rax, [rip+up_b]
    add     r12, rax
    cmp     dword ptr [r12+PB_NOBJ], 0
    je      .Lpf_nextb
    call    wb_reset                    # "active compound mass m friction f bounce b"
    lea     rsi, [rip+s_active]
    cmp     dword ptr [r12+PB_PASS], 0
    je      1f
    lea     rsi, [rip+s_passive]
1:  call    wb_str
    mov     eax, [r12+PB_SHAPE]
    lea     rcx, [rip+s_shapes]
    mov     rsi, [rcx+rax*8]
    call    wb_str
    movsd   xmm0, [r12+PB_MASS]         # (shared by its parts)
    xorpd   xmm1, xmm1
    comisd  xmm0, xmm1
    jbe     2f
    cvtsi2sd xmm1, dword ptr [r12+PB_NOBJ]
    divsd   xmm0, xmm1
    maxsd   xmm0, [rsp+8]
    movsd   [rsp], xmm0
    lea     rsi, [rip+s_k_mass]
    call    wb_str
    movsd   xmm0, [rsp]
    call    up_f
2:  mov     rax, [r12+PB_PMAT]          # its physics material
    test    rax, rax
    jz      4f
    mov     rdi, rax
    call    up_primof
    test    eax, eax
    js      4f
    mov     r13d, eax
    mov     edi, r13d
    lea     rsi, [rip+a_dfric]
    call    up_attr
    call    up_isdbl
    test    eax, eax
    jz      3f
    movsd   [rsp], xmm0
    lea     rsi, [rip+s_k_fric]
    call    wb_str
    movsd   xmm0, [rsp]
    call    up_f
3:  mov     edi, r13d
    lea     rsi, [rip+a_rest]
    call    up_attr
    call    up_isdbl
    test    eax, eax
    jz      4f
    movsd   [rsp], xmm0
    lea     rsi, [rip+s_k_bounce]
    call    wb_str
    movsd   xmm0, [rsp]
    call    up_f
4:  cmp     dword ptr [rip+up_nb], 1    # (several bodies: a group)
    jbe     41f
    lea     rsi, [rip+s_k_group]
    call    wb_str
    mov     edi, [rip+up_group]
    call    wb_int
    lea     rsi, [rip+s_k_coll]
    call    wb_str
    mov     ecx, [rip+up_group]
    mov     edi, 1
    shl     edi, cl
    not     edi
    and     edi, 0xffff
    call    wb_int
41: xor     edi, edi
    call    wb_char
    mov     edi, ebx
    call    up_select
    mov     rsi, [rip+wb_ptr]           # (copied: rigid.add may write too)
    lea     rdi, [rip+up_txt]
    mov     rcx, [rip+wb_len]
    cmp     rcx, 500
    ja      .Lpf_nextb
    rep     movsb
    lea     rdi, [rip+s_rbadd]
    lea     rsi, [rip+up_txt]
    call    up_run
    inc     dword ptr [rip+usd_nbodies]
    # its other parts: fixed to the first
    xor     r13d, r13d
5:  cmp     r13d, [rip+up_no]
    jae     .Lpf_nextb
    lea     rax, [rip+up_obj]
    cmp     [rax+r13*8+4], ebx
    jne     6f
    mov     r14d, [rax+r13*8]
    cmp     r14d, [r12+PB_FIRST]
    je      6f
    call    wb_reset
    lea     rsi, [rip+s_jfixed]
    call    wb_str
    mov     edi, ' '
    call    wb_char
    mov     edi, r14d
    call    up_name
    mov     edi, ' '
    call    wb_char
    mov     edi, [r12+PB_FIRST]
    call    up_name
    xor     edi, edi
    call    wb_char
    call    up_wb_run_joint
6:  inc     r13d
    jmp     5b
.Lpf_nextb:
    inc     ebx
    jmp     .Lpf_body
.Lpf_joints:
    xor     ebx, ebx
.Lpf_joint:
    cmp     ebx, [rip+up_nj]
    jae     .Lpf_out
    lea     rax, [rip+up_j]
    mov     edi, [rax+rbx*4]
    call    up_joint
    inc     ebx
    jmp     .Lpf_joint
.Lpf_out:
    call    select_none
    add     rsp, 64
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# up_wb_run_joint - the text made (wb) run as rigid.joint
up_wb_run_joint:
    sub     rsp, 8
    mov     rsi, [rip+wb_ptr]
    lea     rdi, [rip+up_txt]
    mov     rcx, [rip+wb_len]
    cmp     rcx, 500
    ja      9f
    rep     movsb
    lea     rdi, [rip+s_rbjoint]
    lea     rsi, [rip+up_txt]
    call    up_run
9:  add     rsp, 8
    ret

# up_primof(rdi=stage path) -> eax = the composed prim, -1
up_primof:
    push    rbx
    mov     rsi, rdi
    mov     rdi, [rip+us_st]
    call    ul_find
    test    eax, eax
    js      9f
    mov     ebx, eax
    mov     edi, eax
    call    us_done
    test    eax, eax
    jz      8f
    mov     eax, ebx
    jmp     9f
8:  mov     eax, -1
9:  pop     rbx
    ret

# up_bodyof(edi=prim of a joint, rsi=rel name) -> eax = the body its target
#   is (or is inside: the nearest body above), -1 the world
up_bodyof:
    push    rbx
    push    r12
    sub     rsp, 8
    call    us_rel
    test    rax, rax
    jz      8f
    mov     rbx, rax
    xor     r12d, r12d                  # the body whose prim's path is it, or
1:  cmp     r12d, [rip+up_nb]           #  a prefix of it
    jae     8f
    imul    rax, r12, PB_SZ
    lea     rcx, [rip+up_b]
    mov     edi, [rcx+rax+PB_PRIM]
    call    us_prim_path
    mov     rdi, rbx
    mov     rsi, rax
    call    up_under
    test    eax, eax
    jnz     7f
    inc     r12d
    jmp     1b
7:  imul    rax, r12, PB_SZ             # (a body without objects: the world)
    lea     rcx, [rip+up_b]
    cmp     dword ptr [rcx+rax+PB_NOBJ], 0
    je      8f
    mov     eax, r12d
    jmp     9f
8:  mov     eax, -1
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# up_under(rdi=path, rsi=root) -> eax = 1 when path is root or below it
up_under:
    xor     ecx, ecx
1:  mov     al, [rsi+rcx]
    test    al, al
    jz      2f
    cmp     al, [rdi+rcx]
    jne     8f
    inc     ecx
    jmp     1b
2:  mov     al, [rdi+rcx]
    test    al, al
    jz      7f
    cmp     al, '/'
    jne     8f
7:  mov     eax, 1
    ret
8:  xor     eax, eax
    ret

# up_joint(edi=joint prim) - rigid.joint <type> <a> <b|world> pivot .. axis
#   .. [limits ..]
up_joint:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 192
    mov     ebx, edi
    lea     rsi, [rip+a_jen]            # disabled: out
    call    up_attr
    test    rax, rax
    jz      1f
    cmp     dword ptr [rax+UV_T], UT_INT
    jne     1f
    cmp     qword ptr [rax+UV_D], 0
    je      .Lpj_out
1:  mov     edi, ebx
    call    up_jointkind
    test    eax, eax
    js      .Lpj_out
    mov     r12d, eax                   # kind
    mov     edi, ebx
    lea     rsi, [rip+r_body0]
    call    up_bodyof
    mov     r13d, eax
    mov     edi, ebx
    lea     rsi, [rip+r_body1]
    call    up_bodyof
    mov     r14d, eax
    test    r13d, r13d                  # (body0 the world: body1 alone)
    jns     2f
    mov     r13d, r14d
    mov     r14d, -1
2:  test    r13d, r13d
    js      .Lpj_out
    cmp     r13d, r14d
    je      .Lpj_out
    # the pivot and axis in the stage: body0's matrix x localPos0 / localRot0
    imul    r15, r13, PB_SZ
    lea     rax, [rip+up_b]
    add     r15, rax
    xorpd   xmm0, xmm0                  # localPos0 (0 0 0)
    movsd   [rsp], xmm0
    movsd   [rsp+8], xmm0
    movsd   [rsp+16], xmm0
    mov     edi, ebx
    lea     rsi, [rip+a_lpos0]
    call    up_attr
    test    rax, rax
    jz      3f
    cmp     dword ptr [rax+UV_T], UT_VEC
    jne     3f
    cmp     qword ptr [rax+UV_N], 3
    jb      3f
    mov     rcx, [rax+UV_P]
    movups  xmm0, [rcx]
    movups  [rsp], xmm0
    movsd   xmm0, [rcx+16]
    movsd   [rsp+16], xmm0
3:  lea     rdi, [rsp+32]               # the pivot: W p, then C
    lea     rsi, [r15+PB_W]
    lea     rdx, [rsp]
    mov     ecx, 1
    call    up_xvec
    lea     rdi, [rsp+64]
    lea     rsi, [rip+us_cm]
    lea     rdx, [rsp+32]
    mov     ecx, 1
    call    up_xvec
    xor     ecx, ecx                    # (and where the asset lands)
31: movsd   xmm0, [rsp+64+rcx*8]
    lea     rax, [rip+us_off]
    addsd   xmm0, [rax+rcx*8]
    movsd   [rsp+64+rcx*8], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      31b
    mov     edi, ebx                    # the axis: e_axis through localRot0
    call    up_axis                     #  -> [rsp+..] doubles at rdi
    lea     rdi, [rsp+96]
    call    up_jaxis
    lea     rdi, [rsp+128]              # then W's rotation, then C's
    lea     rsi, [r15+PB_W]
    lea     rdx, [rsp+96]
    xor     ecx, ecx
    call    up_xvec
    lea     rdi, [rsp+96]
    lea     rsi, [rip+us_cm]
    lea     rdx, [rsp+128]
    xor     ecx, ecx
    call    up_xvec
    lea     rdi, [rsp+96]               # (unit length)
    call    up_unit
    call    wb_reset                    # the text: body1 first (BeeModel
    lea     rax, [rip+s_jtypes]         #  measures the first from the
    mov     rsi, [rax+r12*8]            #  second, USD body1 from body0)
    call    wb_str
    mov     edi, ' '
    call    wb_char
    test    r14d, r14d
    js      4f
    imul    rax, r14, PB_SZ
    lea     rcx, [rip+up_b]
    mov     edi, [rcx+rax+PB_FIRST]
    call    up_name
    mov     edi, ' '
    call    wb_char
    imul    rax, r13, PB_SZ
    lea     rcx, [rip+up_b]
    mov     edi, [rcx+rax+PB_FIRST]
    call    up_name
    jmp     5f
4:  imul    rax, r13, PB_SZ             # (one body: it, to the world)
    lea     rcx, [rip+up_b]
    mov     edi, [rcx+rax+PB_FIRST]
    call    up_name
    mov     edi, ' '
    call    wb_char
    lea     rsi, [rip+s_world]
    call    wb_str
5:  lea     rsi, [rip+s_k_pivot]
    call    wb_str
    lea     rdi, [rsp+64]
    call    up_vec3
    cmp     r12d, 2                     # (fixed and point: no axis)
    jae     7f
    lea     rsi, [rip+s_k_axis]
    call    wb_str
    lea     rdi, [rsp+96]
    call    up_vec3
    mov     edi, ebx                    # a drive: held where it is (as a
    lea     rsi, [rip+v_drivel]         #  stiff drive holds it): limits 0 0
    call    up_has_api
    test    eax, eax
    jnz     65f
    mov     edi, ebx
    lea     rsi, [rip+v_drivea]
    call    up_has_api
    test    eax, eax
    jnz     65f
    mov     edi, ebx                    # limits, when both are finite
    lea     rsi, [rip+a_lower]
    call    up_attr
    call    up_isdbl
    test    eax, eax
    jz      7f
    movsd   [rsp+160], xmm0
    mov     edi, ebx
    lea     rsi, [rip+a_upper]
    call    up_attr
    call    up_isdbl
    test    eax, eax
    jz      7f
    movsd   [rsp+168], xmm0
    movsd   xmm0, [rsp+160]
    andpd   xmm0, [rip+up_abs]
    comisd  xmm0, [rip+d_lim]
    jae     7f
    movsd   xmm0, [rsp+168]
    andpd   xmm0, [rip+up_abs]
    comisd  xmm0, [rip+d_lim]
    jae     7f
    cmp     r12d, 1                     # a slider's: stage units to metres
    jne     6f
    movsd   xmm1, [rip+us_cm]           # (C's scale: its first row's x)
    andpd   xmm1, [rip+up_abs]
    movsd   xmm0, [rsp+160]
    mulsd   xmm0, xmm1
    movsd   [rsp+160], xmm0
    movsd   xmm0, [rsp+168]
    mulsd   xmm0, xmm1
    movsd   [rsp+168], xmm0
    jmp     6f
65: xorpd   xmm0, xmm0
    movsd   [rsp+160], xmm0
    movsd   [rsp+168], xmm0
6:  lea     rsi, [rip+s_k_lim]
    call    wb_str
    movsd   xmm0, [rsp+160]
    call    up_f
    mov     edi, ' '
    call    wb_char
    movsd   xmm0, [rsp+168]
    call    up_f
7:  xor     edi, edi
    call    wb_char
    call    up_wb_run_joint
    inc     dword ptr [rip+usd_njoints]
.Lpj_out:
    add     rsp, 192
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# up_unit(rdi=3 doubles) - made unit length (left when ~0)
up_unit:
    movsd   xmm0, [rdi]
    mulsd   xmm0, xmm0
    movsd   xmm1, [rdi+8]
    mulsd   xmm1, xmm1
    addsd   xmm0, xmm1
    movsd   xmm1, [rdi+16]
    mulsd   xmm1, xmm1
    addsd   xmm0, xmm1
    sqrtsd  xmm0, xmm0
    xorpd   xmm1, xmm1
    comisd  xmm0, xmm1
    jbe     9f
    movsd   xmm1, [rip+d_deg]
    divsd   xmm1, xmm0
    xor     ecx, ecx
1:  movsd   xmm0, [rdi+rcx*8]
    mulsd   xmm0, xmm1
    movsd   [rdi+rcx*8], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      1b
9:  ret

# up_vec3(rdi=3 doubles) - "x y z" into the text
up_vec3:
    push    rbx
    mov     rbx, rdi
    movsd   xmm0, [rbx]
    call    up_f
    mov     edi, ' '
    call    wb_char
    movsd   xmm0, [rbx+8]
    call    up_f
    mov     edi, ' '
    call    wb_char
    movsd   xmm0, [rbx+16]
    call    up_f
    pop     rbx
    ret

# up_xvec(rdi=out 3 doubles, rsi=matrix (16 doubles, row-major), rdx=in 3
#   doubles, ecx=1: a point (translated), 0: a direction)
up_xvec:
    xor     r8d, r8d
1:  lea     eax, [r8*4]
    movsd   xmm0, [rsi+rax*8]
    mulsd   xmm0, [rdx]
    movsd   xmm1, [rsi+rax*8+8]
    mulsd   xmm1, [rdx+8]
    addsd   xmm0, xmm1
    movsd   xmm1, [rsi+rax*8+16]
    mulsd   xmm1, [rdx+16]
    addsd   xmm0, xmm1
    test    ecx, ecx
    jz      2f
    addsd   xmm0, [rsi+rax*8+24]
2:  movsd   [rdi+r8*8], xmm0
    inc     r8d
    cmp     r8d, 3
    jb      1b
    ret

.section .bss
.align 8
up_ax:      .skip 32                    # the joint's axis (in its frame)
up_q:       .skip 32                    # localRot0 (x y z w)
.text

# up_axis(edi=joint) - up_ax: its axis token X / Y / Z (else X) as a vector;
#   up_q: localRot0 (else none)
up_axis:
    push    rbx
    mov     ebx, edi
    xorpd   xmm0, xmm0
    movsd   [rip+up_ax], xmm0
    movsd   [rip+up_ax+8], xmm0
    movsd   [rip+up_ax+16], xmm0
    mov     eax, 0                      # (X)
    push    rax
    mov     edi, ebx
    lea     rsi, [rip+a_axis]
    call    up_attr
    pop     rcx
    test    rax, rax
    jz      1f
    cmp     dword ptr [rax+UV_T], UT_STR
    jne     1f
    mov     rdx, [rax+UV_P]
    movzx   ecx, byte ptr [rdx]
    sub     ecx, 'X'
    cmp     ecx, 2
    jbe     1f
    xor     ecx, ecx
1:  movsd   xmm0, [rip+d_deg]           # (1.0)
    lea     rax, [rip+up_ax]
    movsd   [rax+rcx*8], xmm0
    xorpd   xmm0, xmm0                  # localRot0: identity unless given
    movsd   [rip+up_q], xmm0
    movsd   [rip+up_q+8], xmm0
    movsd   [rip+up_q+16], xmm0
    movsd   xmm0, [rip+d_deg]
    movsd   [rip+up_q+24], xmm0
    mov     edi, ebx
    lea     rsi, [rip+a_lrot0]
    call    up_attr
    test    rax, rax
    jz      9f
    cmp     dword ptr [rax+UV_T], UT_VEC
    jne     9f
    cmp     qword ptr [rax+UV_N], 4
    jb      9f
    mov     rcx, [rax+UV_P]
    movups  xmm0, [rcx]
    movups  [rip+up_q], xmm0
    movups  xmm0, [rcx+16]
    movups  [rip+up_q+16], xmm0
9:  pop     rbx
    ret

# up_jaxis(rdi=out 3 doubles) - up_ax turned by up_q: v + 2w (q x v) +
#   2 q x (q x v)
up_jaxis:
    movsd   xmm0, [rip+up_q]            # q (x y z), w
    movsd   xmm1, [rip+up_q+8]
    movsd   xmm2, [rip+up_q+16]
    movsd   xmm3, [rip+up_q+24]
    movsd   xmm4, [rip+up_ax]           # v
    movsd   xmm5, [rip+up_ax+8]
    movsd   xmm6, [rip+up_ax+16]
    sub     rsp, 56
    # t = q x v
    movsd   xmm7, xmm1                  # tx = qy vz - qz vy
    mulsd   xmm7, xmm6
    movsd   xmm8, xmm2
    mulsd   xmm8, xmm5
    subsd   xmm7, xmm8
    movsd   [rsp], xmm7
    movsd   xmm7, xmm2                  # ty = qz vx - qx vz
    mulsd   xmm7, xmm4
    movsd   xmm8, xmm0
    mulsd   xmm8, xmm6
    subsd   xmm7, xmm8
    movsd   [rsp+8], xmm7
    movsd   xmm7, xmm0                  # tz = qx vy - qy vx
    mulsd   xmm7, xmm5
    movsd   xmm8, xmm1
    mulsd   xmm8, xmm4
    subsd   xmm7, xmm8
    movsd   [rsp+16], xmm7
    # u = q x t
    movsd   xmm7, xmm1
    mulsd   xmm7, [rsp+16]
    movsd   xmm8, xmm2
    mulsd   xmm8, [rsp+8]
    subsd   xmm7, xmm8
    movsd   [rsp+24], xmm7
    movsd   xmm7, xmm2
    mulsd   xmm7, [rsp]
    movsd   xmm8, xmm0
    mulsd   xmm8, [rsp+16]
    subsd   xmm7, xmm8
    movsd   [rsp+32], xmm7
    movsd   xmm7, xmm0
    mulsd   xmm7, [rsp+8]
    movsd   xmm8, xmm1
    mulsd   xmm8, [rsp]
    subsd   xmm7, xmm8
    movsd   [rsp+40], xmm7
    # out = v + 2 w t + 2 u
    xor     ecx, ecx
1:  movsd   xmm7, [rsp+rcx*8]
    mulsd   xmm7, xmm3
    addsd   xmm7, [rsp+24+rcx*8]
    addsd   xmm7, xmm7
    lea     rax, [rip+up_ax]
    addsd   xmm7, [rax+rcx*8]
    movsd   [rdi+rcx*8], xmm7
    inc     ecx
    cmp     ecx, 3
    jb      1b
    add     rsp, 56
    ret

.section .rodata
.align 16
up_abs:     .quad 0x7fffffffffffffff, 0x7fffffffffffffff

.section .note.GNU-stack,"",@progbits
