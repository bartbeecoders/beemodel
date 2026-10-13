# =============================================================================
#  BeeModel - image readers: PNG, JPEG (baseline), Radiance HDR
#
#  An image is one mapping: a 64-byte header, then the pixels.
#    IM_W, IM_H      size
#    IM_FMT          0: u32 0xAARRGGBB, sRGB (8-bit sources)
#                    1: f32 r, g, b, linear (HDR sources)
#    IM_MAPSZ        bytes mapped
#  Readers take the whole file in memory and return an image or 0, with
#  img_err saying why.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"

.globl img_alloc
.globl img_free
.globl img_decode
.globl img_err
.globl vmap
.globl vunmap

.equ IM_W,      0
.equ IM_H,      4
.equ IM_FMT,    8
.equ IM_MAPSZ,  16
.equ IM_DATA,   64
.equ MAP_ANON_PRIV, 0x22
.equ IMG_MAX,   16384                   # sides up to 16K

.section .rodata
png_magic:      .byte 0x89, 'P', 'N', 'G', 13, 10, 26, 10
e_img_format:   .asciz "unknown image format"
e_img_bad:      .asciz "damaged or unsupported file"
e_img_size:     .asciz "image too large"
e_img_mem:      .asciz "out of memory"
e_png_depth:    .asciz "unsupported PNG colour type or bit depth"
e_png_data:     .asciz "damaged PNG data"
# Adam7: x0, y0, dx, dy per pass (the last row: no interlace)
adam7:          .byte 0,0,8,8, 4,0,8,8, 0,4,4,8, 2,0,4,4, 0,2,2,4, 1,0,2,2, 0,1,1,2
plain:          .byte 0,0,1,1

.section .bss
.align 8
img_err:        .skip 8
pn_w:           .skip 4
pn_h:           .skip 4
pn_depth:       .skip 4
pn_ctype:       .skip 4
pn_inter:       .skip 4
pn_chan:        .skip 4
pn_bpp:         .skip 4                 # bytes per complete pixel (>= 1)
pn_trns:        .skip 4                 # 1 = colour key, 2 = palette alpha
pn_npal:        .skip 4
pn_key:         .skip 8                 # tRNS key: u16 gray or r, g, b
pn_pal:         .skip 4*256             # 0xAARRGGBB
pn_row:         .skip 8
pn_img:         .skip 8

.text

# vmap(rdi=bytes) -> rax = zeroed anonymous mapping or 0
vmap:
    mov     rsi, rdi
    add     rsi, 4095
    and     rsi, -4096
    xor     edi, edi
    mov     edx, PROT_RW
    mov     r10d, MAP_ANON_PRIV
    mov     r8d, -1
    xor     r9d, r9d
    mov     eax, SYS_MMAP
    syscall
    cmp     rax, -4096
    jbe     1f
    xor     eax, eax
1:  ret

# vunmap(rdi=mapping, rsi=bytes)
vunmap:
    test    rdi, rdi
    jz      1f
    add     rsi, 4095
    and     rsi, -4096
    mov     eax, SYS_MUNMAP
    syscall
1:  ret

# img_alloc(edi=w, esi=h, edx=fmt) -> rax = image or 0
img_alloc:
    push    rbx
    push    r12
    push    r13
    mov     ebx, edi
    mov     r12d, esi
    mov     r13d, edx
    lea     eax, [rdi-1]
    cmp     eax, IMG_MAX
    jae     8f
    lea     eax, [rsi-1]
    cmp     eax, IMG_MAX
    jae     8f
    mov     eax, ebx
    imul    rax, r12
    lea     rcx, [rax*4]
    test    r13d, r13d
    jz      1f
    lea     rcx, [rax+rax*2]
    shl     rcx, 2
1:  lea     rdi, [rcx+IM_DATA]
    push    rdi
    call    vmap
    pop     rdi
    test    rax, rax
    jz      7f
    mov     [rax+IM_W], ebx
    mov     [rax+IM_H], r12d
    mov     [rax+IM_FMT], r13d
    add     rdi, 4095
    and     rdi, -4096
    mov     [rax+IM_MAPSZ], rdi
    jmp     9f
