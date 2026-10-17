# =============================================================================
#  BeeModel - a light's shape in the 3D viewport: a point or spot light with
#  a radius as three circles of it, a spot's cone (to 2 m), a sun's
#  direction, an area light's square and the way it faces. From the same
#  16 floats the path tracers read (hive.s hv_light).
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

.globl light_shapes_draw

.equ SEGS, 24

.section .bss
.align 16
ls_rec:         .skip 64
ls_a:           .skip 12
ls_b:           .skip 12
ls_tmp:         .skip 16
.align 4
ls_col:         .skip 4

.section .rodata
.align 4
lf_2pi:         .float 6.28318531
lf_segs:        .float 24.0
lf_two:         .float 2.0
lf_one:         .float 1.0
lf_cone:        .float 2.0                  # a spot's cone drawn this long
lf_arrow:       .float 0.6
ax_x:           .float 1, 0, 0
ax_y:           .float 0, 1, 0
ax_z:           .float 0, 0, 1

.text
# light_shapes_draw - (viewport_draw, camera set up) every visible light's
light_shapes_draw:
    push    rbx
    push    r12
    sub     rsp, 8
    xor     ebx, ebx
1:  cmp     ebx, [rip+obj_count]
    jae     9f
    mov     edi, ebx
    call    obj_at
    inc     ebx
    cmp     dword ptr [rax+OB_TYPE], OT_LIGHT
    jne     1b
    test    dword ptr [rax+OB_FLAGS], OBF_HIDDEN
    jnz     1b
    mov     r12, rax
    mov     dword ptr [rip+ls_col], COL_TEXT_DIM
    test    dword ptr [r12+OB_FLAGS], OBF_SELECTED
    jz      2f
    mov     dword ptr [rip+ls_col], COL_ACCENT
2:  mov     rdi, r12
    lea     rsi, [rip+ls_rec]
    call    hv_light
    call    ls_one
    jmp     1b
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# ls_one - ls_rec's shape
ls_one:
    sub     rsp, 8
    cvttss2si eax, [rip+ls_rec+24]
    cmp     eax, 1
    je      .Lsh_sun
    cmp     eax, 3
    je      .Lsh_area
    movss   xmm0, [rip+ls_rec+28]       # point, spot: the radius's circles
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    jbe     3f
    lea     rdi, [rip+ax_x]
    lea     rsi, [rip+ax_y]
    call    ls_circle
    lea     rdi, [rip+ax_y]
    lea     rsi, [rip+ax_z]
    movss   xmm0, [rip+ls_rec+28]
    call    ls_circle
    lea     rdi, [rip+ax_z]
    lea     rsi, [rip+ax_x]
    movss   xmm0, [rip+ls_rec+28]
    call    ls_circle
3:  cvttss2si eax, [rip+ls_rec+24]      # a spot: its cone
    cmp     eax, 2
    jne     9f
    call    ls_cone
    jmp     9f
.Lsh_sun:                               # the way it shines
    call    ls_ray
    jmp     9f
.Lsh_area:                              # its square, the way it faces
    lea     rdi, [rip+ls_rec+32]        # V = dir x U
    lea     rsi, [rip+ls_rec+48]
    lea     rdx, [rip+ls_b]
    call    ls_cross
    mov     ecx, 0                      # corners: (+,+) (-,+) (-,-) (+,-)
4:  mov     eax, ecx
    call    ls_corner
    movss   xmm0, [rip+ls_tmp]
    movss   [rip+lp0], xmm0
    movss   xmm0, [rip+ls_tmp+4]
    movss   [rip+lp0+4], xmm0
    movss   xmm0, [rip+ls_tmp+8]
    movss   [rip+lp0+8], xmm0
    lea     eax, [rcx+1]
    and     eax, 3
    push    rcx
    push    rcx
    call    ls_corner
    movss   xmm0, [rip+ls_tmp]
    movss   [rip+lp1], xmm0
    movss   xmm0, [rip+ls_tmp+4]
    movss   [rip+lp1+4], xmm0
    movss   xmm0, [rip+ls_tmp+8]
    movss   [rip+lp1+8], xmm0
    mov     edx, [rip+ls_col]
    call    line3d
    pop     rcx
    pop     rcx
    inc     ecx
    cmp     ecx, 4
    jb      4b
    call    ls_ray
