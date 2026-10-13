# =============================================================================
#  BeeModel - textures: bilinear image lookups and box projection
#
#  Meshes with UVs are textured through them (the renderers hand the
#  triangle's UVs to the shader graph). Without UVs a textured surface is
#  box-projected in object space: each triangle takes the two axes across
#  its face normal's largest component, so cubes map one image per side and
#  the texture follows the object when it moves. Lookups wrap (repeat), are bilinear and
#  return linear colour (8-bit images are sRGB, decoded through a table).
# =============================================================================
.intel_syntax noprefix
.include "const.inc"

.globl tex_init
.globl tex_sample
.globl tx_unlin
.globl box_uv
.globl srgb_to_lin
.globl tex_texel

.equ IM_W,     0
.equ IM_H,     4
.equ IM_FMT,   8
.equ IM_DATA,  64

.section .rodata
.align 4
tx_one:         .float 1.0
tx_half:        .float 0.5
tx_inv255:      .float 0.00392156863
tx_lin_k:       .float 0.0773993808     # 1 / 12.92
tx_lin_t:       .float 0.04045
tx_a:           .float 0.9478672986     # 1 / 1.055
tx_b:           .float 0.0521327014     # 0.055 / 1.055
tx_big:         .float 1.0e7

.section .bss
.align 16
tx_lut:         .skip 256*4
tx_ready:       .skip 4

.text

# srgb_to_lin(xmm0 in 0..1) -> xmm0 linear (x87 pow; rax kept)
srgb_to_lin:
    comiss  xmm0, [rip+tx_lin_t]
    ja      1f
    mulss   xmm0, [rip+tx_lin_k]
    ret
1:  mulss   xmm0, [rip+tx_a]            # ((c + 0.055) / 1.055)^2.4
    addss   xmm0, [rip+tx_b]
    sub     rsp, 8
    movss   [rsp], xmm0
    mov     dword ptr [rsp+4], 0x4019999a
    fld     dword ptr [rsp+4]
    fld     dword ptr [rsp]
    fyl2x
    fld     st(0)
    frndint
    fsub    st(1), st(0)
    fxch    st(1)
    f2xm1
    fld1
    faddp   st(1), st(0)
    fscale
    fstp    st(1)
    fstp    dword ptr [rsp]
    movss   xmm0, [rsp]
    add     rsp, 8
    ret

# tex_init - the sRGB table (call from the main thread before lookups)
tex_init:
    cmp     dword ptr [rip+tx_ready], 0
    jne     9f
    push    rbx
    xor     ebx, ebx
1:  cvtsi2ss xmm0, ebx
    mulss   xmm0, [rip+tx_inv255]
    call    srgb_to_lin
    lea     rax, [rip+tx_lut]
    movss   [rax+rbx*4], xmm0
    inc     ebx
    cmp     ebx, 256
    jb      1b
    mov     dword ptr [rip+tx_ready], 1
    pop     rbx
9:  ret

# floor_wrap(xmm0=x, ecx=n) -> eax = floor(x) mod n, xmm0 = fraction
floor_wrap:
    xorps   xmm2, xmm2                  # (keep it in int range)
    subss   xmm2, [rip+tx_big]
    maxss   xmm0, xmm2
    minss   xmm0, [rip+tx_big]
    cvttss2si eax, xmm0
    cvtsi2ss xmm2, eax
    comiss  xmm2, xmm0
    jbe     1f
    dec     eax
    cvtsi2ss xmm2, eax
1:  subss   xmm0, xmm2
    cdq
    idiv    ecx
    mov     eax, edx
    test    eax, eax
    jns     2f
    add     eax, ecx
2:  ret

# tx_unlin(xmm0 = a linear value from an 8-bit image) -> xmm0 = the stored
#   0..1 value again (normal maps are data, not colour): the decoding table
#   searched, interpolated between entries (keeps rdi rsi; xmm0..2, eax ecx
#   edx r8 change)
tx_unlin:
    lea     r8, [rip+tx_lut]
    xor     eax, eax                    # the last entry <= x: lo = 0, hi = 255
    mov     ecx, 255