7:  lea     rax, [rip+e_img_mem]
    mov     [rip+img_err], rax
    xor     eax, eax
    jmp     9f
8:  lea     rax, [rip+e_img_size]
    mov     [rip+img_err], rax
    xor     eax, eax
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# img_free(rdi=image)
img_free:
    test    rdi, rdi
    jz      1f
    mov     rsi, [rdi+IM_MAPSZ]
    mov     eax, SYS_MUNMAP
    syscall
1:  ret

# img_decode(rdi=file data, rsi=bytes) -> rax = image or 0 (img_err)
img_decode:
    cmp     rsi, 8
    jb      8f
    mov     rax, [rdi]
    cmp     rax, [rip+png_magic]
    je      png_decode
    movzx   eax, word ptr [rdi]
    cmp     eax, 0xd8ff
    je      jpeg_decode
    cmp     word ptr [rdi], 0x3f23      # "#?" RADIANCE / RGBE
    je      hdr_decode
8:  lea     rax, [rip+e_img_format]
    mov     [rip+img_err], rax
    xor     eax, eax
    ret

# be32(rsi) -> eax
.macro BE32 reg, mem
    mov     \reg, \mem
    bswap   \reg
.endm

# =============================================================================
#  PNG: every colour type and bit depth, Adam7, tRNS; 16-bit keeps the top
#  byte
# =============================================================================
png_decode:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 56
    mov     [rsp], rdi                  # file
    lea     rax, [rdi+rsi]
    mov     [rsp+8], rax                # end
    mov     qword ptr [rsp+16], 0       # IDAT bytes
    mov     qword ptr [rsp+24], 0       # IDAT buffer
    mov     qword ptr [rsp+32], 0       # raw buffer
    mov     qword ptr [rsp+40], 0       # raw size
    mov     qword ptr [rip+pn_img], 0
    mov     dword ptr [rip+pn_w], 0
    mov     dword ptr [rip+pn_trns], 0
    mov     dword ptr [rip+pn_npal], 0
    # pass 1: header, palette, transparency, IDAT size
    lea     rbx, [rdi+8]
.Lpn_c1:
    lea     rax, [rbx+12]
    cmp     rax, [rsp+8]
    ja      .Lpn_c1end
    BE32    r12d, [rbx]                 # length
    mov     r13d, [rbx+4]               # type
    lea     rax, [rbx+r12+12]
    cmp     rax, [rsp+8]
    ja      .Lpn_bad
    lea     rbp, [rbx+8]                # data
    cmp     r13d, 0x52444849            # IHDR
    jne     1f
    cmp     r12d, 13
    jb      .Lpn_bad
    BE32    eax, [rbp]
    mov     [rip+pn_w], eax
    BE32    eax, [rbp+4]
    mov     [rip+pn_h], eax
    movzx   eax, byte ptr [rbp+8]
    mov     [rip+pn_depth], eax
    movzx   eax, byte ptr [rbp+9]
    mov     [rip+pn_ctype], eax
    movzx   eax, byte ptr [rbp+12]
    mov     [rip+pn_inter], eax
    jmp     .Lpn_c1next
1:  cmp     r13d, 0x45544c50            # PLTE
    jne     2f
    mov     eax, r12d
    xor     edx, edx
    mov     ecx, 3
    div     ecx
    cmp     eax, 256
    jbe     11f
    mov     eax, 256
11: mov     [rip+pn_npal], eax
    xor     ecx, ecx
    lea     rdx, [rip+pn_pal]
12: cmp     ecx, eax
    jae     .Lpn_c1next
    lea     r8, [rcx+rcx*2]
    movzx   r9d, byte ptr [rbp+r8]
    shl     r9d, 8
    movzx   r10d, byte ptr [rbp+r8+1]
    or      r9d, r10d
    shl     r9d, 8
    movzx   r10d, byte ptr [rbp+r8+2]
    or      r9d, r10d
    or      r9d, 0xff000000
    mov     [rdx+rcx*4], r9d
    inc     ecx
    jmp     12b
