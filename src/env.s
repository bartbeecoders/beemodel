# =============================================================================
#  BeeModel - the world: an HDRI environment (equirectangular image)
#
#  When the world has an image it replaces the studio sky and sun:
#    Hive    radiance lookups (bilinear) and importance sampling through a
#            2D CDF over luminance x sin(theta) (marginal rows, conditional
#            columns), with the pdf for MIS;
#    preview irradiance from 9 spherical-harmonic coefficients (Ramamoorthi
#            and Hanrahan) and reflections from a 128 x 64 blurred copy.
#  Directions: y up; u = 0.5 + (atan2(x, -z) - rotation) / 2 pi, v = theta / pi
#  (row 0 looks straight up). The tables are rebuilt when the image changes.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

.globl env_idx
.globl env_str
.globl env_rot
.globl env_prep
.globl env_rad
.globl env_sample
.globl env_pdf
.globl env_irr_pv
.globl env_spec_pv
.globl env_on
.globl env_forget
.globl op_world_hdri
.globl op_world_strength
.globl op_world_rotation

.equ IM_W,     0
.equ IM_H,     4
.equ IM_FMT,   8
.equ IM_DATA,  64
.equ SMALL_W,  128
.equ SMALL_H,  64

.section .data
.align 4
env_idx:        .long 0                 # image + 1 (0: the studio sky)
env_str:        .float 1.0
env_rot:        .float 0.0              # radians about y

.section .bss
.align 8
env_on:         .skip 4                 # prepared and active
env_img:        .skip 8                 # the image the tables are for
env_cond:       .skip 8                 # f32[h][w]: per row, normalised CDF
env_rows:       .skip 8                 # f32[h]: row sums
env_marg:       .skip 8                 # f32[h]: normalised CDF over rows
env_mapsz:      .skip 8
env_total:      .skip 4
env_small:      .skip 8                 # 128 x 64 blurred (an image, f32)
env_sh:         .skip 27*4              # SH coefficients, rgb
env_cr:         .skip 4                 # cos, sin of the rotation
env_sr:         .skip 4
ew_word:        .skip 64

.section .rodata
.align 4
ef_one:         .float 1.0
ef_half:        .float 0.5
ef_zero:        .float 0.0
ef_pi:          .float 3.14159265
ef_2pi:         .float 6.28318531
ef_inv2pi:      .float 0.15915494
ef_invpi:       .float 0.31830989
ef_2pi2:        .float 19.7392088           # 2 pi^2
ef_tiny:        .float 1.0e-12
ef_deg:         .float 0.01745329
ef_lum:         .float 0.2126, 0.7152, 0.0722
# SH: constants and the cosine lobe's bands (A0 = pi, A1 = 2pi/3, A2 = pi/4)
ef_y0:          .float 0.282095
ef_y1:          .float 0.488603
ef_y2a:         .float 1.092548
ef_y2b:         .float 0.315392
ef_y2c:         .float 0.546274
ef_a:           .float 3.14159265, 2.0943951, 0.78539816
ef_three:       .float 3.0
s_w_need:       .asciz "  world.hdri <image|none>"
s_w_noimg:      .asciz "  no image named "
s_w_hdri:       .asciz "  world: "
s_w_studio:     .asciz "the studio sky"
s_w_none:       .asciz "none"
s_w_str:        .asciz "  world strength: "
s_w_rot:        .asciz "  world rotation: "

OPERATOR op_world_hdri, "world.hdri", "World HDRI", do_world_hdri, flags=OPF_AI_SAFE, doc="Light the scene with an equirectangular image: world.hdri <image|none>"
OPERATOR op_world_strength, "world.strength", "World Strength", do_world_strength, flags=OPF_AI_SAFE, doc="Scale the world's light: world.strength <factor>", form=form_wstrength
OPERATOR op_world_rotation, "world.rotation", "World Rotation", do_world_rotation, flags=OPF_AI_SAFE, doc="Turn the world image about the vertical: world.rotation <degrees>", form=form_wrotation

.text

