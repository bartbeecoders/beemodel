# =============================================================================
#  BeeModel - OpenEXR writer: scanline, half-float B, G, R, ZIP or none
#
#  ZIP blocks hold 16 lines: the bytes are split into even and odd halves,
#  delta-coded (the EXR predictor) and deflated with png.s's compressor
#  inside a zlib stream; a block that would not shrink is stored raw, as
#  the format allows.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"

.globl exr_write
.globl exr_write_image

.equ IM_W,     0
.equ IM_H,     4
.equ IM_FMT,   8
.equ IM_DATA,  64
.equ ZIP_LINES, 16

.section .rodata
exr_head:       .byte 0x76, 0x2f, 0x31, 0x01, 2, 0, 0, 0
                .ascii "channels\0chlist\0"
                .long 55
                .ascii "B\0"
                .long 1
                .byte 0, 0, 0, 0
                .long 1, 1
                .ascii "G\0"
                .long 1
                .byte 0, 0, 0, 0
                .long 1, 1
                .ascii "R\0"
                .long 1
                .byte 0, 0, 0, 0
                .long 1, 1
                .byte 0
                .ascii "compression\0compression\0"
                .long 1
exr_head_end:
exr_head2:      .ascii "lineOrder\0lineOrder\0"
                .long 1
                .byte 0
                .ascii "pixelAspectRatio\0float\0"
                .long 4
                .float 1.0
                .ascii "screenWindowCenter\0v2f\0"
                .long 8
                .float 0.0, 0.0
                .ascii "screenWindowWidth\0float\0"
                .long 4
                .float 1.0
exr_head2_end:
s_dw:           .ascii "dataWindow\0box2i\0"
                .long 16
s_dw_end:
s_dpw:          .ascii "displayWindow\0box2i\0"
                .long 16
s_dpw_end:
f_2p24:         .float 16777216.0
f_lin:          .float 0.0773993808, 0.04045, 0.0549, 1.0
f_srgb_a:       .float 0.9478672986             # 1 / 1.055
f_srgb_b:       .float 0.0521327014             # 0.055 / 1.055
f_255i:         .float 0.00392156863

.section .bss
.align 8
ex_out:         .skip 8
ex_buf:         .skip 8                 # the file being built
ex_cap:         .skip 8
ex_raw:         .skip 8                 # one block, raw
ex_tmp:         .skip 8                 # reordered
ex_z:           .skip 8                 # deflated
ex_blk:         .skip 8                 # bytes in a raw block (max)
ex_px:          .skip 8
ex_w:           .skip 4
ex_h:           .skip 4
ex_stride:      .skip 4
ex_zip:         .skip 4

.text

# half(xmm0) -> eax = IEEE half (round to nearest even)
half:
    movd    eax, xmm0
    mov     edx, eax
    shr     edx, 16
    and     edx, 0x8000                 # sign
    and     eax, 0x7fffffff
    cmp     eax, 0x7f800000
    ja      .Lh_nan
    cmp     eax, 0x477ff000             # >= 65520: infinity
    jae     .Lh_inf
    cmp     eax, 0x38800000             # below 2^-14: subnormal
    jb      .Lh_sub
    mov     ecx, eax                    # normal: rebias and round
    shr     ecx, 13
    and     ecx, 1
    lea     eax, [rax+rcx+0xfff]
    sub     eax, 0x38000000
    shr     eax, 13
    or      eax, edx
    ret
.Lh_sub:
    movd    xmm0, eax
    mulss   xmm0, [rip+f_2p24]
    cvtss2si eax, xmm0
    or      eax, edx
    ret
.Lh_inf:
    mov     eax, 0x7c00
    or      eax, edx
    ret
.Lh_nan:
    mov     eax, 0x7e00
    ret

# put(rsi=data, edx=bytes) - append to the file buffer
put:
    mov     rdi, [rip+ex_out]
    mov     ecx, edx
    rep     movsb
    mov     [rip+ex_out], rdi
    ret