2:  cmp     r13d, 0x534e5274            # tRNS
    jne     3f
    cmp     dword ptr [rip+pn_ctype], 3
    jne     21f
    mov     dword ptr [rip+pn_trns], 2  # palette alpha
    xor     ecx, ecx
    lea     rdx, [rip+pn_pal]
22: cmp     ecx, r12d
    jae     .Lpn_c1next
    cmp     ecx, 256
    jae     .Lpn_c1next
    movzx   eax, byte ptr [rbp+rcx]
    mov     byte ptr [rdx+rcx*4+3], al
    inc     ecx
    jmp     22b
21: mov     dword ptr [rip+pn_trns], 1  # colour key (u16 values)
    movzx   eax, word ptr [rbp]
    xchg    al, ah
    mov     [rip+pn_key], ax
    cmp     r12d, 6
    jb      .Lpn_c1next
    movzx   eax, word ptr [rbp+2]
    xchg    al, ah
    mov     [rip+pn_key+2], ax
    movzx   eax, word ptr [rbp+4]
    xchg    al, ah
    mov     [rip+pn_key+4], ax
    jmp     .Lpn_c1next
3:  cmp     r13d, 0x54414449            # IDAT
    jne     4f
    add     [rsp+16], r12
    jmp     .Lpn_c1next
4:  cmp     r13d, 0x444e4549            # IEND
    je      .Lpn_c1end
.Lpn_c1next:
    lea     rbx, [rbx+r12+12]
    jmp     .Lpn_c1
.Lpn_c1end:
    # the format
    mov     eax, [rip+pn_ctype]
    mov     ecx, [rip+pn_depth]
    mov     edx, 1
    cmp     eax, 0
    je      5f
    mov     edx, 3
    cmp     eax, 2
    je      51f
    mov     edx, 1
    cmp     eax, 3
    je      52f
    mov     edx, 2
    cmp     eax, 4
    je      51f
    mov     edx, 4
    cmp     eax, 6
    je      51f
    jmp     .Lpn_depth
5:  cmp     ecx, 1                      # gray: 1 2 4 8 16
    je      53f
    cmp     ecx, 2
    je      53f
    cmp     ecx, 4
    je      53f
51: cmp     ecx, 8                      # rgb, gray+a, rgba: 8 16
    je      53f
    cmp     ecx, 16
    je      53f
    jmp     .Lpn_depth
52: cmp     ecx, 16                     # palette: 1 2 4 8
    je      .Lpn_depth
    cmp     ecx, 8
    je      53f
    cmp     ecx, 4
    je      53f
    cmp     ecx, 2
    je      53f
    cmp     ecx, 1
    jne     .Lpn_depth
53: mov     [rip+pn_chan], edx
    imul    edx, ecx                    # bits per pixel
    add     edx, 7
    shr     edx, 3
    mov     [rip+pn_bpp], edx
    cmp     dword ptr [rip+pn_inter], 1
    ja      .Lpn_bad
    cmp     qword ptr [rsp+16], 0
    je      .Lpn_bad
    mov     edi, [rip+pn_w]
    mov     esi, [rip+pn_h]
    xor     edx, edx
    call    img_alloc
    test    rax, rax
    jz      .Lpn_fail
    mov     [rip+pn_img], rax
    # the raw (filtered) size over the passes
    xor     r14d, r14d                  # pass
    xor     r15, r15                    # bytes
6:  mov     edi, r14d
    call    pass_dims                   # eax = pw, edx = ph
    test    eax, eax
    jz      61f
    test    edx, edx
    jz      61f
    mov     edi, eax
    push    rdx
    call    row_bytes
    pop     rdx
    inc     eax
    imul    rax, rdx
    add     r15, rax