# ---- directions ------------------------------------------------------------
# dir_uv(rdi=dir) -> xmm0 = u, xmm1 = v, xmm2 = sin theta
dir_uv:
    sub     rsp, 24
    movss   xmm0, [rdi]                 # phi = atan2(x, -z)
    movss   [rsp], xmm0
    movss   xmm0, [rdi+8]
    xorps   xmm1, xmm1
    subss   xmm1, xmm0
    movss   [rsp+4], xmm1
    fld     dword ptr [rsp]
    fld     dword ptr [rsp+4]
    fpatan
    fstp    dword ptr [rsp+8]
    movss   xmm0, [rdi+4]               # cos theta = y (clamped)
    minss   xmm0, [rip+ef_one]
    xorps   xmm1, xmm1
    subss   xmm1, [rip+ef_one]
    maxss   xmm0, xmm1
    movss   xmm2, xmm0                  # sin = sqrt(1 - y^2)
    mulss   xmm2, xmm2
    movss   xmm3, [rip+ef_one]
    subss   xmm3, xmm2
    maxss   xmm3, [rip+ef_zero]
    sqrtss  xmm2, xmm3
    movss   [rsp+12], xmm2
    movss   [rsp+16], xmm0
    fld     dword ptr [rsp+12]          # theta = atan2(sin, cos)
    fld     dword ptr [rsp+16]
    fpatan
    fstp    dword ptr [rsp+16]
    movss   xmm0, [rsp+8]               # u = 0.5 + (phi - rot) / 2pi, wrapped
    subss   xmm0, [rip+env_rot]
    mulss   xmm0, [rip+ef_inv2pi]
    addss   xmm0, [rip+ef_half]
    cvttss2si eax, xmm0
    cvtsi2ss xmm1, eax
    comiss  xmm1, xmm0
    jbe     1f
    subss   xmm1, [rip+ef_one]
1:  subss   xmm0, xmm1
    movss   xmm1, [rsp+16]
    mulss   xmm1, [rip+ef_invpi]
    movss   xmm2, [rsp+12]
    add     rsp, 24
    ret

# uv_dir(xmm0=u, xmm1=v, rdi=out dir) -> xmm2 = sin theta
uv_dir:
    sub     rsp, 24
    mulss   xmm0, [rip+ef_2pi]          # phi = 2pi (u - 0.5) + rot
    subss   xmm0, [rip+ef_pi]
    addss   xmm0, [rip+env_rot]
    mulss   xmm1, [rip+ef_pi]           # theta
    movss   [rsp], xmm0
    movss   [rsp+4], xmm1
    fld     dword ptr [rsp+4]
    fsincos                             # st0 = cos t, st1 = sin t
    fstp    dword ptr [rsp+8]           # cos t
    fstp    dword ptr [rsp+12]          # sin t
    fld     dword ptr [rsp]
    fsincos
    fstp    dword ptr [rsp+16]          # cos p
    fstp    dword ptr [rsp+20]          # sin p
    movss   xmm2, [rsp+12]
    movss   xmm0, [rsp+20]              # (sin t sin p, cos t, -sin t cos p)
    mulss   xmm0, xmm2
    movss   [rdi], xmm0
    movss   xmm0, [rsp+8]
    movss   [rdi+4], xmm0
    movss   xmm0, [rsp+16]
    mulss   xmm0, xmm2
    xorps   xmm1, xmm1
    subss   xmm1, xmm0
    movss   [rdi+8], xmm1
    add     rsp, 24
    ret

# lookup(rdi=image, xmm0=u, xmm1=v, rsi=out[3]) - bilinear: u wraps, v clamps
lookup:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 72
    mov     rbx, rdi
    mov     r12, rsi
    cvtsi2ss xmm2, dword ptr [rbx+IM_W]
    mulss   xmm0, xmm2
    subss   xmm0, [rip+ef_half]
    cvtsi2ss xmm2, dword ptr [rbx+IM_H]
    mulss   xmm1, xmm2
    subss   xmm1, [rip+ef_half]
    maxss   xmm1, [rip+ef_zero]
    cvttss2si eax, xmm0                 # x0 = floor, fx
    cvtsi2ss xmm2, eax
    comiss  xmm2, xmm0
    jbe     1f
    dec     eax
    cvtsi2ss xmm2, eax
1:  subss   xmm0, xmm2
    movss   [rsp+48], xmm0
    cdq
    idiv    dword ptr [rbx+IM_W]
    test    edx, edx
    jns     2f
    add     edx, [rbx+IM_W]