9:  add     rsp, 8
    ret

# ls_corner(eax=0..3) -> ls_tmp = q +- U +- V (rcx kept)
ls_corner:
    movss   xmm1, [rip+lf_one]          # sign of U: corners 0, 3 +
    cmp     eax, 1
    je      1f
    cmp     eax, 2
    jne     2f
1:  xorps   xmm1, [rip+lf_signm]
2:  movss   xmm2, [rip+lf_one]          # sign of V: corners 0, 1 +
    cmp     eax, 2
    jb      3f
    xorps   xmm2, [rip+lf_signm]
3:  xor     edx, edx
4:  lea     r8, [rip+ls_rec]
    movss   xmm0, [r8+48+rdx*4]
    mulss   xmm0, xmm1
    lea     r8, [rip+ls_b]
    movss   xmm3, [r8+rdx*4]
    mulss   xmm3, xmm2
    addss   xmm0, xmm3
    lea     r8, [rip+ls_rec]
    addss   xmm0, [r8+rdx*4]
    lea     r8, [rip+ls_tmp]
    movss   [r8+rdx*4], xmm0
    inc     edx
    cmp     edx, 3
    jb      4b
    ret

# ls_ray - from the light, 0.6 m the way it shines
ls_ray:
    sub     rsp, 8
    xor     ecx, ecx