61: inc     r14d
    call    pass_count
    cmp     r14d, eax
    jb      6b
    mov     [rsp+40], r15
    # gather IDAT
    mov     rdi, [rsp+16]
    call    vmap
    test    rax, rax
    jz      .Lpn_mem
    mov     [rsp+24], rax
    mov     rdi, rax
    mov     rbx, [rsp]
    add     rbx, 8
7:  lea     rax, [rbx+12]
    cmp     rax, [rsp+8]
    ja      71f
    BE32    r12d, [rbx]
    cmp     dword ptr [rbx+4], 0x54414449
    jne     72f
    lea     rsi, [rbx+8]
    mov     ecx, r12d
    rep     movsb
72: cmp     dword ptr [rbx+4], 0x444e4549
    je      71f
    lea     rbx, [rbx+r12+12]
    jmp     7b
71: mov     rdi, [rsp+40]
    inc     rdi
    call    vmap
    test    rax, rax
    jz      .Lpn_mem
    mov     [rsp+32], rax
    mov     rdi, [rsp+24]
    mov     rsi, [rsp+16]
    mov     rdx, rax
    mov     rcx, [rsp+40]
    call    zlib_inflate
    cmp     rax, [rsp+40]
    jne     .Lpn_data
    # unfilter and convert, pass by pass
    mov     rbx, [rsp+32]               # raw cursor
    xor     r14d, r14d
8:  mov     edi, r14d
    call    pass_dims
    test    eax, eax
    jz      89f
    test    edx, edx
    jz      89f
    mov     [rsp+48], eax               # pw
    mov     [rsp+52], edx               # ph
    mov     edi, eax
    call    row_bytes
    mov     r12d, eax                   # row bytes
    xor     r13d, r13d                  # row
    xor     ebp, ebp                    # previous row (0 = none)
81: cmp     r13d, [rsp+52]
    jae     89f
    movzx   r8d, byte ptr [rbx]         # filter
    cmp     r8d, 4
    ja      .Lpn_data
    lea     rdi, [rbx+1]
    mov     rsi, rbp
    mov     edx, r12d
    mov     ecx, [rip+pn_bpp]
    call    unfilter
    lea     rdi, [rbx+1]
    mov     esi, r14d
    mov     edx, r13d
    mov     ecx, [rsp+48]
    call    png_row
    lea     rbp, [rbx+1]
    lea     rbx, [rbx+r12+1]
    inc     r13d
    jmp     81b
89: inc     r14d
    call    pass_count
    cmp     r14d, eax
    jb      8b
    mov     rax, [rip+pn_img]
    mov     qword ptr [rip+pn_img], 0
    jmp     .Lpn_out
.Lpn_depth:
    lea     rax, [rip+e_png_depth]
    jmp     .Lpn_err
.Lpn_data:
    lea     rax, [rip+e_png_data]
    jmp     .Lpn_err
.Lpn_mem:
    lea     rax, [rip+e_img_mem]
    jmp     .Lpn_err
.Lpn_bad:
    lea     rax, [rip+e_img_bad]
.Lpn_err:
    mov     [rip+img_err], rax
.Lpn_fail:
    xor     eax, eax
.Lpn_out:
    push    rax
    mov     rdi, [rsp+8+24]
    mov     rsi, [rsp+8+16]
    call    vunmap
    mov     rdi, [rsp+8+32]
    mov     rsi, [rsp+8+40]
    inc     rsi
    call    vunmap
    mov     rdi, [rip+pn_img]           # (an image only on failure)
    call    img_free
    pop     rax
    add     rsp, 56
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

# pass_count -> eax = 7 (interlaced) or 1
pass_count:
    mov     eax, 1
    cmp     dword ptr [rip+pn_inter], 0
    je      1f
    mov     eax, 7
1:  ret

# pass_tab(edi=pass) -> rax = x0, y0, dx, dy bytes
pass_tab:
    lea     rax, [rip+plain]
    cmp     dword ptr [rip+pn_inter], 0
    je      1f
    lea     rax, [rip+adam7]
    lea     rax, [rax+rdi*4]
1:  ret