2:  mov     r13d, edx                   # x0
    cvttss2si eax, xmm1                 # y0 (>= 0), fy
    cvtsi2ss xmm2, eax
    subss   xmm1, xmm2
    movss   [rsp+52], xmm1
    mov     ecx, [rbx+IM_H]
    dec     ecx
    cmp     eax, ecx
    cmova   eax, ecx
    mov     r14d, eax                   # y0
    lea     eax, [r14+1]
    cmp     eax, ecx
    cmova   eax, ecx
    mov     [rsp+56], eax               # y1
    lea     eax, [r13+1]
    cmp     eax, [rbx+IM_W]
    jb      3f
    xor     eax, eax
3:  mov     [rsp+60], eax               # x1
    mov     rdi, rbx
    mov     ecx, r13d
    mov     edx, r14d
    lea     rsi, [rsp]
    call    tex_texel
    mov     rdi, rbx
    mov     ecx, [rsp+60]
    mov     edx, r14d
    lea     rsi, [rsp+12]
    call    tex_texel
    mov     rdi, rbx
    mov     ecx, r13d
    mov     edx, [rsp+56]
    lea     rsi, [rsp+24]
    call    tex_texel
    mov     rdi, rbx
    mov     ecx, [rsp+60]
    mov     edx, [rsp+56]
    lea     rsi, [rsp+36]
    call    tex_texel
    movss   xmm4, [rsp+48]
    movss   xmm5, [rsp+52]
    xor     ecx, ecx
