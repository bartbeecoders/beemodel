# =============================================================================
#  BeeModel - the pivot point and the transform orientation (the 3D
#  viewport's header, view.pivot / view.orientation), and the 3x3 rotation
#  helpers transforms use with them.
#
#  Both are chosen from the header's pivot button (a menu with check
#  marks) or view.pivot / view.orientation.
#  Pivot: Median Point (the selection's middle), 3D Cursor, Individual
#  Origins (objects turn and scale about their own origins), Active Object.
#  Orientation: the axes X / Y / Z mean when a move or turn is constrained -
#  Global (the world's), Local (the active object's), View (screen right,
#  up, towards you), Normal (edit mode: the selected faces' normal; objects:
#  local). tm_basis holds the three axis vectors for the transform running.
#  Matrices are float[9], row-major; an object's R = Rz * Ry * Rx.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"
.include "widgets.inc"

.globl tm_pvmode
.globl tm_orient
.globl tm_basis
.globl orient_setup
.globl pivot_fix
.globl o_euler_mat
.globl o_mat_euler
.globl o_axis_mat
.globl o_mul
.globl o_mulv
.globl xf_list
.globl xf_list_cnt

.section .data
.align 4
tm_pvmode:      .long 0                 # 0 median, 1 cursor, 2 individual, 3 active
tm_orient:      .long 0                 # 0 global, 1 local, 2 view, 3 normal
.section .bss
.align 16
tm_basis:       .skip 36                # the X, Y, Z axis vectors in use
o_tmp:          .skip 64

.section .rodata
.align 4
o_one:          .float 1.0
s_w_median:     .asciz "median"
s_w_cursor:     .asciz "cursor"
s_w_indiv:      .asciz "individual"
s_w_active:     .asciz "active"
s_w_global:     .asciz "global"
s_w_local:      .asciz "local"
s_w_view:       .asciz "view"
s_w_normal:     .asciz "normal"
.align 8
xf_list:        .quad op_pv_med, op_pv_cur, op_pv_ind, op_pv_act, 0
                .quad op_or_glob, op_or_loc, op_or_view, op_or_nrm
.equ xf_list_n, (. - xf_list) / 8
.align 4
xf_list_cnt:    .long xf_list_n
pivot_kw:       .quad s_w_median, s_w_cursor, s_w_indiv, s_w_active, 0
orient_kw:      .quad s_w_global, s_w_local, s_w_view, s_w_normal, 0

.text
OPERATOR op_pivot, "view.pivot", "Pivot Point", do_pivot, flags=OPF_AI_SAFE|OPF_QUIET, doc="What turning and scaling go around: view.pivot median|cursor|individual|active"
OPERATOR op_orient, "view.orientation", "Transform Orientation", do_orient, flags=OPF_AI_SAFE|OPF_QUIET, doc="What X, Y and Z mean while moving or turning: view.orientation global|local|view|normal"
OPERATOR op_pv_med, "view.pivot_median", "Median Point", o_set_pv, check=o_chk_pv, arg=0, flags=OPF_HIDDEN|OPF_QUIET, doc="Turn and scale around the middle of the selection"
OPERATOR op_pv_cur, "view.pivot_cursor", "3D Cursor", o_set_pv, check=o_chk_pv, arg=1, flags=OPF_HIDDEN|OPF_QUIET, doc="Turn and scale around the 3D cursor"
OPERATOR op_pv_ind, "view.pivot_individual", "Individual Origins", o_set_pv, check=o_chk_pv, arg=2, flags=OPF_HIDDEN|OPF_QUIET, doc="Each object turns and scales around its own origin"
OPERATOR op_pv_act, "view.pivot_active", "Active Object", o_set_pv, check=o_chk_pv, arg=3, flags=OPF_HIDDEN|OPF_QUIET, doc="Turn and scale around the active object's origin"
OPERATOR op_or_glob, "view.orientation_global", "Global", o_set_or, check=o_chk_or, arg=0, flags=OPF_HIDDEN|OPF_QUIET, doc="X, Y and Z are the world's axes"
OPERATOR op_or_loc, "view.orientation_local", "Local", o_set_or, check=o_chk_or, arg=1, flags=OPF_HIDDEN|OPF_QUIET, doc="X, Y and Z are the active object's own axes"
OPERATOR op_or_view, "view.orientation_view", "View", o_set_or, check=o_chk_or, arg=2, flags=OPF_HIDDEN|OPF_QUIET, doc="X is screen right, Y screen up, Z towards you"
OPERATOR op_or_nrm, "view.orientation_normal", "Normal", o_set_or, check=o_chk_or, arg=3, flags=OPF_HIDDEN|OPF_QUIET, doc="Edit mode: Z is the selected faces' normal (objects: their own axes)"