# pass_dims(edi=pass) -> eax = width, edx = height of the pass
pass_dims:
    call    pass_tab
    mov     r8, rax
    movzx   ecx, byte ptr [r8+2]        # (w - x0 + dx - 1) / dx
    mov     eax, [rip+pn_w]
    movzx   edx, byte ptr [r8]
    sub     eax, edx
    jle     8f
    add     eax, ecx
    dec     eax
    xor     edx, edx
    div     ecx
    push    rax
    movzx   ecx, byte ptr [r8+3]
    mov     eax, [rip+pn_h]
    movzx   edx, byte ptr [r8+1]
    sub     eax, edx
    jle     7f
    add     eax, ecx
    dec     eax
    xor     edx, edx
    div     ecx
    mov     edx, eax
    pop     rax
    ret
7:  pop     rax
8:  xor     eax, eax
    xor     edx, edx
    ret

# row_bytes(edi=pixels) -> eax = ceil(pixels * channels * depth / 8)
row_bytes:
    mov     eax, edi
    imul    eax, [rip+pn_chan]
    imul    eax, [rip+pn_depth]
    add     eax, 7
    shr     eax, 3
    ret

# unfilter(rdi=row, rsi=previous or 0, edx=bytes, ecx=bpp, r8d=filter)
unfilter:
    test    r8d, r8d
    jz      9f
    push    rbx
    push    r12
    mov     r9, rdi
    xor     r10d, r10d                  # i
1:  cmp     r10d, edx
    jae     8f
    xor     eax, eax                    # a = left
    xor     r11d, r11d                  # b = up
    xor     ebx, ebx                    # c = up-left
    cmp     r10d, ecx
    jb      2f
    mov     r12d, r10d
    sub     r12d, ecx
    movzx   eax, byte ptr [r9+r12]
    test    rsi, rsi
    jz      2f
    movzx   ebx, byte ptr [rsi+r12]
2:  test    rsi, rsi
    jz      3f
    movzx   r11d, byte ptr [rsi+r10]
3:  cmp     r8d, 2
    jb      4f                          # 1 Sub: a
    je      41f                         # 2 Up: b
    cmp     r8d, 3
    jne     42f
    add     eax, r11d                   # 3 Average
    shr     eax, 1
    jmp     4f
41: mov     eax, r11d
    jmp     4f
42: push    rcx                         # 4 Paeth
    push    rdx
    mov     ecx, eax                    # p = a + b - c
    add     ecx, r11d
    sub     ecx, ebx
    mov     edx, ecx                    # pa = |p - a|
    sub     edx, eax
    mov     r12d, edx
    neg     r12d
    cmovl   r12d, edx
    mov     edx, ecx                    # pb = |p - b|
    sub     edx, r11d
    mov     edi, edx
    neg     edi
    cmovl   edi, edx
    sub     ecx, ebx                    # pc = |p - c|
    mov     edx, ecx
    neg     edx
    cmovl   edx, ecx
    cmp     r12d, edi                   # pa <= pb && pa <= pc: a
    ja      43f
    cmp     r12d, edx
    jbe     44f
43: cmp     edi, edx                    # pb <= pc: b, else c
    mov     eax, r11d
    jbe     44f
    mov     eax, ebx
44: pop     rdx
    pop     rcx
4:  add     [r9+r10], al
    inc     r10d
    jmp     1b
8:  pop     r12
    pop     rbx
9:  ret

# sample(rdi=row, esi=index) -> eax = the raw sample (full depth)
sample:
    mov     ecx, [rip+pn_depth]
    cmp     ecx, 8
    jne     1f
    movzx   eax, byte ptr [rdi+rsi]
    ret
1:  ja      2f
    imul    esi, ecx                    # bit position
    mov     eax, esi
    shr     eax, 3
    movzx   eax, byte ptr [rdi+rax]
    and     esi, 7
    add     esi, ecx
    neg     esi
    add     esi, 8                      # shift = 8 - depth - (pos & 7)
    xchg    ecx, esi
    shr     eax, cl
    mov     ecx, esi
    mov     edx, 1
    shl     edx, cl
    dec     edx
    and     eax, edx
    ret
