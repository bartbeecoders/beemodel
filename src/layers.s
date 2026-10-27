# =============================================================================
#  BeeModel - paint layers
#
#  An 8-bit image can carry a stack of layers (IM_LAYERS, up to 16): the
#  base (the pixels it had) and layers above with alpha, an opacity, a
#  blend mode (normal, multiply, add) and a visibility. The image's own
#  pixels are then the composite, which is what the shaders sample and the
#  files save; texture painting writes into the active layer and composites
#  the texels it touched. Merge flattens the stack into the image.
#  Layers are saved inside .bee files (ILAY: per layer its settings and an
#  RGBA PNG).
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

.globl lay_of
.globl lay_add
.globl lay_target
.globl lay_texel
.globl lay_rect
.globl lay_free
.globl lay_op
.globl ilay_write
.globl ilay_read

.equ IM_W,      0
.equ IM_H,      4
.equ IM_FMT,    8
.equ IM_DIRTY,  24
.equ IM_LAYERS, 32                      # (header) the layer block, or 0
.equ IM_DATA,   64
.equ LB_COUNT,  0                       # layer block: layers (base too),
.equ LB_ACTIVE, 4                       #  the one painted
.equ LB_L,      16
.equ LE_PIX,    0                       # per layer: pixels (0xAARRGGBB),
.equ LE_OPAC,   8                       #  opacity, blend, visible
.equ LE_BLEND,  12
.equ LE_VIS,    16
.equ LE_SZ,     32
.equ MAX_LAY,   16
.equ LB_SZ,     LB_L+MAX_LAY*LE_SZ

.section .rodata
.align 4
ly_one:         .float 1.0
ly_255:         .float 255.0
ly_inv255:      .float 0.003921569
ly_half:        .float 0.5

.text
# lay_of(rdi=image) -> rax = its layer block (0: none)
lay_of:
    xor     eax, eax
    test    rdi, rdi
    jz      1f
    mov     rax, [rdi+IM_LAYERS]
1:  ret

# lay_add(rdi=image) -> eax = the new layer's number (active; -1: none):
#   the first one also makes the base from the image's pixels
lay_add:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    cmp     dword ptr [rbx+IM_FMT], 0
    jne     8f
    mov     r12, [rbx+IM_LAYERS]
    test    r12, r12
    jnz     1f
    mov     edi, LB_SZ                  # the block, the base
    call    smap
    test    rax, rax
    jz      8f
    mov     r12, rax
    call    lay_pixels
    test    rax, rax
    jz      7f
    mov     [r12+LB_L+LE_PIX], rax
    mov     rdi, rax
    lea     rsi, [rbx+IM_DATA]
    mov     ecx, [rbx+IM_W]
    imul    ecx, [rbx+IM_H]
    rep     movsd
    mov     eax, [rip+ly_one]
    mov     [r12+LB_L+LE_OPAC], eax
    mov     dword ptr [r12+LB_L+LE_VIS], 1
    mov     dword ptr [r12+LB_COUNT], 1
    mov     [rbx+IM_LAYERS], r12
1:  mov     r13d, [r12+LB_COUNT]
    cmp     r13d, MAX_LAY
    jae     8f
    call    lay_pixels                  # transparent
    test    rax, rax
    jz      8f
    mov     ecx, r13d
    shl     ecx, 5
    mov     [r12+LB_L+rcx+LE_PIX], rax
    mov     eax, [rip+ly_one]
    mov     [r12+LB_L+rcx+LE_OPAC], eax
    mov     dword ptr [r12+LB_L+rcx+LE_BLEND], 0
    mov     dword ptr [r12+LB_L+rcx+LE_VIS], 1
    inc     dword ptr [r12+LB_COUNT]
    mov     [r12+LB_ACTIVE], r13d
    mov     dword ptr [rbx+IM_DIRTY], 1
    mov     eax, r13d
    jmp     9f
7:  mov     rdi, r12
    mov     esi, LB_SZ
    call    plat_munmap