1:  mov     edx, ecx
    sub     edx, eax
    cmp     edx, 1
    jbe     2f
    lea     edx, [rax+rcx]
    shr     edx, 1
    comiss  xmm0, [r8+rdx*4]
    jb      11f
    mov     eax, edx
    jmp     1b
11: mov     ecx, edx
    jmp     1b
2:  movss   xmm1, [r8+rcx*4]            # i + (x - lut[i]) / (lut[i+1] - lut[i])
    subss   xmm1, [r8+rax*4]
    subss   xmm0, [r8+rax*4]
    xorps   xmm2, xmm2
    maxss   xmm0, xmm2
    divss   xmm0, xmm1
    minss   xmm0, [rip+tx_one]
    cvtsi2ss xmm1, eax
    addss   xmm0, xmm1
    mulss   xmm0, [rip+tx_inv255]
    ret

# texel(rdi=image, ecx=x, edx=y, rsi=out[3]) - linear colour
tex_texel:
texel:
    imul    edx, [rdi+IM_W]
    add     edx, ecx
    cmp     dword ptr [rdi+IM_FMT], 0
    jne     1f
    mov     eax, [rdi+IM_DATA+rdx*4]    # 0xAARRGGBB
    lea     r8, [rip+tx_lut]
    mov     ecx, eax
    shr     ecx, 16
    movzx   ecx, cl
    movss   xmm0, [r8+rcx*4]
    movss   [rsi], xmm0
    movzx   ecx, ah
    movss   xmm0, [r8+rcx*4]
    movss   [rsi+4], xmm0
    movzx   ecx, al
    movss   xmm0, [r8+rcx*4]
    movss   [rsi+8], xmm0
    ret
1:  lea     rdx, [rdx+rdx*2]
    mov     rax, [rdi+IM_DATA+rdx*4]
    mov     [rsi], rax
    mov     eax, [rdi+IM_DATA+rdx*4+8]
    mov     [rsi+8], eax
    ret

# tex_sample(rdi=image, xmm0=u, xmm1=v, rsi=out[3]) - bilinear, repeating;
#   v runs up the image
tex_sample:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 80
    mov     rbx, rdi
    mov     r12, rsi
    cvtsi2ss xmm2, dword ptr [rbx+IM_W] # x = u w - 0.5
    mulss   xmm0, xmm2
    subss   xmm0, [rip+tx_half]
    movss   xmm3, [rip+tx_one]          # y = (1 - v) h - 0.5
    subss   xmm3, xmm1
    cvtsi2ss xmm2, dword ptr [rbx+IM_H]
    mulss   xmm3, xmm2
    subss   xmm3, [rip+tx_half]
    movss   [rsp+64], xmm3
    mov     ecx, [rbx+IM_W]
    call    floor_wrap
    mov     r13d, eax                   # x0
    movss   [rsp+68], xmm0              # fx
    movss   xmm0, [rsp+64]
    mov     ecx, [rbx+IM_H]
    call    floor_wrap
    mov     r14d, eax                   # y0
    movss   [rsp+72], xmm0              # fy
    lea     r15d, [r13+1]               # x1, y1 (wrapped)
    cmp     r15d, [rbx+IM_W]
    jb      1f
    xor     r15d, r15d
1:  lea     eax, [r14+1]
    cmp     eax, [rbx+IM_H]
    jb      2f
    xor     eax, eax
2:  mov     [rsp+76], eax
    mov     rdi, rbx                    # the four texels
    mov     ecx, r13d
    mov     edx, r14d
    lea     rsi, [rsp]
    call    texel
    mov     rdi, rbx
    mov     ecx, r15d
    mov     edx, r14d
    lea     rsi, [rsp+16]
    call    texel
    mov     rdi, rbx
    mov     ecx, r13d
    mov     edx, [rsp+76]
    lea     rsi, [rsp+32]
    call    texel
    mov     rdi, rbx
    mov     ecx, r15d
    mov     edx, [rsp+76]
    lea     rsi, [rsp+48]
    call    texel
    movss   xmm4, [rsp+68]
    movss   xmm5, [rsp+72]
    xor     ecx, ecx