2:  movzx   eax, word ptr [rdi+rsi*2]   # 16-bit, big-endian
    xchg    al, ah
    ret

# to8(eax=raw sample) -> eax = 8-bit value
to8:
    mov     ecx, [rip+pn_depth]
    cmp     ecx, 8
    je      9f
    ja      1f
    cmp     ecx, 4
    je      4f
    cmp     ecx, 2
    je      2f
    imul    eax, eax, 255
    ret
2:  imul    eax, eax, 85
    ret
4:  imul    eax, eax, 17
    ret
1:  shr     eax, 8
9:  ret

# png_row(rdi=unfiltered row, esi=pass, edx=row in pass, ecx=pixels)
png_row:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 24
    mov     rbx, rdi
    mov     [rsp+8], ecx
    mov     edi, esi
    call    pass_tab
    mov     r15, rax
    movzx   eax, byte ptr [r15+3]       # y = y0 + row dy
    imul    eax, edx
    movzx   ecx, byte ptr [r15+1]
    add     eax, ecx
    imul    eax, [rip+pn_w]
    mov     rbp, [rip+pn_img]
    lea     rbp, [rbp+IM_DATA+rax*4]    # image row
    xor     r12d, r12d                  # i
1:  cmp     r12d, [rsp+8]
    jae     9f
    mov     r13d, r12d                  # first sample index
    imul    r13d, [rip+pn_chan]
    mov     eax, [rip+pn_ctype]
    cmp     eax, 3
    je      .Lpr_pal
    cmp     eax, 2
    je      .Lpr_rgb
    cmp     eax, 6
    je      .Lpr_rgb
    # gray (+ alpha)
    mov     rdi, rbx
    mov     esi, r13d
    call    sample
    mov     r14d, eax                   # raw gray
    call    to8
    mov     edx, eax
    imul    edx, 0x010101
    or      edx, 0xff000000
    mov     [rsp], edx
    cmp     dword ptr [rip+pn_ctype], 4
    jne     2f
    mov     rdi, rbx
    lea     esi, [r13+1]
    call    sample
    call    to8
    shl     eax, 24
    and     dword ptr [rsp], 0xffffff
    or      [rsp], eax
    jmp     .Lpr_put
2:  cmp     dword ptr [rip+pn_trns], 1  # key
    jne     .Lpr_put
    movzx   eax, word ptr [rip+pn_key]
    cmp     eax, r14d
    jne     .Lpr_put
    and     dword ptr [rsp], 0xffffff
    jmp     .Lpr_put
.Lpr_rgb:
    xor     r14d, r14d                  # 8-bit rgb
    mov     dword ptr [rsp+4], 1        # matches the key so far
    xor     ecx, ecx
3:  push    rcx
    mov     rdi, rbx
    lea     esi, [r13+rcx]
    call    sample
    pop     rcx
    lea     rdx, [rip+pn_key]
    movzx   edx, word ptr [rdx+rcx*2]
    cmp     eax, edx
    je      31f
    mov     dword ptr [rsp+4], 0
31: push    rcx
    call    to8
    pop     rcx
    shl     r14d, 8
    or      r14d, eax
    inc     ecx
    cmp     ecx, 3
    jb      3b
    or      r14d, 0xff000000
    cmp     dword ptr [rip+pn_ctype], 6
    jne     32f
    mov     rdi, rbx
    lea     esi, [r13+3]
    call    sample
    call    to8
    shl     eax, 24
    and     r14d, 0xffffff
    or      r14d, eax
    jmp     33f
32: cmp     dword ptr [rip+pn_trns], 1
    jne     33f
    cmp     dword ptr [rsp+4], 0
    je      33f
    and     r14d, 0xffffff
33: mov     [rsp], r14d
    jmp     .Lpr_put
.Lpr_pal:
    mov     rdi, rbx
    mov     esi, r13d
    call    sample
    mov     edx, 0xff000000
    cmp     eax, [rip+pn_npal]
    jae     4f
    lea     rcx, [rip+pn_pal]
    mov     edx, [rcx+rax*4]