8:  mov     eax, -1
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# lay_pixels(rbx=image) -> rax = zeroed pixels its size (0: none)
lay_pixels:
    mov     edi, [rbx+IM_W]
    imul    edi, [rbx+IM_H]
    shl     rdi, 2
    jmp     smap

# lay_free(rdi=image) - its layers go (the composite stays)
lay_free:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12, [rbx+IM_LAYERS]
    test    r12, r12
    jz      9f
    xor     r13d, r13d
1:  cmp     r13d, [r12+LB_COUNT]
    jae     2f
    mov     eax, r13d
    shl     eax, 5
    mov     rdi, [r12+LB_L+rax+LE_PIX]
    call    lay_unmap
    inc     r13d
    jmp     1b
2:  mov     rdi, r12
    mov     esi, LB_SZ
    add     esi, 4095
    and     esi, -4096
    call    plat_munmap
    mov     qword ptr [rbx+IM_LAYERS], 0
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# lay_unmap(rdi=pixels; rbx=image)
lay_unmap:
    test    rdi, rdi
    jz      1f
    mov     esi, [rbx+IM_W]
    imul    esi, [rbx+IM_H]
    shl     rsi, 2
    add     rsi, 4095
    and     rsi, -4096
    call    plat_munmap
1:  ret

# lay_target(rdi=image) -> rax = the pixels painting writes: the active
#   layer's (layers), else the image's own
lay_target:
    lea     rax, [rdi+IM_DATA]
    mov     rcx, [rdi+IM_LAYERS]
    test    rcx, rcx
    jz      1f
    mov     eax, [rcx+LB_ACTIVE]
    shl     eax, 5
    mov     rax, [rcx+LB_L+rax+LE_PIX]
1:  ret

# lay_texel(rdi=image, esi=x, edx=y) - the composite there (layers only)
lay_texel:
    push    rbx
    push    r12
    push    r13
    push    r14
    mov     rbx, rdi
    mov     r12, [rbx+IM_LAYERS]
    test    r12, r12
    jz      9f
    mov     eax, edx
    imul    eax, [rbx+IM_W]
    add     eax, esi
    mov     r13d, eax                   # texel
    xorps   xmm4, xmm4                  # colour (0..1): r g b
    xorps   xmm5, xmm5
    xorps   xmm6, xmm6
    xor     r14d, r14d
1:  cmp     r14d, [r12+LB_COUNT]
    jae     5f
    mov     eax, r14d
    shl     eax, 5
    lea     r8, [r12+LB_L+rax]
    cmp     dword ptr [r8+LE_VIS], 0
    je      4f
    mov     rcx, [r8+LE_PIX]
    mov     ecx, [rcx+r13*4]
    mov     eax, ecx                    # a x opacity
    shr     eax, 24
    cvtsi2ss xmm3, eax
    mulss   xmm3, [rip+ly_inv255]
    mulss   xmm3, [r8+LE_OPAC]
    test    r14d, r14d                  # (the base: opaque)
    jnz     11f
    movss   xmm3, [r8+LE_OPAC]
11: mov     eax, ecx                    # c (0..1)
    shr     eax, 16
    and     eax, 0xff
    cvtsi2ss xmm0, eax
    mulss   xmm0, [rip+ly_inv255]
    mov     eax, ecx
    shr     eax, 8
    and     eax, 0xff
    cvtsi2ss xmm1, eax
    mulss   xmm1, [rip+ly_inv255]
    and     ecx, 0xff
    cvtsi2ss xmm2, ecx
    mulss   xmm2, [rip+ly_inv255]
    mov     eax, [r8+LE_BLEND]
    cmp     eax, 1
    je      2f
    cmp     eax, 2
    je      3f
    subss   xmm0, xmm4                  # normal: out + (c - out) a
    mulss   xmm0, xmm3
    addss   xmm4, xmm0
    subss   xmm1, xmm5
    mulss   xmm1, xmm3
    addss   xmm5, xmm1
    subss   xmm2, xmm6
    mulss   xmm2, xmm3
    addss   xmm6, xmm2
    jmp     4f