# put32(edi=value)
put32:
    mov     rax, [rip+ex_out]
    mov     [rax], edi
    add     qword ptr [rip+ex_out], 4
    ret

# adler32(rsi=data, rdx=bytes) -> eax
adler32:
    mov     r8d, 1                      # a
    xor     r9d, r9d                    # b
1:  test    rdx, rdx
    jz      3f
    mov     r10, rdx                    # in runs of 5552 (no overflow)
    cmp     r10, 5552
    jbe     2f
    mov     r10d, 5552
2:  sub     rdx, r10
21: movzx   eax, byte ptr [rsi]
    inc     rsi
    add     r8d, eax
    add     r9d, r8d
    dec     r10
    jnz     21b
    push    rdx                         # (bytes left)
    mov     eax, r8d
    mov     ecx, 65521
    xor     edx, edx
    div     ecx
    mov     r8d, edx
    mov     eax, r9d
    xor     edx, edx
    div     ecx
    mov     r9d, edx
    pop     rdx
    jmp     1b
3:  mov     eax, r9d
    shl     eax, 16
    or      eax, r8d
    ret

# block(edi=first line, esi=lines) -> rsi = data, edx = bytes (raw or zip)
block:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r12d, edi
    mov     r13d, esi
    mov     rbx, [rip+ex_raw]           # raw: per line B, G, R halves
    xor     r14d, r14d                  # line
1:  cmp     r14d, r13d
    jae     5f
    mov     ecx, 2                      # channel: B, G, R (stored order)
2:  xor     r15d, r15d                  # x
3:  cmp     r15d, [rip+ex_w]
    jae     4f
    lea     eax, [r12+r14]
    imul    eax, [rip+ex_w]
    add     eax, r15d
    imul    eax, [rip+ex_stride]
    add     eax, ecx
    mov     rdx, [rip+ex_px]
    movss   xmm0, [rdx+rax*4]
    push    rcx
    call    half
    pop     rcx
    mov     [rbx], ax
    add     rbx, 2
    inc     r15d
    jmp     3b
4:  dec     ecx
    jns     2b
    inc     r14d
    jmp     1b
5:  mov     rsi, [rip+ex_raw]
    mov     rdx, rbx
    sub     rdx, rsi                    # raw bytes
    cmp     dword ptr [rip+ex_zip], 0
    je      9f
    mov     r14, rdx
    mov     rdi, [rip+ex_tmp]           # split: even bytes, then odd
    lea     r8, [r14+1]
    shr     r8, 1
    add     r8, rdi                     # the second half
    xor     ecx, ecx
6:  cmp     rcx, r14
    jae     7f
    mov     al, [rsi+rcx]
    mov     [rdi], al
    inc     rdi
    inc     rcx
    cmp     rcx, r14
    jae     7f
    mov     al, [rsi+rcx]
    mov     [r8], al
    inc     r8
    inc     rcx
    jmp     6b
7:  mov     rdi, [rip+ex_tmp]           # predictor: d[i] = t[i] - t[i-1] + 128
    movzx   edx, byte ptr [rdi]
    mov     ecx, 1
71: cmp     rcx, r14
    jae     72f
    movzx   eax, byte ptr [rdi+rcx]
    mov     r8d, eax
    sub     eax, edx
    add     eax, 128
    mov     [rdi+rcx], al
    mov     edx, r8d
    inc     rcx
    jmp     71b