1:  lea     r8, [rip+ls_rec]
    movss   xmm0, [r8+rcx*4]
    lea     r9, [rip+lp0]
    movss   [r9+rcx*4], xmm0
    movss   xmm1, [r8+32+rcx*4]
    mulss   xmm1, [rip+lf_arrow]
    addss   xmm0, xmm1
    lea     r9, [rip+lp1]
    movss   [r9+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      1b
    mov     edx, [rip+ls_col]
    call    line3d
    add     rsp, 8
    ret

# ls_cone - a spot's cone: four lines out to 2 m and the circle there
ls_cone:
    push    rbx
    sub     rsp, 16
    lea     rdi, [rip+ls_rec+32]        # a frame round the direction
    lea     rsi, [rip+ls_a]
    lea     rdx, [rip+ls_b]
    call    ls_frame
    movss   xmm0, [rip+ls_rec+44]       # the cone's radius at 2 m: 2 tan acos(c)
    movss   xmm1, xmm0
    mulss   xmm1, xmm1
    movss   xmm2, [rip+lf_one]
    subss   xmm2, xmm1
    xorps   xmm1, xmm1
    maxss   xmm2, xmm1
    sqrtss  xmm2, xmm2
    maxss   xmm0, [rip+lf_tiny]
    divss   xmm2, xmm0
    mulss   xmm2, [rip+lf_cone]
    movss   [rsp], xmm2
    xor     ebx, ebx                    # the circle at the end, around ..
    xor     ecx, ecx
1:  lea     r8, [rip+ls_rec]
    movss   xmm0, [r8+32+rcx*4]
    mulss   xmm0, [rip+lf_cone]
    addss   xmm0, [r8+rcx*4]
    lea     r9, [rip+ls_tmp]
    movss   [r9+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      1b
    movss   xmm0, [rsp]
    lea     rdi, [rip+ls_a]
    lea     rsi, [rip+ls_b]
    lea     rdx, [rip+ls_tmp]
    call    ls_circle_at
    xor     ebx, ebx                    # .. and four lines to it
2:  cvtsi2ss xmm0, ebx
    mulss   xmm0, [rip+lf_quarter]
    call    ls_sincos                   # xmm0 sin, xmm1 cos
    mulss   xmm0, [rsp]
    mulss   xmm1, [rsp]
    xor     ecx, ecx
3:  lea     r8, [rip+ls_rec]
    movss   xmm2, [r8+rcx*4]
    lea     r9, [rip+lp0]
    movss   [r9+rcx*4], xmm2
    lea     r8, [rip+ls_a]
    movss   xmm2, [r8+rcx*4]
    mulss   xmm2, xmm1
    lea     r8, [rip+ls_b]
    movss   xmm3, [r8+rcx*4]
    mulss   xmm3, xmm0
    addss   xmm2, xmm3
    lea     r8, [rip+ls_tmp]
    addss   xmm2, [r8+rcx*4]
    lea     r9, [rip+lp1]
    movss   [r9+rcx*4], xmm2
    inc     ecx
    cmp     ecx, 3
    jb      3b
    mov     edx, [rip+ls_col]
    call    line3d
    inc     ebx
    cmp     ebx, 4
    jb      2b
    add     rsp, 16
    pop     rbx
    ret

# ls_circle(rdi=a, rsi=b unit axes, xmm0=radius) - round the light's centre
ls_circle:
    lea     rdx, [rip+ls_rec]
# ls_circle_at(rdi=a, rsi=b, rdx=centre, xmm0=radius) - SEGS lines
ls_circle_at:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 24
    mov     r12, rdi
    mov     r13, rsi
    mov     r14, rdx
    movss   [rsp], xmm0
    xor     ebx, ebx
1:  cmp     ebx, SEGS
    jae     9f
    cvtsi2ss xmm0, ebx                  # from point i to point i + 1
    divss   xmm0, [rip+lf_segs]
    lea     rdi, [rip+lp0]
    call    ls_cpoint
    lea     eax, [rbx+1]
    cvtsi2ss xmm0, eax
    divss   xmm0, [rip+lf_segs]
    lea     rdi, [rip+lp1]
    call    ls_cpoint
    mov     edx, [rip+ls_col]
    call    line3d
    inc     ebx
    jmp     1b
9:  add     rsp, 24
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ls_cpoint(xmm0=0..1 round, rdi=out; r12 a, r13 b, r14 centre, [rsp+8] r)
ls_cpoint:
    push    rdi
    call    ls_sincos
    pop     rdi
    mulss   xmm0, [rsp+8]
    mulss   xmm1, [rsp+8]
    xor     ecx, ecx
1:  movss   xmm2, [r12+rcx*4]
    mulss   xmm2, xmm1
    movss   xmm3, [r13+rcx*4]
    mulss   xmm3, xmm0
    addss   xmm2, xmm3
    addss   xmm2, [r14+rcx*4]
    movss   [rdi+rcx*4], xmm2
    inc     ecx
    cmp     ecx, 3
    jb      1b
    ret

# ls_sincos(xmm0=0..1 of a turn) -> xmm0 sin, xmm1 cos
ls_sincos:
    sub     rsp, 8
    mulss   xmm0, [rip+lf_2pi]
    movss   [rsp], xmm0
    fld     dword ptr [rsp]
    fsincos
    fstp    dword ptr [rsp+4]
    fstp    dword ptr [rsp]
    movss   xmm0, [rsp]
    movss   xmm1, [rsp+4]
    add     rsp, 8
    ret

# ls_frame(rdi=unit n, rsi=a, rdx=b) - two unit axes across n
ls_frame:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13, rdx
    lea     rsi, [rip+ax_y]             # n x Y (or n x X near vertical)
    movss   xmm0, [rbx+4]
    andps   xmm0, [rip+lf_absm]
    comiss  xmm0, [rip+lf_vert]
    jb      1f
    lea     rsi, [rip+ax_x]
1:  mov     rdi, rbx
    mov     rdx, r12
    call    ls_cross
    mov     rdi, r12
    call    ls_unit
    mov     rdi, rbx                    # b = n x a
    mov     rsi, r12
    mov     rdx, r13
    call    ls_cross
    pop     r13
    pop     r12
    pop     rbx
    ret

ls_unit:
    movss   xmm0, [rdi]
    mulss   xmm0, xmm0
    movss   xmm1, [rdi+4]
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    movss   xmm1, [rdi+8]
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    sqrtss  xmm0, xmm0
    maxss   xmm0, [rip+lf_tiny]
    xor     ecx, ecx
1:  movss   xmm1, [rdi+rcx*4]
    divss   xmm1, xmm0
    movss   [rdi+rcx*4], xmm1
    inc     ecx
    cmp     ecx, 3
    jb      1b
    ret

ls_cross:                               # rdi x rsi -> rdx
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

.section .rodata
.align 16
lf_signm:       .long 0x80000000, 0, 0, 0
lf_absm:        .long 0x7fffffff, 0, 0, 0
lf_vert:        .float 0.9
lf_tiny:        .float 1.0e-12
lf_quarter:     .float 0.25

.section .note.GNU-stack,"",@progbits