2:  mulss   xmm0, xmm4                  # multiply: out + (out c - out) a
    subss   xmm0, xmm4
    mulss   xmm0, xmm3
    addss   xmm4, xmm0
    mulss   xmm1, xmm5
    subss   xmm1, xmm5
    mulss   xmm1, xmm3
    addss   xmm5, xmm1
    mulss   xmm2, xmm6
    subss   xmm2, xmm6
    mulss   xmm2, xmm3
    addss   xmm6, xmm2
    jmp     4f
3:  mulss   xmm0, xmm3                  # add: out + c a (to 1)
    addss   xmm4, xmm0
    minss   xmm4, [rip+ly_one]
    mulss   xmm1, xmm3
    addss   xmm5, xmm1
    minss   xmm5, [rip+ly_one]
    mulss   xmm2, xmm3
    addss   xmm6, xmm2
    minss   xmm6, [rip+ly_one]
4:  inc     r14d
    jmp     1b
5:  mov     eax, 0xff                   # back to 0xffRRGGBB
    mulss   xmm4, [rip+ly_255]
    addss   xmm4, [rip+ly_half]
    cvttss2si ecx, xmm4
    shl     eax, 8
    or      eax, ecx
    mulss   xmm5, [rip+ly_255]
    addss   xmm5, [rip+ly_half]
    cvttss2si ecx, xmm5
    shl     eax, 8
    or      eax, ecx
    mulss   xmm6, [rip+ly_255]
    addss   xmm6, [rip+ly_half]
    cvttss2si ecx, xmm6
    shl     eax, 8
    or      eax, ecx
    mov     [rbx+IM_DATA+r13*4], eax
9:  pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# lay_rect(rdi=image, esi=x0, edx=y0, ecx=x1, r8d=y1 (inclusive)) - the
#   composite of that box (or all: x1 < 0)
lay_rect:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rbx, rdi
    cmp     qword ptr [rbx+IM_LAYERS], 0
    je      9f
    mov     r12d, esi
    mov     r13d, edx
    mov     r14d, ecx
    mov     r15d, r8d
    test    r14d, r14d
    jns     1f
    xor     r12d, r12d
    xor     r13d, r13d
    mov     r14d, [rbx+IM_W]
    dec     r14d
    mov     r15d, [rbx+IM_H]
    dec     r15d
1:  cmp     r13d, r15d
    jg      9f
    mov     ecx, r12d
2:  cmp     ecx, r14d
    jg      3f
    push    rcx
    push    rcx
    mov     rdi, rbx
    mov     esi, ecx
    mov     edx, r13d
    call    lay_texel
    pop     rcx
    pop     rcx
    inc     ecx
    jmp     2b
3:  inc     r13d
    jmp     1b
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# lay_op(rdi=image, esi=op, edx=layer, xmm0=value) -> eax = result (-1:
#   no such layer): 0 count, 1 add (-> its number), 2 active (set), 3
#   opacity, 4 blend (0 normal 1 multiply 2 add), 5 visible (0 / 1),
#   6 remove, 7 merge (flatten, layers gone), 8 active (get)
lay_op:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 16
    movss   [rsp], xmm0
    mov     rbx, rdi
    mov     r12d, esi
    mov     r13d, edx
    cmp     r12d, 1
    jne     1f
    call    pt_hist_clear               # (strokes point at layers)
    mov     rdi, rbx
    call    lay_add
    jmp     .Llo_done
1:  mov     rcx, [rbx+IM_LAYERS]
    test    r12d, r12d
    jnz     2f
    mov     eax, 1                      # count (none: just the image)
    test    rcx, rcx
    jz      9f
    mov     eax, [rcx+LB_COUNT]
    jmp     9f
2:  cmp     r12d, 8
    jne     21f
    xor     eax, eax
    test    rcx, rcx
    jz      9f
    mov     eax, [rcx+LB_ACTIVE]
    jmp     9f