72: mov     rdi, [rip+ex_z]             # zlib: 78 01, deflate, adler32
    mov     word ptr [rdi], 0x0178
    add     rdi, 2
    mov     rsi, [rip+ex_tmp]
    mov     rdx, r14
    call    deflate_buf
    mov     rbx, rax
    mov     rsi, [rip+ex_tmp]
    mov     rdx, r14
    call    adler32
    bswap   eax
    mov     [rbx], eax
    add     rbx, 4
    mov     rdx, rbx
    mov     rsi, [rip+ex_z]
    sub     rdx, rsi
    cmp     rdx, r14
    jb      9f
    mov     rsi, [rip+ex_raw]           # no gain: raw
    mov     rdx, r14
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# exr_write(rdi=path, rsi=f32 pixels, edx=w, ecx=h, r8d=floats per pixel
#   (r g b first), r9d=1 for ZIP) -> eax = 0 ok
exr_write:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r12, rdi
    mov     [rip+ex_px], rsi
    mov     [rip+ex_w], edx
    mov     [rip+ex_h], ecx
    mov     [rip+ex_stride], r8d
    mov     [rip+ex_zip], r9d
    mov     qword ptr [rip+ex_buf], 0
    mov     qword ptr [rip+ex_raw], 0
    mov     eax, edx                    # a block: 16 lines x 3 x 2 bytes x w
    imul    eax, 6*ZIP_LINES
    mov     [rip+ex_blk], rax
    lea     rdi, [rax*4+4096]           # raw, tmp, z (2x)
    call    vmap
    test    rax, rax
    jz      8f
    mov     [rip+ex_raw], rax
    mov     rcx, [rip+ex_blk]
    add     rax, rcx
    mov     [rip+ex_tmp], rax
    add     rax, rcx
    mov     [rip+ex_z], rax
    mov     eax, [rip+ex_w]             # the file: header + table + data (raw bound)
    imul    eax, [rip+ex_h]
    imul    rax, rax, 6
    mov     ecx, [rip+ex_h]
    lea     rax, [rax+rcx*8+4096]
    lea     rax, [rax+rcx*8]
    mov     [rip+ex_cap], rax
    mov     rdi, rax
    call    vmap
    test    rax, rax
    jz      8f
    mov     [rip+ex_buf], rax
    mov     [rip+ex_out], rax
    lea     rsi, [rip+exr_head]         # header
    mov     edx, exr_head_end - exr_head
    call    put
    mov     rax, [rip+ex_out]
    mov     ecx, 3
    cmp     dword ptr [rip+ex_zip], 0
    jne     1f
    xor     ecx, ecx
1:  mov     [rax], cl
    inc     qword ptr [rip+ex_out]
    lea     rsi, [rip+s_dw]
    mov     edx, s_dw_end - s_dw
    call    put
    call    put_box
    lea     rsi, [rip+s_dpw]
    mov     edx, s_dpw_end - s_dpw
    call    put_box_named
    lea     rsi, [rip+exr_head2]
    mov     edx, exr_head2_end - exr_head2
    call    put
    mov     rax, [rip+ex_out]
    mov     byte ptr [rax], 0           # end of header
    inc     rax
    mov     [rip+ex_out], rax
    mov     r13d, 1                     # lines per block
    cmp     dword ptr [rip+ex_zip], 0
    je      2f
    mov     r13d, ZIP_LINES
2:  mov     eax, [rip+ex_h]             # blocks
    add     eax, r13d
    dec     eax
    xor     edx, edx
    div     r13d
    mov     r14d, eax
    mov     r15, [rip+ex_out]           # the offset table
    lea     rax, [r15+r14*8]
    mov     [rip+ex_out], rax
    xor     ebx, ebx                    # block
3:  cmp     ebx, r14d
    jae     5f
    mov     rax, [rip+ex_out]           # its offset
    sub     rax, [rip+ex_buf]
    mov     [r15+rbx*8], rax
    mov     edi, ebx
    imul    edi, r13d                   # first line
    mov     esi, [rip+ex_h]
    sub     esi, edi
    cmp     esi, r13d
    jbe     4f
    mov     esi, r13d
4:  push    rdi
    push    rsi
    call    block
    pop     rcx
    pop     rdi
    push    rsi
    push    rdx
    call    put32                       # y
    mov     edi, [rsp]
    call    put32                       # size
    pop     rdx
    pop     rsi
    call    put
    inc     ebx
    jmp     3b