4:  movss   xmm0, [rsp+rcx*4]
    movss   xmm1, [rsp+12+rcx*4]
    subss   xmm1, xmm0
    mulss   xmm1, xmm4
    addss   xmm0, xmm1
    movss   xmm2, [rsp+24+rcx*4]
    movss   xmm1, [rsp+36+rcx*4]
    subss   xmm1, xmm2
    mulss   xmm1, xmm4
    addss   xmm2, xmm1
    subss   xmm2, xmm0
    mulss   xmm2, xmm5
    addss   xmm0, xmm2
    movss   [r12+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      4b
    add     rsp, 72
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# scale_out(rsi=out[3]) - times the world strength
scale_out:
    movss   xmm0, [rip+env_str]
    xor     ecx, ecx
1:  movss   xmm1, [rsi+rcx*4]
    mulss   xmm1, xmm0
    movss   [rsi+rcx*4], xmm1
    inc     ecx
    cmp     ecx, 3
    jb      1b
    ret

# env_rad(rdi=dir, rsi=out[3]) - the world's radiance (env_on must be set)
env_rad:
    push    rbx
    mov     rbx, rsi
    call    dir_uv
    mov     rdi, [rip+env_img]
    mov     rsi, rbx
    call    lookup
    mov     rsi, rbx
    call    scale_out
    pop     rbx
    ret

# env_spec_pv(rdi=dir, rsi=out[3]) - the blurred world (preview reflections)
env_spec_pv:
    push    rbx
    mov     rbx, rsi
    call    dir_uv
    mov     rdi, [rip+env_small]
    mov     rsi, rbx
    call    lookup
    mov     rsi, rbx
    call    scale_out
    pop     rbx
    ret

# sh_basis(rdi=dir, rsi=out[9])
sh_basis:
    movss   xmm0, [rdi]                 # x y z
    movss   xmm1, [rdi+4]
    movss   xmm2, [rdi+8]
    movss   xmm3, [rip+ef_y0]
    movss   [rsi], xmm3
    movss   xmm3, [rip+ef_y1]
    movss   xmm4, xmm3
    mulss   xmm4, xmm1
    movss   [rsi+4], xmm4               # y
    movss   xmm4, xmm3
    mulss   xmm4, xmm2
    movss   [rsi+8], xmm4               # z
    mulss   xmm3, xmm0
    movss   [rsi+12], xmm3              # x
    movss   xmm3, [rip+ef_y2a]
    movss   xmm4, xmm0
    mulss   xmm4, xmm1
    mulss   xmm4, xmm3
    movss   [rsi+16], xmm4              # xy
    movss   xmm4, xmm1
    mulss   xmm4, xmm2
    mulss   xmm4, xmm3
    movss   [rsi+20], xmm4              # yz
    movss   xmm4, xmm2                  # 3 z^2 - 1
    mulss   xmm4, xmm2
    mulss   xmm4, [rip+ef_three]
    subss   xmm4, [rip+ef_one]
    mulss   xmm4, [rip+ef_y2b]
    movss   [rsi+24], xmm4
    movss   xmm4, xmm0
    mulss   xmm4, xmm2
    mulss   xmm4, xmm3
    movss   [rsi+28], xmm4              # xz
    movss   xmm4, xmm0                  # x^2 - y^2
    mulss   xmm4, xmm0
    movss   xmm5, xmm1
    mulss   xmm5, xmm1
    subss   xmm4, xmm5
    mulss   xmm4, [rip+ef_y2c]
    movss   [rsi+32], xmm4
    ret

# env_irr_pv(rdi=normal, rsi=out[3]) - irradiance / pi from the SH
env_irr_pv:
    push    rbx
    sub     rsp, 64
    mov     rbx, rsi
    movss   xmm0, [rdi]                 # x' = x c + z s, z' = z c - x s
    mulss   xmm0, [rip+env_cr]
    movss   xmm1, [rdi+8]
    mulss   xmm1, [rip+env_sr]
    addss   xmm0, xmm1
    movss   [rsp+48], xmm0
    mov     eax, [rdi+4]
    mov     [rsp+52], eax
    movss   xmm0, [rdi+8]
    mulss   xmm0, [rip+env_cr]
    movss   xmm1, [rdi]
    mulss   xmm1, [rip+env_sr]
    subss   xmm0, xmm1
    movss   [rsp+56], xmm0
    lea     rdi, [rsp+48]
    lea     rsi, [rsp]
    call    sh_basis
    lea     rax, [rip+ef_a]             # band weights
    movss   xmm0, [rax]
    mulss   xmm0, [rsp]
    movss   [rsp], xmm0
    mov     ecx, 1
1:  movss   xmm0, [rax+4]
    mulss   xmm0, [rsp+rcx*4]
    movss   [rsp+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 4
    jb      1b
2:  movss   xmm0, [rax+8]
    mulss   xmm0, [rsp+rcx*4]
    movss   [rsp+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 9
    jb      2b
    xor     edx, edx                    # channel
3:  xorps   xmm0, xmm0
    xor     ecx, ecx
    lea     r8, [rip+env_sh]
4:  lea     eax, [rcx+rcx*2]
    add     eax, edx
    movss   xmm1, [r8+rax*4]
    mulss   xmm1, [rsp+rcx*4]
    addss   xmm0, xmm1
    inc     ecx
    cmp     ecx, 9
    jb      4b
    mulss   xmm0, [rip+ef_invpi]
    maxss   xmm0, [rip+ef_zero]
    mulss   xmm0, [rip+env_str]
    movss   [rbx+rdx*4], xmm0
    inc     edx
    cmp     edx, 3
    jb      3b
    add     rsp, 64
    pop     rbx
    ret

# ---- the tables ------------------------------------------------------------
# env_prep -> eax = 1 when the world has an image (tables ready); main thread
env_prep:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 88
    mov     dword ptr [rip+env_on], 0
    mov     edi, [rip+env_idx]
    test    edi, edi
    jz      .Lep_out
    dec     edi
    call    image_ptr
    test    rax, rax
    jz      .Lep_out
    cmp     rax, [rip+env_img]
    je      .Lep_ready
    mov     rbx, rax
    call    env_free
    mov     [rip+env_img], rbx
    call    tex_init
    # the CDF: w h floats (cond) + 2 h (rows, marg)
    mov     eax, [rbx+IM_W]
    inc     eax
    imul    eax, [rbx+IM_H]
    lea     rdi, [rax*4]
    mov     eax, [rbx+IM_H]
    lea     rdi, [rdi+rax*8+64]
    mov     [rip+env_mapsz], rdi
    call    vmap
    test    rax, rax
    jz      .Lep_fail
    mov     [rip+env_cond], rax
    mov     ecx, [rbx+IM_W]
    imul    ecx, [rbx+IM_H]
    lea     rax, [rax+rcx*4]
    mov     [rip+env_rows], rax
    mov     ecx, [rbx+IM_H]
    lea     rax, [rax+rcx*4]
    mov     [rip+env_marg], rax
    xorps   xmm6, xmm6                  # total
    movss   [rsp+80], xmm6
    xor     r13d, r13d                  # row
1:  cmp     r13d, [rbx+IM_H]
    jae     5f
    cvtsi2ss xmm0, r13d                 # sin(theta of the row centre)
    addss   xmm0, [rip+ef_half]
    mulss   xmm0, [rip+ef_pi]
    cvtsi2ss xmm1, dword ptr [rbx+IM_H]
    divss   xmm0, xmm1
    movss   [rsp+64], xmm0
    fld     dword ptr [rsp+64]
    fsin
    fstp    dword ptr [rsp+64]
    xorps   xmm7, xmm7                  # row running sum
    movss   [rsp+68], xmm7
    mov     eax, r13d
    imul    eax, [rbx+IM_W]
    mov     rcx, [rip+env_cond]
    lea     r14, [rcx+rax*4]
    xor     r12d, r12d
2:  cmp     r12d, [rbx+IM_W]
    jae     3f
    mov     rdi, rbx
    mov     ecx, r12d
    mov     edx, r13d
    lea     rsi, [rsp]
    call    tex_texel
    movss   xmm0, [rsp]                 # luminance
    mulss   xmm0, [rip+ef_lum]
    movss   xmm1, [rsp+4]
    mulss   xmm1, [rip+ef_lum+4]
    addss   xmm0, xmm1
    movss   xmm1, [rsp+8]
    mulss   xmm1, [rip+ef_lum+8]
    addss   xmm0, xmm1
    maxss   xmm0, [rip+ef_zero]
    mulss   xmm0, [rsp+64]
    addss   xmm0, [rsp+68]
    movss   [rsp+68], xmm0
    movss   [r14+r12*4], xmm0
    inc     r12d
    jmp     2b
3:  movss   xmm0, [rsp+68]              # normalise the row (uniform if empty)
    mov     rax, [rip+env_rows]
    movss   [rax+r13*4], xmm0
    addss   xmm0, [rsp+80]
    movss   [rsp+80], xmm0
    mov     rax, [rip+env_marg]
    movss   [rax+r13*4], xmm0
    movss   xmm1, [rsp+68]
    xor     r12d, r12d
    comiss  xmm1, [rip+ef_tiny]
    jbe     32f
    movss   xmm2, [rip+ef_one]
    divss   xmm2, xmm1
31: cmp     r12d, [rbx+IM_W]
    jae     4f
    movss   xmm0, [r14+r12*4]
    mulss   xmm0, xmm2
    movss   [r14+r12*4], xmm0
    inc     r12d
    jmp     31b
32: cvtsi2ss xmm2, dword ptr [rbx+IM_W]
33: cmp     r12d, [rbx+IM_W]
    jae     4f
    lea     eax, [r12+1]
    cvtsi2ss xmm0, eax
    divss   xmm0, xmm2
    movss   [r14+r12*4], xmm0
    inc     r12d
    jmp     33b
4:  inc     r13d
    jmp     1b
5:  movss   xmm0, [rsp+80]
    movss   [rip+env_total], xmm0
    comiss  xmm0, [rip+ef_tiny]
    jbe     .Lep_fail                   # (a black world: no light)
    movss   xmm2, [rip+ef_one]
    divss   xmm2, xmm0
    mov     rax, [rip+env_marg]
    xor     ecx, ecx
6:  cmp     ecx, [rbx+IM_H]
    jae     7f
    movss   xmm0, [rax+rcx*4]
    mulss   xmm0, xmm2
    movss   [rax+rcx*4], xmm0
    inc     ecx
    jmp     6b
7:  # the blurred copy: box averages into 128 x 64
    mov     edi, SMALL_W
    mov     esi, SMALL_H
    mov     edx, 1
    call    img_alloc
    test    rax, rax
    jz      .Lep_fail
    mov     [rip+env_small], rax
    mov     r15, rax
    xor     r13d, r13d                  # small row
8:  cmp     r13d, SMALL_H
    jae     .Lep_sh
    xor     r12d, r12d
81: cmp     r12d, SMALL_W
    jae     89f
    mov     eax, r12d                   # source box [x0, x1) x [y0, y1)
    imul    eax, [rbx+IM_W]
    xor     edx, edx
    mov     ecx, SMALL_W
    div     ecx
    mov     [rsp+64], eax
    lea     eax, [r12+1]
    imul    eax, [rbx+IM_W]
    xor     edx, edx
    div     ecx
    cmp     eax, [rsp+64]
    ja      82f
    mov     eax, [rsp+64]
    inc     eax
82: mov     [rsp+68], eax
    mov     eax, r13d
    imul    eax, [rbx+IM_H]
    xor     edx, edx
    mov     ecx, SMALL_H
    div     ecx
    mov     [rsp+72], eax
    lea     eax, [r13+1]
    imul    eax, [rbx+IM_H]
    xor     edx, edx
    div     ecx
    cmp     eax, [rsp+72]
    ja      83f
    mov     eax, [rsp+72]
    inc     eax
83: mov     [rsp+76], eax
    xorps   xmm0, xmm0                  # sums at +16, count at +32
    movups  [rsp+16], xmm0
    movss   [rsp+32], xmm0
    mov     r14d, [rsp+72]
84: cmp     r14d, [rsp+76]
    jae     87f
    cmp     r14d, [rbx+IM_H]
    jae     87f
    mov     ebp, [rsp+64]
85: cmp     ebp, [rsp+68]
    jae     86f
    cmp     ebp, [rbx+IM_W]
    jae     86f
    mov     rdi, rbx
    mov     ecx, ebp
    mov     edx, r14d
    lea     rsi, [rsp]
    call    tex_texel
    xor     ecx, ecx
851:movss   xmm0, [rsp+rcx*4]
    addss   xmm0, [rsp+16+rcx*4]
    movss   [rsp+16+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      851b
    movss   xmm0, [rsp+32]
    addss   xmm0, [rip+ef_one]
    movss   [rsp+32], xmm0
    inc     ebp
    jmp     85b
86: inc     r14d
    jmp     84b
87: movss   xmm1, [rip+ef_one]
    divss   xmm1, [rsp+32]
    mov     eax, r13d
    imul    eax, SMALL_W
    add     eax, r12d
    lea     rax, [rax+rax*2]
    lea     rax, [r15+IM_DATA+rax*4]
    xor     ecx, ecx
88: movss   xmm0, [rsp+16+rcx*4]
    mulss   xmm0, xmm1
    movss   [rax+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      88b
    inc     r12d
    jmp     81b
89: inc     r13d
    jmp     8b
.Lep_sh:
    # SH projection of the small copy (rotation-free: in image space, the
    # direction comes from uv_dir with the current rotation at use)
    lea     rdi, [rip+env_sh]
    xor     eax, eax
    mov     ecx, 27
    rep     stosd
    xor     r13d, r13d
1:  cmp     r13d, SMALL_H
    jae     .Lep_ready
    xor     r12d, r12d
2:  cmp     r12d, SMALL_W
    jae     5f
    cvtsi2ss xmm0, r12d                 # the pixel centre's direction
    addss   xmm0, [rip+ef_half]
    mov     eax, SMALL_W
    cvtsi2ss xmm2, eax
    divss   xmm0, xmm2
    cvtsi2ss xmm1, r13d
    addss   xmm1, [rip+ef_half]
    mov     eax, SMALL_H
    cvtsi2ss xmm2, eax
    divss   xmm1, xmm2
    movss   xmm3, [rip+env_rot]         # (in image space)
    movss   [rsp+60], xmm3
    mov     dword ptr [rip+env_rot], 0
    lea     rdi, [rsp]
    call    uv_dir
    movss   xmm3, [rsp+60]
    movss   [rip+env_rot], xmm3
    mulss   xmm2, [rip+ef_2pi2]         # d omega = 2 pi^2 sin / (w h)
    mov     eax, SMALL_W*SMALL_H
    cvtsi2ss xmm3, eax
    divss   xmm2, xmm3
    movss   [rsp+56], xmm2
    lea     rdi, [rsp]
    lea     rsi, [rsp+16]               # 9 basis values (36 bytes)
    call    sh_basis
    mov     eax, r13d
    imul    eax, SMALL_W
    add     eax, r12d
    lea     rax, [rax+rax*2]
    lea     rax, [r15+IM_DATA+rax*4]
    lea     r8, [rip+env_sh]
    xor     ecx, ecx                    # basis
3:  movss   xmm4, [rsp+16+rcx*4]
    mulss   xmm4, [rsp+56]
    xor     edx, edx
4:  movss   xmm0, [rax+rdx*4]
    mulss   xmm0, xmm4
    lea     r9d, [rcx+rcx*2]
    add     r9d, edx
    addss   xmm0, [r8+r9*4]
    movss   [r8+r9*4], xmm0
    inc     edx
    cmp     edx, 3
    jb      4b
    inc     ecx
    cmp     ecx, 9
    jb      3b
    inc     r12d
    jmp     2b
5:  inc     r13d
    jmp     1b
.Lep_ready:
    fld     dword ptr [rip+env_rot]     # cos / sin of the rotation (SH lookups)
    fsincos
    fstp    dword ptr [rip+env_cr]
    fstp    dword ptr [rip+env_sr]
    mov     dword ptr [rip+env_on], 1
    mov     eax, 1
    jmp     9f
.Lep_fail:
    call    env_free
.Lep_out:
    xor     eax, eax
9:  add     rsp, 88
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# env_forget - the images are going: drop the tables and the world settings
env_forget:
    mov     dword ptr [rip+env_idx], 0
    mov     dword ptr [rip+env_str], 0x3f800000
    mov     dword ptr [rip+env_rot], 0
env_free:
    sub     rsp, 8
    mov     rdi, [rip+env_cond]
    mov     rsi, [rip+env_mapsz]
    call    vunmap
    mov     qword ptr [rip+env_cond], 0
    mov     rdi, [rip+env_small]
    call    img_free
    mov     qword ptr [rip+env_small], 0
    mov     qword ptr [rip+env_img], 0
    mov     dword ptr [rip+env_on], 0
    add     rsp, 8
    ret

# bsearch(rdi=cdf, ecx=n, xmm0=u) -> eax = first index with cdf > u
bsearch:
    xor     eax, eax
    mov     edx, ecx
1:  cmp     eax, edx
    jae     2f
    lea     r8d, [rax+rdx]
    shr     r8d, 1
    comiss  xmm0, [rdi+r8*4]
    jb      11f
    lea     eax, [r8+1]
    jmp     1b
11: mov     edx, r8d
    jmp     1b
2:  dec     ecx
    cmp     eax, ecx
    cmova   eax, ecx
    ret

# pdf_px(ecx=x, edx=y, xmm2=sin theta) -> xmm0 = solid-angle pdf
pdf_px:
    mov     r8, [rip+env_img]
    mov     eax, edx
    imul    eax, [r8+IM_W]
    add     eax, ecx
    mov     r9, [rip+env_cond]
    movss   xmm0, [r9+rax*4]            # cond[x] - cond[x-1]
    test    ecx, ecx
    jz      1f
    subss   xmm0, [r9+rax*4-4]
1:  mov     r9, [rip+env_rows]
    mulss   xmm0, [r9+rdx*4]            # = f(x, y)
    divss   xmm0, [rip+env_total]
    cvtsi2ss xmm1, dword ptr [r8+IM_W]
    mulss   xmm0, xmm1
    cvtsi2ss xmm1, dword ptr [r8+IM_H]
    mulss   xmm0, xmm1
    mulss   xmm2, [rip+ef_2pi2]
    maxss   xmm2, [rip+ef_tiny]
    divss   xmm0, xmm2
    ret

# env_sample(rdi=out dir, xmm0..3 = four uniform numbers) -> xmm0 = pdf
env_sample:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 32
    mov     rbx, rdi
    movss   [rsp], xmm1
    movss   [rsp+4], xmm2
    movss   [rsp+8], xmm3
    mov     r8, [rip+env_img]
    mov     rdi, [rip+env_marg]         # the row
    mov     ecx, [r8+IM_H]
    call    bsearch
    mov     r12d, eax
    mov     r8, [rip+env_img]
    mov     eax, r12d
    imul    eax, [r8+IM_W]
    mov     rdi, [rip+env_cond]
    lea     rdi, [rdi+rax*4]
    mov     ecx, [r8+IM_W]
    movss   xmm0, [rsp]
    call    bsearch                     # the column
    mov     r13d, eax
    mov     r8, [rip+env_img]
    cvtsi2ss xmm0, r13d                 # u, v inside the pixel
    addss   xmm0, [rsp+4]
    cvtsi2ss xmm1, dword ptr [r8+IM_W]
    divss   xmm0, xmm1
    cvtsi2ss xmm1, r12d
    addss   xmm1, [rsp+8]
    cvtsi2ss xmm2, dword ptr [r8+IM_H]
    divss   xmm1, xmm2
    mov     rdi, rbx
    call    uv_dir
    mov     ecx, r13d
    mov     edx, r12d
    call    pdf_px
    add     rsp, 32
    pop     r13
    pop     r12
    pop     rbx
    ret

# env_pdf(rdi=dir) -> xmm0 = the solid-angle pdf of env_sample
env_pdf:
    call    dir_uv
    mov     r8, [rip+env_img]
    cvtsi2ss xmm3, dword ptr [r8+IM_W]
    mulss   xmm0, xmm3
    cvttss2si ecx, xmm0
    mov     eax, [r8+IM_W]
    dec     eax
    cmp     ecx, eax
    cmova   ecx, eax
    test    ecx, ecx
    jns     1f
    xor     ecx, ecx
1:  cvtsi2ss xmm3, dword ptr [r8+IM_H]
    mulss   xmm1, xmm3
    cvttss2si edx, xmm1
    mov     eax, [r8+IM_H]
    dec     eax
    cmp     edx, eax
    cmova   edx, eax
    test    edx, edx
    jns     2f
    xor     edx, edx
2:  jmp     pdf_px

# ---- operators -------------------------------------------------------------
do_world_hdri:
    push    rbx
    mov     rdi, [rip+op_arg]
    test    rdi, rdi
    jz      .Lwh_need
    lea     rsi, [rip+ew_word]          # one word
    xor     ecx, ecx
1:  cmp     byte ptr [rdi], ' '
    jne     2f
    inc     rdi
    jmp     1b
2:  mov     al, [rdi+rcx]
    test    al, al
    jz      3f
    cmp     al, ' '
    je      3f
    cmp     ecx, 62
    jae     3f
    mov     [rsi+rcx], al
    inc     ecx
    jmp     2b
3:  mov     byte ptr [rsi+rcx], 0
    test    ecx, ecx
    jz      .Lwh_need
    lea     rdi, [rip+ew_word]
    lea     rsi, [rip+s_w_none]
    call    str_eq
    test    eax, eax
    jz      4f
    mov     dword ptr [rip+env_idx], 0
    lea     rdi, [rip+s_w_hdri]
    lea     rsi, [rip+s_w_studio]
    call    log_pair
    jmp     9f
4:  lea     rdi, [rip+ew_word]
    call    image_find
    test    eax, eax
    js      .Lwh_noimg
    inc     eax
    mov     [rip+env_idx], eax
    lea     rdi, [rip+s_w_hdri]
    lea     rsi, [rip+ew_word]
    call    log_pair
    jmp     9f
.Lwh_noimg:
    lea     rdi, [rip+s_w_noimg]
    lea     rsi, [rip+ew_word]
    call    log_pair
    jmp     9f
.Lwh_need:
    lea     rdi, [rip+s_w_need]
    call    log_line
9:  mov     dword ptr [rip+dirty], 1
    pop     rbx
    ret

# world_num(rdi=label) -> xmm0, eax = 1 if the argument is a number
world_num:
    push    rbx
    mov     rbx, rdi
    mov     rsi, [rip+op_arg]
    xor     eax, eax
    test    rsi, rsi
    jz      1f
    lea     rdx, [rsi+64]
    call    parse_float
1:  pop     rbx
    ret

do_world_strength:
    sub     rsp, 8
    call    world_num
    test    eax, eax
    jz      8f
    maxss   xmm0, [rip+ef_zero]
    movss   [rip+env_str], xmm0
    call    fmt_reset
    lea     rdi, [rip+s_w_str]
    call    fmt_str
    movss   xmm0, [rip+env_str]
    call    fmt_val3
    lea     rdi, [rip+fmt_buf]
    call    log_line
    mov     dword ptr [rip+dirty], 1
    add     rsp, 8
    ret
8:  call    undo_drop_last
    add     rsp, 8
    ret

do_world_rotation:
    sub     rsp, 8
    call    world_num
    test    eax, eax
    jz      8f
    movss   [rsp], xmm0
    mulss   xmm0, [rip+ef_deg]
    movss   [rip+env_rot], xmm0
    call    fmt_reset
    lea     rdi, [rip+s_w_rot]
    call    fmt_str
    movss   xmm0, [rsp]
    call    fmt_val3
    lea     rdi, [rip+fmt_buf]
    call    log_line
    mov     dword ptr [rip+dirty], 1
    add     rsp, 8
    ret
8:  call    undo_drop_last
    add     rsp, 8
    ret

.section .note.GNU-stack,"",@progbits