o_set_pv:
    mov     [rip+tm_pvmode], edi
    mov     dword ptr [rip+dirty], 1
    ret
o_chk_pv:
    xor     eax, eax
    cmp     edi, [rip+tm_pvmode]
    sete    al
    ret
o_set_or:
    mov     [rip+tm_orient], edi
    mov     dword ptr [rip+dirty], 1
    ret
o_chk_or:
    xor     eax, eax
    cmp     edi, [rip+tm_orient]
    sete    al
    ret

# kw_index(rdi=0-ended list of words) -> eax = the argument's index, -1
kw_index:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    mov     rsi, [rip+op_arg]
    call    im_next_word
    xor     r12d, r12d
1:  mov     rsi, [rbx+r12*8]
    test    rsi, rsi
    jz      8f
    lea     rdi, [rip+im_word]
    call    str_eq
    test    eax, eax
    jnz     9f
    inc     r12d
    jmp     1b
8:  mov     r12d, -1
9:  mov     eax, r12d
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

do_pivot:
    sub     rsp, 8
    lea     rdi, [rip+pivot_kw]
    call    kw_index
    test    eax, eax
    js      9f
    mov     [rip+tm_pvmode], eax
    mov     dword ptr [rip+dirty], 1
9:  add     rsp, 8
    ret

do_orient:
    sub     rsp, 8
    lea     rdi, [rip+orient_kw]
    call    kw_index
    test    eax, eax
    js      9f
    mov     [rip+tm_orient], eax
    mov     dword ptr [rip+dirty], 1
9:  add     rsp, 8
    ret

# pivot_fix(rdi=float[3] the median, already there) - the pivot chosen:
#   the 3D cursor, or the active object's origin (Individual: the median,
#   each object uses its own)
pivot_fix:
    mov     eax, [rip+tm_pvmode]
    cmp     eax, 1
    jne     1f
    mov     rax, [rip+cursor_pos]
    mov     [rdi], rax
    mov     eax, [rip+cursor_pos+8]
    mov     [rdi+8], eax
    ret
1:  cmp     eax, 3
    jne     9f
    cmp     dword ptr [rip+edit_obj], 0 # (edit mode: the median)
    jne     9f
    push    rdi
    mov     edi, [rip+active_obj]
    call    obj_get
    pop     rdi
    test    rax, rax
    jz      9f
    mov     rcx, [rax+OB_LOC]
    mov     [rdi], rcx
    mov     ecx, [rax+OB_LOC+8]
    mov     [rdi+8], ecx
9:  ret

# orient_setup - tm_basis for the orientation chosen
orient_setup:
    push    rbx
    sub     rsp, 64
    lea     rdi, [rip+tm_basis]         # global: the identity
    xor     eax, eax
    mov     ecx, 9
    rep     stosd
    mov     eax, [rip+o_one]
    mov     [rip+tm_basis], eax
    mov     [rip+tm_basis+16], eax
    mov     [rip+tm_basis+32], eax
    mov     eax, [rip+tm_orient]
    cmp     eax, 2
    je      .Los_view
    cmp     eax, 3
    jne     1f
    cmp     dword ptr [rip+edit_obj], 0
    jne     .Los_normal
    jmp     .Los_local                  # (objects: normal = local)
1:  cmp     eax, 1
    jne     9f
.Los_local:                             # the active object's axes
    mov     edi, [rip+edit_obj]
    test    edi, edi
    jnz     2f
    mov     edi, [rip+active_obj]
2:  call    obj_get
    test    rax, rax
    jz      9f
    mov     rdi, rax
    lea     rsi, [rsp]
    call    obj_matrix                  # row-major 3x4: axis k = column k
    xor     ebx, ebx
3:  lea     rdx, [rip+tm_basis]
    lea     rcx, [rbx+rbx*2]
    lea     rdx, [rdx+rcx*4]
    movss   xmm0, [rsp+rbx*4]
    movss   [rdx], xmm0
    movss   xmm0, [rsp+16+rbx*4]
    movss   [rdx+4], xmm0
    movss   xmm0, [rsp+32+rbx*4]
    movss   [rdx+8], xmm0
    mov     rdi, rdx
    call    normalize
    inc     ebx
    cmp     ebx, 3
    jb      3b
    jmp     9f