3:  movss   xmm0, [rsp+rcx*4]           # top: a + (b - a) fx
    movss   xmm1, [rsp+16+rcx*4]
    subss   xmm1, xmm0
    mulss   xmm1, xmm4
    addss   xmm0, xmm1
    movss   xmm2, [rsp+32+rcx*4]        # bottom
    movss   xmm1, [rsp+48+rcx*4]
    subss   xmm1, xmm2
    mulss   xmm1, xmm4
    addss   xmm2, xmm1
    subss   xmm2, xmm0
    mulss   xmm2, xmm5
    addss   xmm0, xmm2
    movss   [r12+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      3b
    add     rsp, 80
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# box_uv(rdi=p0, rsi=p1, rdx=p2 (object space), rcx=out u0 v0 u1 v1 u2 v2)
box_uv:
    movss   xmm0, [rsi]                 # e1, e2
    subss   xmm0, [rdi]
    movss   xmm1, [rsi+4]
    subss   xmm1, [rdi+4]
    movss   xmm2, [rsi+8]
    subss   xmm2, [rdi+8]
    movss   xmm3, [rdx]
    subss   xmm3, [rdi]
    movss   xmm4, [rdx+4]
    subss   xmm4, [rdi+4]
    movss   xmm5, [rdx+8]
    subss   xmm5, [rdi+8]
    movss   xmm6, xmm1                  # n = e1 x e2
    mulss   xmm6, xmm5
    movss   xmm7, xmm2
    mulss   xmm7, xmm4
    subss   xmm6, xmm7                  # nx
    movss   xmm7, xmm2
    mulss   xmm7, xmm3
    mulss   xmm5, xmm0
    subss   xmm7, xmm5                  # ny
    mulss   xmm0, xmm4
    mulss   xmm1, xmm3
    subss   xmm0, xmm1                  # nz
    # the dominant axis and its sign
    xor     r8d, r8d                    # axis
    movss   xmm1, xmm6
    andps   xmm1, [rip+tx_abs]
    movss   xmm2, xmm7
    andps   xmm2, [rip+tx_abs]
    movss   xmm3, xmm0
    andps   xmm3, [rip+tx_abs]
    movss   xmm4, xmm6                  # the signed component
    comiss  xmm2, xmm1
    jbe     1f
    mov     r8d, 1
    movss   xmm1, xmm2
    movss   xmm4, xmm7
1:  comiss  xmm3, xmm1
    jbe     2f
    mov     r8d, 2
    movss   xmm4, xmm0
2:  xorps   xmm5, xmm5
    xor     r9d, r9d                    # flip u when the face looks down its axis
    comiss  xmm4, xmm5
    jae     3f
    mov     r9d, 1
3:  mov     r10, rdi                    # corners
    call    corner_uv
    mov     r10, rsi
    add     rcx, 8
    call    corner_uv
    mov     r10, rdx
    add     rcx, 8
    call    corner_uv
    ret
# corner_uv(r10=p, r8d=axis, r9d=flip, rcx=out[2])
#   x: (-z, y) / (z, y)   y: (x, -z) / (x, z)   z: (x, y) / (-x, y)
corner_uv:
    cmp     r8d, 1
    je      2f
    ja      3f
    movss   xmm0, [r10+8]               # x axis
    test    r9d, r9d
    jnz     1f
    xorps   xmm0, [rip+tx_sign]
1:  movss   xmm1, [r10+4]
    jmp     8f
2:  movss   xmm0, [r10]                 # y axis
    movss   xmm1, [r10+8]
    test    r9d, r9d
    jnz     8f
    xorps   xmm1, [rip+tx_sign]
    jmp     8f
3:  movss   xmm0, [r10]                 # z axis
    test    r9d, r9d
    jz      31f
    xorps   xmm0, [rip+tx_sign]
31: movss   xmm1, [r10+4]
8:  movss   [rcx], xmm0
    movss   [rcx+4], xmm1
    ret

.section .rodata
.align 16
tx_abs:         .long 0x7fffffff, 0, 0, 0
tx_sign:        .long 0x80000000, 0, 0, 0

.section .note.GNU-stack,"",@progbits