21: cmp     r12d, 7
    jne     3f
    call    pt_hist_clear
    mov     rdi, rbx                    # merge: the composite is the image
    call    lay_free
    xor     eax, eax
    jmp     .Llo_done
3:  test    rcx, rcx
    jz      8f
    test    r13d, r13d
    js      8f
    cmp     r13d, [rcx+LB_COUNT]
    jae     8f
    mov     eax, r13d
    shl     eax, 5
    lea     rdx, [rcx+LB_L+rax]
    cmp     r12d, 2
    jne     4f
    mov     [rcx+LB_ACTIVE], r13d
    mov     eax, r13d
    jmp     9f
4:  cmp     r12d, 3
    jne     5f
    movss   xmm0, [rsp]
    xorps   xmm1, xmm1
    maxss   xmm0, xmm1
    minss   xmm0, [rip+ly_one]
    movss   [rdx+LE_OPAC], xmm0
    jmp     .Llo_comp
5:  cmp     r12d, 4
    jne     6f
    cvttss2si eax, [rsp]
    cmp     eax, 2
    ja      8f
    mov     [rdx+LE_BLEND], eax
    jmp     .Llo_comp
6:  cmp     r12d, 5
    jne     7f
    cvttss2si eax, [rsp]
    test    eax, eax
    setnz   al
    movzx   eax, al
    mov     [rdx+LE_VIS], eax
    jmp     .Llo_comp
7:  cmp     r12d, 6                     # remove (not the base)
    jne     8f
    test    r13d, r13d
    jz      8f
    push    rcx
    push    rdx
    call    pt_hist_clear
    pop     rdx
    pop     rcx
    mov     rdi, [rdx+LE_PIX]
    push    rcx
    push    rdx
    call    lay_unmap
    pop     rdi                         # (the entries above move down)
    pop     rcx
    lea     rsi, [rdi+LE_SZ]
    mov     eax, [rcx+LB_COUNT]
    dec     eax
    sub     eax, r13d
    shl     eax, 5
    push    rcx
    mov     ecx, eax
    rep     movsb
    pop     rcx
    dec     dword ptr [rcx+LB_COUNT]
    mov     eax, [rcx+LB_COUNT]
    dec     eax
    cmp     [rcx+LB_ACTIVE], eax
    jbe     .Llo_comp
    mov     [rcx+LB_ACTIVE], eax
.Llo_comp:
    mov     rdi, rbx                    # all again
    xor     esi, esi
    xor     edx, edx
    mov     ecx, -1
    xor     r8d, r8d
    call    lay_rect
    xor     eax, eax
.Llo_done:
    mov     dword ptr [rbx+IM_DIRTY], 1
    push    rax
    push    rax
    call    eval_flush
    mov     dword ptr [rip+dirty], 1
    pop     rax
    pop     rax
    jmp     9f
8:  mov     eax, -1
9:  add     rsp, 16
    pop     r13
    pop     r12
    pop     rbx
    ret

# ilay_write - ILAY chunk body: per image with layers: index, count,
#   active, then per layer opacity, blend, visible, bytes, an RGBA PNG
ilay_write:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    xor     ebx, ebx
1:  cmp     ebx, [rip+img_count]
    jae     9f
    mov     edi, ebx
    call    image_ptr
    test    rax, rax
    jz      8f
    mov     r12, rax
    mov     r13, [r12+IM_LAYERS]
    test    r13, r13
    jz      8f
    mov     edi, ebx
    call    wb_u32
    mov     edi, [r13+LB_COUNT]
    call    wb_u32
    mov     edi, [r13+LB_ACTIVE]
    call    wb_u32
    xor     r14d, r14d