5:  mov     rdx, [rip+ex_out]
    mov     rsi, [rip+ex_buf]
    sub     rdx, rsi
    mov     rdi, r12
    call    file_write_atomic
    mov     ebx, eax
    jmp     9f
8:  mov     ebx, -12
9:  mov     rdi, [rip+ex_buf]
    mov     rsi, [rip+ex_cap]
    call    vunmap
    mov     rdi, [rip+ex_raw]
    mov     rsi, [rip+ex_blk]
    lea     rsi, [rsi*4+4096]
    call    vunmap
    mov     eax, ebx
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

put_box_named:
    call    put
# put_box - 0, 0, w - 1, h - 1
put_box:
    xor     edi, edi
    call    put32
    xor     edi, edi
    call    put32
    mov     edi, [rip+ex_w]
    dec     edi
    call    put32
    mov     edi, [rip+ex_h]
    dec     edi
    jmp     put32

# exr_write_image(rdi=path, rsi=image) -> eax = 0 ok (8-bit: sRGB decoded)
exr_write_image:
    push    rbx
    push    r12
    push    r13
    mov     r12, rdi
    mov     rbx, rsi
    cmp     dword ptr [rbx+IM_FMT], 0
    jne     5f
    mov     eax, [rbx+IM_W]             # 8-bit: to linear floats first
    imul    eax, [rbx+IM_H]
    mov     r13d, eax
    lea     rdi, [rax+rax*2]
    shl     rdi, 2
    call    vmap
    test    rax, rax
    jz      8f
    push    rax
    xor     ecx, ecx
1:  cmp     ecx, r13d
    jae     4f
    mov     edx, [rbx+IM_DATA+rcx*4]
    xor     r8d, r8d                    # channel: r g b from bits 16, 8, 0
2:  mov     r9d, edx
    push    rcx
    lea     ecx, [r8*8]
    neg     ecx
    add     ecx, 16
    shr     r9d, cl
    pop     rcx
    movzx   r9d, r9b
    cvtsi2ss xmm0, r9d
    mulss   xmm0, [rip+f_255i]
    call    srgb_lin
    lea     r9, [rcx+rcx*2]
    add     r9, r8
    movss   [rax+r9*4], xmm0
    inc     r8d
    cmp     r8d, 3
    jb      2b
    inc     ecx
    jmp     1b
4:  mov     rdi, r12
    mov     rsi, rax
    mov     edx, [rbx+IM_W]
    mov     ecx, [rbx+IM_H]
    mov     r8d, 3
    mov     r9d, 1
    call    exr_write
    mov     r12d, eax
    pop     rdi
    lea     rsi, [r13+r13*2]
    shl     rsi, 2
    call    vunmap
    mov     eax, r12d
    jmp     9f
5:  lea     rsi, [rbx+IM_DATA]
    mov     edx, [rbx+IM_W]
    mov     ecx, [rbx+IM_H]
    mov     r8d, 3
    mov     r9d, 1
    call    exr_write
    jmp     9f
8:  mov     eax, -12
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# srgb_lin(xmm0 in 0..1) -> xmm0 linear  (rax kept; x87 pow)
srgb_lin:
    comiss  xmm0, [rip+f_lin+4]
    ja      1f
    mulss   xmm0, [rip+f_lin]
    ret
1:  mulss   xmm0, [rip+f_srgb_a]        # ((c + 0.055) / 1.055)^2.4
    addss   xmm0, [rip+f_srgb_b]
    sub     rsp, 8
    movss   [rsp], xmm0
    mov     dword ptr [rsp+4], 0x4019999a  # 2.4
    fld     dword ptr [rsp+4]
    fld     dword ptr [rsp]
    fyl2x                               # 2.4 log2(x)
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

.section .note.GNU-stack,"",@progbits