.Los_view:                              # right, up, towards the viewer
    lea     rdx, [rip+tm_basis]
    mov     rax, [rip+right]
    mov     [rdx], rax
    mov     eax, [rip+right+8]
    mov     [rdx+8], eax
    mov     rax, [rip+up]
    mov     [rdx+12], rax
    mov     eax, [rip+up+8]
    mov     [rdx+20], eax
    xor     ecx, ecx
4:  lea     rax, [rip+fwd]
    movss   xmm0, [rax+rcx*4]
    xorps   xmm0, [rip+o_neg]
    movss   [rdx+24+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      4b
    jmp     9f
.Los_normal:                            # Z: the selected faces' normal
    call    sel_normal
    test    eax, eax
    jz      9f
    lea     rdi, [rip+tm_basis+24]
    mov     rax, [rip+nrm]
    mov     [rdi], rax
    mov     eax, [rip+nrm+8]
    mov     [rdi+8], eax
    call    world_dir
    lea     rsi, [rip+tm_basis+24]      # X: Z x world up (or x world X), Y: Z x X
    xorps   xmm0, xmm0                  # tmp = (0,1,0), or (1,0,0) near vertical
    movss   [rip+o_tmp], xmm0
    movss   xmm1, [rip+o_one]
    movss   [rip+o_tmp+4], xmm1
    movss   [rip+o_tmp+8], xmm0
    movss   xmm2, [rsi+4]
    andps   xmm2, [rip+o_abs]
    comiss  xmm2, [rip+o_vert]
    jb      5f
    movss   [rip+o_tmp], xmm1
    movss   [rip+o_tmp+4], xmm0
5:  lea     rdi, [rip+o_tmp]            # X = up x Z
    lea     rsi, [rip+tm_basis+24]
    lea     rdx, [rip+tm_basis]
    call    o_cross
    lea     rdi, [rip+tm_basis]
    call    normalize
    lea     rdi, [rip+tm_basis+24]      # Y = Z x X
    lea     rsi, [rip+tm_basis]
    lea     rdx, [rip+tm_basis+12]
    call    o_cross
9:  add     rsp, 64
    pop     rbx
    ret

# o_cross(rdi=a, rsi=b, rdx=out) - a x b
o_cross:
    movss   xmm0, [rdi+4]
    mulss   xmm0, [rsi+8]
    movss   xmm1, [rdi+8]
    mulss   xmm1, [rsi+4]
    subss   xmm0, xmm1
    movss   xmm2, [rdi+8]
    mulss   xmm2, [rsi]
    movss   xmm1, [rdi]
    mulss   xmm1, [rsi+8]
    subss   xmm2, xmm1
    movss   xmm3, [rdi]
    mulss   xmm3, [rsi+4]
    movss   xmm1, [rdi+4]
    mulss   xmm1, [rsi]
    subss   xmm3, xmm1
    movss   [rdx], xmm0
    movss   [rdx+4], xmm2
    movss   [rdx+8], xmm3
    ret

# sel_normal -> eax = 1 with nrm = the sum of the normals of the edit mesh's
#   faces whose vertices are all selected (local space)
sel_normal:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 16
    xorps   xmm0, xmm0
    movups  [rsp], xmm0
    call    edit_get
    test    rax, rax
    jz      8f
    mov     rbx, [rax+OB_MESH]
    test    rbx, rbx
    jz      8f
    xor     r12d, r12d                  # polygon
    xor     r13d, r13d                  # how many
1:  cmp     r12d, [rbx+ME_NPOLYS]
    jae     5f
    mov     r8, [rbx+ME_POFF]
    mov     ecx, [r8+r12*4]
    mov     edx, [r8+r12*4+4]
    mov     r9, [rbx+ME_LOOPS]
    mov     r10, [rbx+ME_VSEL]
    test    r10, r10
    jz      5f
2:  cmp     ecx, edx
    jae     3f
    mov     eax, [r9+rcx*4]
    cmp     byte ptr [r10+rax], 0
    je      4f
    inc     ecx
    jmp     2b
3:  mov     rdi, rbx
    mov     esi, r12d
    call    poly_normal
    movups  xmm0, [rsp]
    movss   xmm1, [rip+nrm]
    movss   xmm2, [rip+nrm+4]
    movss   xmm3, [rip+nrm+8]
    unpcklps xmm1, xmm2
    movlhps xmm1, xmm3
    addps   xmm0, xmm1
    movups  [rsp], xmm0
    inc     r13d
4:  inc     r12d
    jmp     1b
5:  test    r13d, r13d
    jz      8f
    mov     rax, [rsp]
    mov     [rip+nrm], rax
    mov     eax, [rsp+8]
    mov     [rip+nrm+8], eax
    lea     rdi, [rip+nrm]
    call    normalize
    mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 16
    pop     r13
    pop     r12
    pop     rbx
    ret

# o_euler_mat(rdi=float[3] X Y Z angles, rsi=out float[9]) - Rz * Ry * Rx
o_euler_mat:
    push    rbx
    sub     rsp, 32
    mov     rbx, rsi
    xor     ecx, ecx                    # sin at [rsp+8k], cos at [rsp+8k+4]
1:  fld     dword ptr [rdi+rcx*4]
    fsincos
    fstp    dword ptr [rsp+rcx*8+4]
    fstp    dword ptr [rsp+rcx*8]
    inc     ecx
    cmp     ecx, 3
    jb      1b
    # sx [rsp] cx [rsp+4] sy [rsp+8] cy [rsp+12] sz [rsp+16] cz [rsp+20]
    movss   xmm0, [rsp+12]              # R00 = cy cz
    mulss   xmm0, [rsp+20]
    movss   [rbx], xmm0
    movss   xmm0, [rsp]                 # R01 = sx sy cz - cx sz
    mulss   xmm0, [rsp+8]
    mulss   xmm0, [rsp+20]
    movss   xmm1, [rsp+4]
    mulss   xmm1, [rsp+16]
    subss   xmm0, xmm1
    movss   [rbx+4], xmm0
    movss   xmm0, [rsp+4]               # R02 = cx sy cz + sx sz
    mulss   xmm0, [rsp+8]
    mulss   xmm0, [rsp+20]
    movss   xmm1, [rsp]
    mulss   xmm1, [rsp+16]
    addss   xmm0, xmm1
    movss   [rbx+8], xmm0
    movss   xmm0, [rsp+12]              # R10 = cy sz
    mulss   xmm0, [rsp+16]
    movss   [rbx+12], xmm0
    movss   xmm0, [rsp]                 # R11 = sx sy sz + cx cz
    mulss   xmm0, [rsp+8]
    mulss   xmm0, [rsp+16]
    movss   xmm1, [rsp+4]
    mulss   xmm1, [rsp+20]
    addss   xmm0, xmm1
    movss   [rbx+16], xmm0
    movss   xmm0, [rsp+4]               # R12 = cx sy sz - sx cz
    mulss   xmm0, [rsp+8]
    mulss   xmm0, [rsp+16]
    movss   xmm1, [rsp]
    mulss   xmm1, [rsp+20]
    subss   xmm0, xmm1
    movss   [rbx+20], xmm0
    movss   xmm0, [rsp+8]               # R20 = -sy
    xorps   xmm0, [rip+o_neg]
    movss   [rbx+24], xmm0
    movss   xmm0, [rsp]                 # R21 = sx cy
    mulss   xmm0, [rsp+12]
    movss   [rbx+28], xmm0
    movss   xmm0, [rsp+4]               # R22 = cx cy
    mulss   xmm0, [rsp+12]
    movss   [rbx+32], xmm0
    add     rsp, 32
    pop     rbx
    ret

# o_mat_euler(rdi=float[9], rsi=out float[3]) - the X Y Z angles of R
o_mat_euler:
    sub     rsp, 8
    fld     dword ptr [rdi+24]          # y = atan2(-R20, sqrt(R00^2 + R10^2))
    fchs
    fld     dword ptr [rdi]
    fmul    st, st
    fld     dword ptr [rdi+12]
    fmul    st, st
    faddp
    fsqrt
    fpatan
    fstp    dword ptr [rsi+4]
    fld     dword ptr [rdi+28]          # x = atan2(R21, R22)
    fld     dword ptr [rdi+32]
    fpatan
    fstp    dword ptr [rsi]
    fld     dword ptr [rdi+12]          # z = atan2(R10, R00)
    fld     dword ptr [rdi]
    fpatan
    fstp    dword ptr [rsi+8]
    add     rsp, 8
    ret

# o_axis_mat(rdi=unit axis float[3], xmm0=angle, rsi=out float[9])
#   R = cos I + sin [a]x + (1 - cos) a a^T
o_axis_mat:
    push    rbx
    sub     rsp, 16
    mov     rbx, rsi
    call    sincos                      # xmm0 sin, xmm1 cos
    movss   [rsp], xmm0
    movss   [rsp+4], xmm1
    movss   xmm2, [rip+o_one]
    subss   xmm2, xmm1
    movss   [rsp+8], xmm2               # 1 - cos
    xor     ecx, ecx                    # (1 - cos) a_r a_c, then cos on the diagonal
1:  xor     edx, edx
2:  movss   xmm0, [rdi+rcx*4]
    mulss   xmm0, [rdi+rdx*4]
    mulss   xmm0, [rsp+8]
    cmp     ecx, edx
    jne     3f
    addss   xmm0, [rsp+4]
3:  lea     eax, [rcx+rcx*2]
    add     eax, edx
    movss   [rbx+rax*4], xmm0
    inc     edx
    cmp     edx, 3
    jb      2b
    inc     ecx
    cmp     ecx, 3
    jb      1b
    movss   xmm3, [rsp]                 # + sin [a]x
    movss   xmm0, [rdi+8]               # R01 -= s az, R10 += s az
    mulss   xmm0, xmm3
    movss   xmm1, [rbx+4]
    subss   xmm1, xmm0
    movss   [rbx+4], xmm1
    movss   xmm1, [rbx+12]
    addss   xmm1, xmm0
    movss   [rbx+12], xmm1
    movss   xmm0, [rdi+4]               # R02 += s ay, R20 -= s ay
    mulss   xmm0, xmm3
    movss   xmm1, [rbx+8]
    addss   xmm1, xmm0
    movss   [rbx+8], xmm1
    movss   xmm1, [rbx+24]
    subss   xmm1, xmm0
    movss   [rbx+24], xmm1
    movss   xmm0, [rdi]                 # R12 -= s ax, R21 += s ax
    mulss   xmm0, xmm3
    movss   xmm1, [rbx+20]
    subss   xmm1, xmm0
    movss   [rbx+20], xmm1
    movss   xmm1, [rbx+28]
    addss   xmm1, xmm0
    movss   [rbx+28], xmm1
    add     rsp, 16
    pop     rbx
    ret

# o_mul(rdi=a, rsi=b, rdx=out) - a * b (out may be a or b)
o_mul:
    sub     rsp, 40
    xor     ecx, ecx                    # row
1:  xor     r8d, r8d                    # column
2:  lea     eax, [rcx+rcx*2]
    movss   xmm0, [rdi+rax*4]
    mulss   xmm0, [rsi+r8*4]
    movss   xmm1, [rdi+rax*4+4]
    mulss   xmm1, [rsi+r8*4+12]
    addss   xmm0, xmm1
    movss   xmm1, [rdi+rax*4+8]
    mulss   xmm1, [rsi+r8*4+24]
    addss   xmm0, xmm1
    add     eax, r8d
    movss   [rsp+rax*4], xmm0
    inc     r8d
    cmp     r8d, 3
    jb      2b
    inc     ecx
    cmp     ecx, 3
    jb      1b
    mov     ecx, 9
    xor     eax, eax
3:  mov     r8d, [rsp+rax*4]
    mov     [rdx+rax*4], r8d
    inc     eax
    loop    3b
    add     rsp, 40
    ret

# o_mulv(rdi=m, rsi=v, rdx=out) - m * v (out may be v)
o_mulv:
    sub     rsp, 24
    xor     ecx, ecx
1:  lea     eax, [rcx+rcx*2]
    movss   xmm0, [rdi+rax*4]
    mulss   xmm0, [rsi]
    movss   xmm1, [rdi+rax*4+4]
    mulss   xmm1, [rsi+4]
    addss   xmm0, xmm1
    movss   xmm1, [rdi+rax*4+8]
    mulss   xmm1, [rsi+8]
    addss   xmm0, xmm1
    movss   [rsp+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      1b
    mov     rax, [rsp]
    mov     [rdx], rax
    mov     eax, [rsp+8]
    mov     [rdx+8], eax
    add     rsp, 24
    ret

.section .rodata
.align 16
o_neg:          .long 0x80000000, 0, 0, 0
o_abs:          .long 0x7fffffff, 0, 0, 0
o_vert:         .float 0.9

.section .note.GNU-stack,"",@progbits