4:  mov     [rsp], edx
.Lpr_put:
    movzx   eax, byte ptr [r15+2]       # x = x0 + i dx
    imul    eax, r12d
    movzx   ecx, byte ptr [r15]
    add     eax, ecx
    mov     edx, [rsp]
    mov     [rbp+rax*4], edx
    inc     r12d
    jmp     1b
9:  add     rsp, 24
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

# =============================================================================
#  Radiance HDR (RGBE): new-style RLE scanlines or flat pixels; -Y / +Y
#  orientation with +X (other layouts are refused)
# =============================================================================
# hdr_line(rsi=cursor) -> rsi after the line (0 at the end), the line in rcx
hdr_line:
    mov     rcx, rsi
1:  cmp     rsi, [rip+hd_end]
    jae     8f
    cmp     byte ptr [rsi], 10
    je      2f
    inc     rsi
    jmp     1b
2:  inc     rsi
    ret
8:  xor     esi, esi
    ret

# hdr_num(rsi) -> eax = unsigned number after spaces, rsi after it
hdr_num:
    xor     eax, eax
1:  cmp     byte ptr [rsi], ' '
    jne     2f
    inc     rsi
    jmp     1b
2:  movzx   ecx, byte ptr [rsi]
    sub     ecx, '0'
    cmp     ecx, 9
    ja      3f
    imul    eax, eax, 10
    add     eax, ecx
    cmp     eax, 1 << 20
    ja      3f
    inc     rsi
    jmp     2b
3:  ret

hdr_decode:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 24
    lea     rax, [rdi+rsi]
    mov     [rip+hd_end], rax
    mov     rsi, rdi
    xor     ebx, ebx                    # format seen
1:  call    hdr_line                    # header lines up to an empty one
    test    rsi, rsi
    jz      .Lhd_bad
    mov     rax, rsi
    sub     rax, rcx
    cmp     rax, 1
    je      2f
    cmp     dword ptr [rcx], 0x4d524f46 # "FORM"
    jne     1b
    cmp     dword ptr [rcx+7], 0x622d3233   # "32-b": FORMAT=32-bit_rle_rgbe
    jne     .Lhd_bad
    mov     ebx, 1
    jmp     1b
2:  mov     r8, rsi                     # "-Y h +X w"
    call    hdr_line
    test    rsi, rsi
    jz      .Lhd_bad
    mov     r14, rsi                    # pixel data
    mov     rsi, r8
    movzx   eax, word ptr [rsi]
    mov     r15d, 0                     # 0: top-down, 1: bottom-up
    cmp     eax, 0x592d                 # "-Y"
    je      3f
    cmp     eax, 0x592b                 # "+Y"
    jne     .Lhd_bad
    mov     r15d, 1
3:  add     rsi, 2
    call    hdr_num
    mov     r13d, eax                   # height
    cmp     byte ptr [rsi], ' '
    jne     .Lhd_bad
    inc     rsi
    cmp     word ptr [rsi], 0x582b      # "+X"
    jne     .Lhd_bad
    add     rsi, 2
    call    hdr_num
    mov     r12d, eax                   # width
    mov     edi, r12d
    mov     esi, r13d
    mov     edx, 1
    call    img_alloc
    test    rax, rax
    jz      .Lhd_fail
    mov     [rsp], rax
    mov     edi, r12d                   # a line of RGBE bytes
    shl     edi, 2
    call    vmap
    test    rax, rax
    jz      .Lhd_mem
    mov     [rsp+8], rax
    xor     ebp, ebp                    # row