2:  cmp     r14d, [r13+LB_COUNT]
    jae     8f
    mov     eax, r14d
    shl     eax, 5
    lea     r15, [r13+LB_L+rax]
    mov     edi, [r15+LE_OPAC]
    call    wb_u32
    mov     edi, [r15+LE_BLEND]
    call    wb_u32
    mov     edi, [r15+LE_VIS]
    call    wb_u32
    push    qword ptr [rip+wb_len]      # (bytes: filled in after)
    push    rax
    xor     edi, edi
    call    wb_u32
    mov     rsi, [r15+LE_PIX]
    mov     edx, [r12+IM_W]
    mov     ecx, [r12+IM_H]
    mov     r8d, edx
    call    png_encode_rgba
    pop     rax
    pop     rcx
    mov     rax, [rip+wb_len]
    sub     rax, rcx
    sub     rax, 4
    mov     rdx, [rip+wb_ptr]
    mov     [rdx+rcx], eax
    inc     r14d
    jmp     2b
8:  inc     ebx
    jmp     1b
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ilay_read(rdi=data, esi=bytes) - the layers back on their images (sizes
#   must match), composited
ilay_read:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 24
    mov     r12, rdi
    lea     r13, [rdi+rsi]              # end
1:  lea     rax, [r12+12]
    cmp     rax, r13
    ja      9f
    mov     edi, [r12]
    call    image_ptr
    mov     rbx, rax
    mov     eax, [r12+4]
    mov     [rsp], eax                  # count
    mov     eax, [r12+8]
    mov     [rsp+4], eax                # active
    add     r12, 12
    test    rbx, rbx
    jz      9f
    cmp     dword ptr [rbx+IM_FMT], 0
    jne     9f
    mov     rdi, rbx                    # fresh layers
    call    lay_free
    xor     r14d, r14d
2:  cmp     r14d, [rsp]
    jae     7f
    lea     rax, [r12+16]
    cmp     rax, r13
    ja      9f
    mov     ebp, [r12+12]               # PNG bytes
    lea     rax, [r12+16+rbp]
    cmp     rax, r13
    ja      9f
    test    r14d, r14d                  # a layer (the base comes with the
    jnz     21f                         #  first add)
    mov     rdi, rbx
    call    lay_add                     # base + layer 1: drop layer 1's
    test    eax, eax                    #  pixels after
    js      9f
    mov     rcx, [rbx+IM_LAYERS]
    mov     dword ptr [rcx+LB_COUNT], 1
    mov     rdi, [rcx+LB_L+LE_SZ+LE_PIX]
    call    lay_unmap
    jmp     22f
21: mov     rdi, rbx
    call    lay_add
    test    eax, eax
    js      9f
22: mov     r15, [rbx+IM_LAYERS]
    mov     eax, r14d
    shl     eax, 5
    lea     r15, [r15+LB_L+rax]
    mov     eax, [r12]
    mov     [r15+LE_OPAC], eax
    mov     eax, [r12+4]
    mov     [r15+LE_BLEND], eax
    mov     eax, [r12+8]
    mov     [r15+LE_VIS], eax
    lea     rdi, [r12+16]               # its pixels
    mov     esi, ebp
    call    img_decode
    test    rax, rax
    jz      3f
    mov     ecx, [rax+IM_W]
    cmp     ecx, [rbx+IM_W]
    jne     23f
    mov     ecx, [rax+IM_H]
    cmp     ecx, [rbx+IM_H]
    jne     23f
    cmp     dword ptr [rax+IM_FMT], 0
    jne     23f
    mov     rdi, [r15+LE_PIX]
    lea     rsi, [rax+IM_DATA]
    mov     ecx, [rbx+IM_W]
    imul    ecx, [rbx+IM_H]
    rep     movsd
23: mov     rdi, rax
    call    img_free
3:  lea     r12, [r12+16+rbp]
    inc     r14d
    jmp     2b
7:  mov     rcx, [rbx+IM_LAYERS]
    test    rcx, rcx
    jz      1b
    mov     eax, [rsp+4]
    cmp     eax, [rcx+LB_COUNT]
    jb      71f
    xor     eax, eax
71: mov     [rcx+LB_ACTIVE], eax
    mov     rdi, rbx
    xor     esi, esi
    xor     edx, edx
    mov     ecx, -1
    xor     r8d, r8d
    call    lay_rect
    jmp     1b
9:  add     rsp, 24
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