.Lhd_row:
    cmp     ebp, r13d
    jae     .Lhd_done
    mov     rdi, [rsp+8]
    mov     rax, [rip+hd_end]
    sub     rax, r14
    cmp     r12d, 8                     # new RLE? 2 2 hi lo (lo/hi = width)
    jb      .Lhd_flat
    cmp     r12d, 0x7fff
    ja      .Lhd_flat
    cmp     rax, 4
    jb      .Lhd_short
    cmp     word ptr [r14], 0x0202
    jne     .Lhd_flat
    movzx   eax, byte ptr [r14+2]
    shl     eax, 8
    movzx   ecx, byte ptr [r14+3]
    or      eax, ecx
    cmp     eax, r12d
    jne     .Lhd_bad2
    add     r14, 4
    xor     r8d, r8d                    # channel (stored planar: r, g, b, e)
4:  xor     r9d, r9d                    # x
5:  cmp     r9d, r12d
    jae     7f
    cmp     r14, [rip+hd_end]
    jae     .Lhd_short
    movzx   eax, byte ptr [r14]
    inc     r14
    cmp     eax, 128
    jbe     6f
    sub     eax, 128                    # a run
    lea     ecx, [r9+rax]
    cmp     ecx, r12d
    ja      .Lhd_bad2
    cmp     r14, [rip+hd_end]
    jae     .Lhd_short
    movzx   r10d, byte ptr [r14]
    inc     r14
51: lea     ecx, [r9*4+r8]
    mov     [rdi+rcx], r10b
    inc     r9d
    dec     eax
    jnz     51b
    jmp     5b
6:  test    eax, eax                    # literals
    jz      .Lhd_bad2
    lea     ecx, [r9+rax]
    cmp     ecx, r12d
    ja      .Lhd_bad2
    mov     rcx, [rip+hd_end]
    sub     rcx, r14
    cmp     rcx, rax
    jb      .Lhd_short
61: movzx   r10d, byte ptr [r14]
    inc     r14
    lea     ecx, [r9*4+r8]
    mov     [rdi+rcx], r10b
    inc     r9d
    dec     eax
    jnz     61b
    jmp     5b
7:  inc     r8d
    cmp     r8d, 4
    jb      4b
    jmp     .Lhd_convert
.Lhd_flat:
    mov     ecx, r12d
    shl     ecx, 2
    cmp     rax, rcx
    jb      .Lhd_short
    mov     rsi, r14
    rep     movsb
    mov     r14, rsi
.Lhd_convert:
    mov     eax, ebp                    # the image row
    test    r15d, r15d
    jz      8f
    mov     eax, r13d
    sub     eax, ebp
    dec     eax
8:  imul    eax, r12d
    lea     rax, [rax+rax*2]
    mov     rdx, [rsp]
    lea     rdx, [rdx+IM_DATA+rax*4]
    mov     rsi, [rsp+8]
    xor     r9d, r9d
9:  cmp     r9d, r12d
    jae     .Lhd_rownext
    movzx   eax, byte ptr [rsi+r9*4+3]  # 2^(e - 136) as float bits
    sub     eax, 9
    xorps   xmm1, xmm1
    jle     91f
    shl     eax, 23
    movd    xmm1, eax
91: xor     ecx, ecx
    lea     r10, [rsi+r9*4]
92: movzx   eax, byte ptr [r10+rcx]
    cvtsi2ss xmm0, eax
    mulss   xmm0, xmm1
    movss   [rdx+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      92b
    add     rdx, 12
    inc     r9d
    jmp     9b
.Lhd_rownext:
    inc     ebp
    jmp     .Lhd_row
.Lhd_done:
    mov     rdi, [rsp+8]
    mov     esi, r12d
    shl     esi, 2
    call    vunmap
    mov     rax, [rsp]
    jmp     .Lhd_out
.Lhd_short:
.Lhd_bad2:
    mov     rdi, [rsp+8]
    mov     esi, r12d
    shl     esi, 2
    call    vunmap
.Lhd_mem:
    mov     rdi, [rsp]
    call    img_free
.Lhd_bad:
    lea     rax, [rip+e_img_bad]
    mov     [rip+img_err], rax
.Lhd_fail:
    xor     eax, eax
.Lhd_out:
    add     rsp, 24
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

.section .bss
hd_end:         .skip 8
.text

.section .note.GNU-stack,"",@progbits
