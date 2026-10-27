# =============================================================================
#  BeeModel - landscapes in and out: heightmaps, meshes, tiles.
#
#  landscape.import reads a PNG (grey, grey + alpha, RGB or RGBA; 8 or 16
#  bits: the first channel, 0..1) or an OpenEXR file (scanlines; no, ZIPS or
#  ZIP compression; half, float or uint; its Y channel, else R, else the
#  first) into a new landscape of 2^k + 1 samples a side (the image
#  resampled unless it is that size) with one Heightmap layer: base +
#  value x height metres (EXR: the values as metres x height, default 1).
#  landscape.export writes the heights as a 16-bit grey PNG (the range
#  lowest..highest; a PNG made so round-trips exactly) or a float EXR (the
#  heights in metres), or the splat map as RGBA PNGs (paint layers 1-4, and
#  5-8 in <name>_2.png). landscape.to_mesh makes it a plain mesh (the
#  display grid, or every sample). landscape.tiles splits it into k x k
#  landscapes (the heights baked into each tile's Heightmap layer, the
#  paint copied) that world partition streams like any cell's objects.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"
.include "landscape.inc"

.section .rodata
.align 4
li_inv255:      .float 0.003921569
li_inv65535:    .float 1.5259022e-5
li_65535:       .float 65535.0
li_half:        .float 0.5
li_one:         .float 1.0
li_100:         .float 100.0
li_tiny:        .float 1.0e-12
png_magic:      .byte 0x89, 'P', 'N', 'G', 13, 10, 26, 10
k_li_size:      .asciz "size"
k_li_height:    .asciz "height"
k_li_base:      .asciz "base"
k_li_splat:     .asciz "splat"
k_li_full:      .asciz "full"
k_li_png:       .asciz ".png"
k_li_exr:       .asciz ".exr"
k_li_2:         .asciz "_2.png"
s_li_land:      .asciz "Landscape"
s_li_y:         .asciz "Y"
s_li_r:         .asciz "R"
s_li_bad:       .asciz "  landscape: not understood: "
s_li_read:      .asciz "  landscape.import: cannot read (a PNG or an OpenEXR heightmap): "
s_li_wfail:     .asciz "  landscape.export: could not write "
s_li_mem:       .asciz "  landscape: out of memory"
s_li_imp:       .asciz "  imported a heightmap: "
s_li_x:         .asciz " x "
s_li_exp:       .asciz "  exported "
s_li_tiles:     .asciz "  landscape split into tiles: "
s_li_ntiles:    .asciz "  landscape.tiles <k>: k divides the samples a side less 1 (tiles of 65 samples at least)"
s_li_full:      .asciz "  landscape.to_mesh full: 2049 samples a side at most"
# an EXR header for a float Y channel, no compression (box2i filled in)
exr_hdr:        .byte 0x76, 0x2f, 0x31, 0x01, 2, 0, 0, 0
                .ascii "channels\0chlist\0"
                .long 19
                .ascii "Y\0"
                .long 2
                .byte 0, 0, 0, 0
                .long 1, 1
                .byte 0
                .ascii "compression\0compression\0"
                .long 1
                .byte 0
                .ascii "dataWindow\0box2i\0"
                .long 16
exr_hdr_dw:     .long 0, 0, 0, 0
                .ascii "displayWindow\0box2i\0"
                .long 16
exr_hdr_vw:     .long 0, 0, 0, 0
                .ascii "lineOrder\0lineOrder\0"
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
                .byte 0
exr_hdr_end:
s_chlist:       .asciz "channels"
s_compr:        .asciz "compression"
s_dwin:         .asciz "dataWindow"

OPERATOR op_la_import, "landscape.import", "Import Heightmap", do_la_import, flags=OPF_UNDO, form=form_laimp, doc="A landscape from a heightmap: landscape.import <file.png|file.exr> [size metres (1 a sample)] [height metres (PNG: 100; EXR: 1 x its values)] [base metres]. 16-bit PNGs (grey or colour: the first channel) and OpenEXR scanline files (Y, else R); 2^k + 1 samples a side, or resampled to it"
OPERATOR op_la_export, "landscape.export", "Export Heightmap", do_la_export, flags=0, form=form_laexp, doc="The active landscape's heights to a file: landscape.export <file.png> (16-bit grey, lowest..highest) | <file.exr> (float metres); landscape.export <file.png> splat - its paint (RGBA: paint layers 1-4; 5-8 in <file>_2.png)"
OPERATOR op_la_tomesh, "landscape.to_mesh", "Landscape to Mesh", do_la_tomesh, flags=OPF_AI_SAFE|OPF_UNDO, doc="Make the active landscape a plain mesh: landscape.to_mesh (the display grid) | landscape.to_mesh full (every sample, up to 2049 a side)"
OPERATOR op_la_tiles, "landscape.tiles", "Landscape Tiles", do_la_tiles, flags=OPF_AI_SAFE|OPF_UNDO, form=form_latiles, doc="Split the active landscape into k x k landscapes (its heights baked into each, its paint copied): landscape.tiles <k> - so world partition streams them by cell"

.section .bss
.align 8
li_img:         .skip 8                 # a decoded image: f32 w x h,
li_imgsz:       .skip 8
li_w:           .skip 4
li_h:           .skip 4
li_tmp:         .skip 8                 # scratch mappings
li_tmpsz:       .skip 8
li_tmp2:        .skip 8
li_tmp2sz:      .skip 8
li_args:        .skip 16                # size, height, base, (flags)
li_path:        .skip 520
.text

# li_map(rsi=bytes) -> rax = zeroed mapping, or 0
li_map:
    xor     edi, edi
    add     rsi, 4095
    and     rsi, -4096
    mov     edx, PROT_RW
    mov     r10d, MAP_ANON_PRIV
    mov     r8d, -1
    xor     r9d, r9d
    call    plat_mmap
    cmp     rax, -4096
    jbe     1f
    xor     eax, eax
1:  ret
# li_unmap(rdi=mapping or 0, rsi=bytes)
li_unmap:
    test    rdi, rdi
    jz      1f
    add     rsi, 4095
    and     rsi, -4096
    call    plat_munmap
1:  ret

# li_be32(rdi=bytes) -> eax (big-endian)
li_be32:
    mov     eax, [rdi]
    bswap   eax
    ret

# li_img_new(edi=w, esi=h) -> rax = li_img (zeroed f32 w x h), or 0
li_img_new:
    mov     [rip+li_w], edi
    mov     [rip+li_h], esi
    mov     eax, edi
    imul    rax, rsi
    shl     rax, 2
    mov     [rip+li_imgsz], rax
    mov     rsi, rax
    call    li_map
    mov     [rip+li_img], rax
    ret

# =============================================================================
#  PNG
# =============================================================================
# li_png(rdi=file, rsi=bytes) -> eax = 1: li_img from its first channel
li_png:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 56                     # +0 w, +4 h, +8 depth, +12 colour,
    mov     r12, rdi                    #  +16 IDAT bytes, +24 channels, +28
    mov     r13, rsi                    #  bytes a pixel, +32 stride
    cmp     r13, 33
    jb      .Lpg_fail
    mov     rax, [r12]
    cmp     rax, [rip+png_magic]
    jne     .Lpg_fail
    mov     rsi, r13                    # the IDATs, together
    call    li_map
    test    rax, rax
    jz      .Lpg_fail
    mov     [rip+li_tmp], rax
    mov     [rip+li_tmpsz], r13
    mov     qword ptr [rsp+16], 0
    mov     dword ptr [rsp], 0
    lea     rbx, [r12+8]
1:  lea     rax, [rbx+12]
    lea     rcx, [r12+r13]
    cmp     rax, rcx
    ja      2f
    mov     rdi, rbx
    call    li_be32
    mov     r14d, eax                   # length
    lea     rax, [rbx+12+r14]
    cmp     rax, rcx
    ja      2f
    mov     eax, [rbx+4]
    cmp     eax, 0x52444849             # IHDR
    jne     11f
    lea     rdi, [rbx+8]
    call    li_be32
    mov     [rsp], eax
    lea     rdi, [rbx+12]
    call    li_be32
    mov     [rsp+4], eax
    movzx   eax, byte ptr [rbx+16]
    mov     [rsp+8], eax
    movzx   eax, byte ptr [rbx+17]
    mov     [rsp+12], eax
    cmp     byte ptr [rbx+20], 0        # (interlaced: no)
    jne     .Lpg_fail
    jmp     19f
11: cmp     eax, 0x54414449             # IDAT
    jne     12f
    lea     rsi, [rbx+8]
    mov     rdi, [rip+li_tmp]
    add     rdi, [rsp+16]
    mov     ecx, r14d
    rep     movsb
    add     [rsp+16], r14
    jmp     19f
12: cmp     eax, 0x444e4549             # IEND
    je      2f
19: lea     rbx, [rbx+12+r14]
    jmp     1b
2:  mov     eax, [rsp]                  # sizes
    test    eax, eax
    jz      .Lpg_fail
    cmp     eax, 16384
    ja      .Lpg_fail
    mov     eax, [rsp+4]
    test    eax, eax
    jz      .Lpg_fail
    cmp     eax, 16384
    ja      .Lpg_fail
    mov     eax, [rsp+8]
    cmp     eax, 8
    je      21f
    cmp     eax, 16
    jne     .Lpg_fail
21: mov     eax, [rsp+12]               # channels: 0 1, 2 3, 4 2, 6 4
    mov     ecx, 1
    cmp     eax, 0
    je      22f
    mov     ecx, 3
    cmp     eax, 2
    je      22f
    mov     ecx, 2
    cmp     eax, 4
    je      22f
    mov     ecx, 4
    cmp     eax, 6
    jne     .Lpg_fail
22: mov     [rsp+24], ecx
    mov     eax, [rsp+8]
    shr     eax, 3
    imul    eax, ecx
    mov     [rsp+28], eax               # bytes a pixel
    imul    eax, [rsp]
    mov     [rsp+32], eax               # stride
    inc     eax
    mov     ecx, [rsp+4]
    imul    rax, rcx
    mov     [rsp+40], rax               # the rows, filtered
    lea     rsi, [rax+64]
    call    li_map
    test    rax, rax
    jz      .Lpg_fail
    mov     [rip+li_tmp2], rax
    mov     rcx, [rsp+40]
    add     rcx, 64
    mov     [rip+li_tmp2sz], rcx
    mov     rdi, [rip+li_tmp]
    mov     rsi, [rsp+16]
    mov     rdx, rax
    mov     rcx, [rip+li_tmp2sz]
    call    zlib_inflate
    cmp     rax, [rsp+40]
    jne     .Lpg_fail
    mov     edi, [rsp]
    mov     esi, [rsp+4]
    call    li_img_new
    test    rax, rax
    jz      .Lpg_fail
    xor     r15d, r15d                  # unfilter each row, take channel 0
    mov     rbx, [rip+li_tmp2]
    xor     ebp, ebp                    # (the previous row: none)
3:  cmp     r15d, [rsp+4]
    jae     .Lpg_ok
    movzx   r14d, byte ptr [rbx]        # its filter
    lea     r13, [rbx+1]                # the row
    xor     ecx, ecx
4:  cmp     ecx, [rsp+32]
    jae     5f
    xor     eax, eax                    # a: left, b: up, c: up-left
    mov     edx, ecx
    sub     edx, [rsp+28]
    js      41f
    movzx   eax, byte ptr [r13+rdx]
41: xor     r8d, r8d
    xor     r9d, r9d
    test    rbp, rbp
    jz      43f
    movzx   r8d, byte ptr [rbp+rcx]
    test    edx, edx
    js      43f
    movzx   r9d, byte ptr [rbp+rdx]
43: movzx   r10d, byte ptr [r13+rcx]
    cmp     r14d, 1
    jne     44f
    add     r10d, eax
    jmp     49f
44: cmp     r14d, 2
    jne     45f
    add     r10d, r8d
    jmp     49f
45: cmp     r14d, 3
    jne     46f
    lea     r11d, [rax+r8]
    shr     r11d, 1
    add     r10d, r11d
    jmp     49f
46: cmp     r14d, 4
    jne     49f
    push    rcx                         # Paeth
    lea     r11d, [rax+r8]
    sub     r11d, r9d                   # p = a + b - c
    mov     ecx, r11d
    sub     ecx, eax
    mov     edx, ecx
    neg     edx
    cmovs   edx, ecx                    # pa
    mov     ecx, r11d
    sub     ecx, r8d
    mov     esi, ecx
    neg     esi
    cmovs   esi, ecx                    # pb
    mov     ecx, r11d
    sub     ecx, r9d
    mov     edi, ecx
    neg     edi
    cmovs   edi, ecx                    # pc
    mov     ecx, eax                    # pa <= pb, pa <= pc: a
    cmp     edx, esi
    ja      461f
    cmp     edx, edi
    jbe     462f
461:mov     ecx, r8d                    # pb <= pc: b, else c
    cmp     esi, edi
    jbe     462f
    mov     ecx, r9d
462:add     r10d, ecx
    pop     rcx
49: mov     [r13+rcx], r10b
    inc     ecx
    jmp     4b
5:  mov     rdi, [rip+li_img]           # channel 0 of each pixel
    mov     eax, r15d
    imul    eax, [rsp]
    lea     rdi, [rdi+rax*4]
    xor     ecx, ecx
6:  cmp     ecx, [rsp]
    jae     7f
    mov     eax, ecx
    imul    eax, [rsp+28]
    cmp     dword ptr [rsp+8], 16
    je      61f
    movzx   eax, byte ptr [r13+rax]
    cvtsi2ss xmm0, eax
    mulss   xmm0, [rip+li_inv255]
    jmp     62f
61: movzx   edx, byte ptr [r13+rax]
    shl     edx, 8
    movzx   eax, byte ptr [r13+rax+1]
    or      eax, edx
    cvtsi2ss xmm0, eax
    mulss   xmm0, [rip+li_inv65535]
62: movss   [rdi+rcx*4], xmm0
    inc     ecx
    jmp     6b
7:  mov     rbp, r13                    # this row: the next one's above
    mov     eax, [rsp+32]
    lea     rbx, [r13+rax]
    inc     r15d
    jmp     3b
.Lpg_ok:
    mov     eax, 1
    jmp     .Lpg_out
.Lpg_fail:
    xor     eax, eax
.Lpg_out:
    push    rax
    mov     rdi, [rip+li_tmp]
    mov     rsi, [rip+li_tmpsz]
    call    li_unmap
    mov     rdi, [rip+li_tmp2]
    mov     rsi, [rip+li_tmp2sz]
    call    li_unmap
    mov     qword ptr [rip+li_tmp], 0
    mov     qword ptr [rip+li_tmp2], 0
    pop     rax
    add     rsp, 56
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  OpenEXR
# =============================================================================
# li_h2f(ax=half) -> xmm0
li_h2f:
    movzx   eax, ax
    mov     ecx, eax
    and     ecx, 0x8000
    shl     ecx, 16                     # sign
    mov     edx, eax
    shr     edx, 10
    and     edx, 31                     # exponent
    and     eax, 0x3ff                  # mantissa
    test    edx, edx
    jnz     2f
    test    eax, eax                    # zero / subnormal: m 2^-24
    jz      1f
    cvtsi2ss xmm0, eax
    mov     eax, 0x33800000             # 2^-24
    movd    xmm1, eax
    mulss   xmm0, xmm1
    movd    eax, xmm0
    or      eax, ecx
    movd    xmm0, eax
    ret
1:  movd    xmm0, ecx
    ret
2:  cmp     edx, 31
    jne     3f
    or      ecx, 0x7f800000             # inf / nan
    shl     eax, 13
    or      eax, ecx
    movd    xmm0, eax
    ret
3:  add     edx, 112                    # 127 - 15
    shl     edx, 23
    shl     eax, 13
    or      eax, edx
    or      eax, ecx
    movd    xmm0, eax
    ret

# li_exr(rdi=file, rsi=bytes) -> eax = 1: li_img from Y (else R, else the
#   first channel)
li_exr:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 120                    # +0 channels, +4 the chosen one, +8
    mov     r12, rdi                    #  its byte offset in a line, +12 its
    mov     r13, rsi                    #  type, +16 bytes a line (all), +20
    cmp     r13, 16                     #  compression, +24 x0 y0 x1 y1, +40
    jb      .Lex_fail                   #  w, +44 h, +48 lines a block, +56
    cmp     dword ptr [r12], 0x01312f76 #  types (8), +88 sizes (8)
    jne     .Lex_fail
    test    dword ptr [r12+4], 0x1e00   # (tiled, long names, deep, parts: no)
    jnz     .Lex_fail
    mov     dword ptr [rsp], 0
    mov     dword ptr [rsp+4], -1
    mov     dword ptr [rsp+20], 0
    mov     dword ptr [rsp+40], 0
    lea     rbx, [r12+8]                # the attributes
.Lex_attr:
    lea     rcx, [r12+r13]
    cmp     rbx, rcx
    jae     .Lex_fail
    cmp     byte ptr [rbx], 0           # the end of the header
    je      .Lex_hdone
    mov     r14, rbx                    # its name
1:  cmp     rbx, rcx
    jae     .Lex_fail
    cmp     byte ptr [rbx], 0
    je      2f
    inc     rbx
    jmp     1b
2:  inc     rbx                         # its type
3:  cmp     rbx, rcx
    jae     .Lex_fail
    cmp     byte ptr [rbx], 0
    je      4f
    inc     rbx
    jmp     3b
4:  inc     rbx
    lea     rax, [rbx+4]
    cmp     rax, rcx
    ja      .Lex_fail
    mov     r15d, [rbx]                 # its size
    add     rbx, 4
    lea     rax, [rbx+r15]
    cmp     rax, rcx
    ja      .Lex_fail
    mov     rdi, r14
    lea     rsi, [rip+s_chlist]
    call    str_eq
    test    eax, eax
    jz      .Lex_a2
    mov     rbp, rbx                    # channels: name, type, plinear,
    lea     r8, [rbx+r15]               #  3 reserved, xs, ys
.Lex_ch:
    cmp     rbp, r8
    jae     .Lex_anext
    cmp     byte ptr [rbp], 0
    je      .Lex_anext
    mov     r9, rbp
5:  cmp     rbp, r8
    jae     .Lex_fail
    cmp     byte ptr [rbp], 0
    je      6f
    inc     rbp
    jmp     5b
6:  inc     rbp
    mov     eax, [rsp]
    cmp     eax, 8
    jae     .Lex_fail
    mov     ecx, [rbp]                  # its type: 0 uint, 1 half, 2 float
    cmp     ecx, 2
    ja      .Lex_fail
    mov     [rsp+56+rax*4], ecx
    mov     edx, 4
    cmp     ecx, 1
    jne     61f
    mov     edx, 2
61: mov     [rsp+88+rax*4], edx
    mov     dl, [r9]                    # Y (a name of one letter) first,
    cmp     byte ptr [r9+1], 0          #  else R, else the first
    jne     65f
    cmp     dl, 'Y'
    jne     62f
    mov     [rsp+4], eax
    jmp     65f
62: cmp     dl, 'R'
    jne     65f
    cmp     dword ptr [rsp+4], -1
    jne     65f
    mov     [rsp+4], eax
    or      dword ptr [rsp+4], 0x100    # (R: until a Y comes)
65: inc     dword ptr [rsp]
    add     rbp, 16
    jmp     .Lex_ch
.Lex_a2:
    mov     rdi, r14
    lea     rsi, [rip+s_compr]
    call    str_eq
    test    eax, eax
    jz      .Lex_a3
    movzx   eax, byte ptr [rbx]
    mov     [rsp+20], eax
    jmp     .Lex_anext
.Lex_a3:
    mov     rdi, r14
    lea     rsi, [rip+s_dwin]
    call    str_eq
    test    eax, eax
    jz      .Lex_anext
    mov     rax, [rbx]
    mov     [rsp+24], rax
    mov     rax, [rbx+8]
    mov     [rsp+32], rax
.Lex_anext:
    add     rbx, r15
    jmp     .Lex_attr
.Lex_hdone:
    inc     rbx                         # the offset table follows
    cmp     dword ptr [rsp], 0
    je      .Lex_fail
    mov     eax, [rsp+4]                # the channel (none named: the first)
    cmp     eax, -1
    jne     7f
    xor     eax, eax
7:  and     eax, 0xff
    mov     [rsp+4], eax
    xor     ecx, ecx                    # its offset in a line (per pixel:
    xor     edx, edx                    #  channels' sizes before it)
71: cmp     ecx, eax
    jae     72f
    add     edx, [rsp+88+rcx*4]
    inc     ecx
    jmp     71b
72: mov     [rsp+8], edx
    mov     ecx, [rsp+56+rax*4]
    mov     [rsp+12], ecx
    xor     ecx, ecx                    # a pixel's bytes (all channels)
    xor     edx, edx
73: cmp     ecx, [rsp]
    jae     74f
    add     edx, [rsp+88+rcx*4]
    inc     ecx
    jmp     73b
74: mov     eax, [rsp+32]               # w, h
    sub     eax, [rsp+24]
    inc     eax
    mov     [rsp+40], eax
    imul    edx, eax
    mov     [rsp+16], edx               # bytes a line
    mov     eax, [rsp+36]
    sub     eax, [rsp+28]
    inc     eax
    mov     [rsp+44], eax
    cmp     dword ptr [rsp+40], 0
    jle     .Lex_fail
    cmp     dword ptr [rsp+40], 16384
    jg      .Lex_fail
    cmp     dword ptr [rsp+44], 0
    jle     .Lex_fail
    cmp     dword ptr [rsp+44], 16384
    jg      .Lex_fail
    mov     dword ptr [rsp+48], 1       # lines a block: none, ZIPS 1, ZIP 16
    mov     eax, [rsp+20]
    cmp     eax, 3
    jne     75f
    mov     dword ptr [rsp+48], 16
    jmp     76f
75: cmp     eax, 2
    ja      .Lex_fail
    cmp     eax, 1                      # (RLE: no)
    je      .Lex_fail
76: mov     edi, [rsp+40]
    mov     esi, [rsp+44]
    call    li_img_new
    test    rax, rax
    jz      .Lex_fail
    mov     eax, [rsp+16]               # a block's room: lines x bytes
    imul    eax, [rsp+48]
    lea     rsi, [rax*2+64]
    mov     [rip+li_tmpsz], rsi
    call    li_map
    test    rax, rax
    jz      .Lex_fail
    mov     [rip+li_tmp], rax
    mov     rsi, [rip+li_tmpsz]
    mov     [rip+li_tmp2sz], rsi
    call    li_map
    test    rax, rax
    jz      .Lex_fail
    mov     [rip+li_tmp2], rax
    mov     eax, [rsp+44]               # blocks: their offsets
    add     eax, [rsp+48]
    dec     eax
    xor     edx, edx
    div     dword ptr [rsp+48]
    mov     r14d, eax                   # how many
    mov     [rsp+52], eax
    mov     r15, rbx                    # the table
    xor     ebp, ebp
.Lex_block:
    cmp     ebp, [rsp+52]
    jae     .Lex_ok
    lea     rax, [r15+rbp*8+8]
    lea     rcx, [r12+r13]
    cmp     rax, rcx
    ja      .Lex_fail
    mov     rbx, [r15+rbp*8]            # y, size, data
    lea     rax, [rbx+8]
    cmp     rax, r13
    ja      .Lex_fail
    add     rbx, r12
    mov     r14d, [rbx]                 # its first line
    sub     r14d, [rsp+28]
    mov     ecx, [rbx+4]
    lea     rax, [rbx+8+rcx]
    lea     rdx, [r12+r13]
    cmp     rax, rdx
    ja      .Lex_fail
    mov     eax, [rsp+44]               # its lines (the last block: fewer)
    sub     eax, r14d
    cmp     eax, [rsp+48]
    jbe     77f
    mov     eax, [rsp+48]
77: mov     [rsp+64+32], eax            # (+96)
    imul    eax, [rsp+16]
    mov     [rsp+100], eax              # its raw bytes
    lea     rsi, [rbx+8]                # raw already, or inflated
    cmp     dword ptr [rsp+20], 0
    je      8f
    cmp     ecx, eax                    # (stored when it did not shrink)
    je      8f
    lea     rdi, [rbx+8]
    mov     esi, ecx
    mov     rdx, [rip+li_tmp]
    mov     rcx, [rip+li_tmpsz]
    call    zlib_inflate
    mov     ecx, [rsp+100]
    cmp     rax, rcx
    jne     .Lex_fail
    mov     rsi, [rip+li_tmp]           # the predictor: t[i] += t[i-1] - 128
    mov     ecx, 1
78: cmp     ecx, [rsp+100]
    jae     79f
    movzx   eax, byte ptr [rsi+rcx-1]
    movzx   edx, byte ptr [rsi+rcx]
    add     eax, edx
    sub     eax, 128
    mov     [rsi+rcx], al
    inc     ecx
    jmp     78b
79: mov     rdi, [rip+li_tmp2]          # interleave: out[2i] = t[i],
    mov     ecx, [rsp+100]              #  out[2i+1] = t[(n+1)/2 + i]
    inc     ecx
    shr     ecx, 1
    xor     edx, edx
791:mov     eax, edx
    shr     eax, 1
    test    edx, 1
    jz      792f
    add     eax, ecx
792:movzx   eax, byte ptr [rsi+rax]
    mov     [rdi+rdx], al
    inc     edx
    cmp     edx, [rsp+100]
    jb      791b
    mov     rsi, [rip+li_tmp2]
8:  xor     r9d, r9d                    # each line: the channel's row
81: cmp     r9d, [rsp+96]
    jae     89f
    mov     eax, r9d
    imul    eax, [rsp+16]
    lea     r10, [rsi+rax]              # the line
    mov     eax, [rsp+8]                # the channel's row: the sizes of
    imul    eax, [rsp+40]               #  those before it x w
    add     r10, rax
    mov     eax, r14d
    add     eax, r9d
    imul    eax, [rsp+40]
    mov     rdi, [rip+li_img]
    lea     rdi, [rdi+rax*4]
    xor     ecx, ecx
82: cmp     ecx, [rsp+40]
    jae     88f
    mov     eax, [rsp+12]
    cmp     eax, 1
    jne     83f
    movzx   eax, word ptr [r10+rcx*2]
    push    rcx
    call    li_h2f
    pop     rcx
    jmp     85f
83: cmp     eax, 2
    jne     84f
    movss   xmm0, [r10+rcx*4]
    jmp     85f
84: mov     eax, [r10+rcx*4]            # uint
    cvtsi2ss xmm0, rax
85: movss   [rdi+rcx*4], xmm0
    inc     ecx
    jmp     82b
88: inc     r9d
    jmp     81b
89: inc     ebp
    jmp     .Lex_block
.Lex_ok:
    mov     eax, 1
    jmp     .Lex_out
.Lex_fail:
    xor     eax, eax
.Lex_out:
    push    rax
    mov     rdi, [rip+li_tmp]
    mov     rsi, [rip+li_tmpsz]
    call    li_unmap
    mov     rdi, [rip+li_tmp2]
    mov     rsi, [rip+li_tmp2sz]
    call    li_unmap
    mov     qword ptr [rip+li_tmp], 0
    mov     qword ptr [rip+li_tmp2], 0
    pop     rax
    add     rsp, 120
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Operators
# =============================================================================
# li_word_path(rsi=text) -> li_path (the first word), rsi past it, eax = 1
li_word_path:
    push    rbx
    call    im_next_word
    mov     rbx, rsi
    test    eax, eax
    jz      9f
    cmp     eax, 511
    ja      8f
    lea     rsi, [rip+im_word]
    lea     rdi, [rip+li_path]
    lea     ecx, [rax+1]
    rep     movsb
    mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  mov     rsi, rbx
    pop     rbx
    ret

# li_ext(rsi=extension) -> eax = 1 if li_path ends in it
li_ext:
    push    rbx
    mov     rbx, rsi
    lea     rdi, [rip+li_path]
    call    str_len
    mov     ecx, eax
    mov     rdi, rbx
    call    str_len
    cmp     ecx, eax
    jb      8f
    sub     ecx, eax
    lea     rdi, [rip+li_path]
    add     rdi, rcx
    mov     rsi, rbx
    call    str_eq
    jmp     9f
8:  xor     eax, eax
9:  pop     rbx
    ret

# do_la_import - landscape.import <file> [size s] [height h] [base b]
do_la_import:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 32
    mov     dword ptr [rip+li_args], 0          # size (0: a metre a sample)
    mov     dword ptr [rip+li_args+4], 0        # height (0: the default)
    mov     dword ptr [rip+li_args+8], 0        # base
    mov     rsi, [rip+op_arg]
    call    li_word_path
    test    eax, eax
    jz      .Lim_bad
    mov     r12, rsi
1:  mov     rsi, r12
    call    im_next_word
    mov     r12, rsi
    test    eax, eax
    jz      3f
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_li_size]
    call    str_eq
    xor     ebx, ebx
    test    eax, eax
    jnz     2f
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_li_height]
    call    str_eq
    mov     ebx, 4
    test    eax, eax
    jnz     2f
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_li_base]
    call    str_eq
    mov     ebx, 8
    test    eax, eax
    jz      .Lim_bad
2:  mov     rsi, r12
    call    la_num
    mov     r12, rsi
    test    eax, eax
    jz      .Lim_bad
    lea     rax, [rip+li_args]
    movss   [rax+rbx], xmm0
    jmp     1b
3:  lea     rdi, [rip+li_path]          # read and decode
    call    path_expand
    lea     rdi, [rip+path_buf]
    call    file_read
    test    rax, rax
    jz      .Lim_read
    mov     r14, rax
    mov     r15, rdx
    mov     qword ptr [rip+li_img], 0
    mov     rdi, r14
    mov     rsi, r15
    call    li_png
    mov     r13d, 1                     # (1: a PNG's 0..1)
    test    eax, eax
    jnz     4f
    mov     rdi, r14
    mov     rsi, r15
    call    li_exr
    xor     r13d, r13d
4:  push    rax
    mov     rdi, r14
    mov     rsi, r15
    call    li_unmap
    pop     rax
    test    eax, eax
    jz      .Lim_read
    mov     eax, [rip+li_w]             # the samples: 2^k + 1 >= the side
    cmp     eax, [rip+li_h]
    cmovb   eax, [rip+li_h]
    mov     ecx, 65
5:  cmp     ecx, eax
    jae     51f
    cmp     ecx, 4097
    jae     51f
    lea     ecx, [rcx*2-1]
    jmp     5b
51: mov     ebx, ecx
    xor     edi, edi
    mov     esi, ebx
    mov     edx, 2
    call    la_make
    test    rax, rax
    jz      .Lim_mem
    mov     r12, rax
    lea     eax, [rbx-1]                # size: a metre a sample, or given
    cvtsi2ss xmm0, eax
    movss   xmm1, [rip+li_args]
    xorps   xmm2, xmm2
    comiss  xmm1, xmm2
    jbe     52f
    movaps  xmm0, xmm1
52: movss   [r12+LB_SIZE], xmm0
    mov     dword ptr [r12+LB_NL], 1    # one Heightmap layer
    lea     rdi, [r12+LB_LAY]
    mov     dword ptr [rdi+LY_TYPE], 6
    mov     dword ptr [rdi+LY_FLG], 0
    mov     eax, [rip+li_one]
    mov     [rdi+LY_STR], eax
    mov     rax, [rip+lv_extra]
    mov     [rdi+LY_DATA], rax
    movss   xmm0, [rip+li_args+4]       # the height: PNG 100, EXR 1 (as
    xorps   xmm1, xmm1                  #  given otherwise)
    comiss  xmm0, xmm1
    ja      53f
    movss   xmm0, [rip+li_one]
    test    r13d, r13d
    jz      53f
    movss   xmm0, [rip+li_100]
53: movss   [rsp], xmm0
    mov     rdi, [r12+LB_LAY+LY_DATA]   # the samples: the image (resampled
    add     rdi, r12                    #  when not that size)
    mov     rsi, [rip+li_img]
    cmp     [rip+li_w], ebx
    jne     6f
    cmp     [rip+li_h], ebx
    jne     6f
    mov     eax, ebx
    imul    rax, rax
    mov     rcx, rax
    jmp     7f
6:  push    rdi
    push    rdi
    mov     rsi, [rip+li_img]           # (non-square: stretched to a square)
    mov     edx, [rip+li_w]
    mov     ecx, [rip+li_h]
    mov     r8d, ebx
    call    li_resample
    pop     rdi
    pop     rdi
    mov     rsi, rdi
    mov     eax, ebx
    imul    rax, rax
    mov     rcx, rax
7:  test    rcx, rcx                    # base + value x height
    jz      8f
    dec     rcx
    movss   xmm0, [rsi+rcx*4]
    mulss   xmm0, [rsp]
    addss   xmm0, [rip+li_args+8]
    movss   [rdi+rcx*4], xmm0
    jmp     7b
8:  mov     rdi, [rip+li_img]
    mov     rsi, [rip+li_imgsz]
    call    li_unmap
    mov     qword ptr [rip+li_img], 0
    mov     rdi, r12
    xor     esi, esi
    call    la_eval
    mov     rdi, r12
    xor     esi, esi
    call    la_display
    mov     r13, rax
    mov     rdi, r12
    call    la_unref
    test    r13, r13
    jz      .Lim_mem
    mov     edi, OT_MESH
    lea     rsi, [rip+s_li_land]
    mov     rdx, r13
    call    obj_new
    test    eax, eax
    jz      9f
    mov     r14d, eax
    mov     edi, eax
    xor     esi, esi
    call    obj_click_select
    call    fmt_reset
    lea     rdi, [rip+s_li_imp]
    call    fmt_str
    mov     edi, ebx
    call    fmt_int
    lea     rdi, [rip+s_li_x]
    call    fmt_str
    mov     edi, ebx
    call    fmt_int
    lea     rdi, [rip+fmt_buf]
    call    log_line
    jmp     9f
.Lim_bad:
    lea     rdi, [rip+s_li_bad]
    mov     rsi, [rip+op_arg]
    call    log_pair
    jmp     9f
.Lim_read:
    mov     rdi, [rip+li_img]
    mov     rsi, [rip+li_imgsz]
    call    li_unmap
    mov     qword ptr [rip+li_img], 0
    lea     rdi, [rip+s_li_read]
    lea     rsi, [rip+li_path]
    call    log_pair
    jmp     9f
.Lim_mem:
    lea     rdi, [rip+s_li_mem]
    call    log_line
9:  add     rsp, 32
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# li_resample(rsi=f32 w x h, edx=w, ecx=h, rdi=out n x n, r8d=n) - bilinear
li_resample:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    mov     r12, rsi
    mov     r13d, edx
    mov     r14d, ecx
    mov     r15, rdi
    mov     [rsp], r8d
    lea     eax, [r8-1]
    cvtsi2ss xmm6, eax                  # (n - 1)
    xor     ebx, ebx
1:  cmp     ebx, [rsp]
    jae     9f
    xor     r9d, r9d
2:  cmp     r9d, [rsp]
    jae     8f
    cvtsi2ss xmm0, r9d                  # x = i (w - 1) / (n - 1)
    lea     eax, [r13-1]
    cvtsi2ss xmm1, eax
    mulss   xmm0, xmm1
    divss   xmm0, xmm6
    cvtsi2ss xmm2, ebx
    lea     eax, [r14-1]
    cvtsi2ss xmm1, eax
    mulss   xmm2, xmm1
    divss   xmm2, xmm6
    cvttss2si r10d, xmm0
    lea     eax, [r13-2]
    test    eax, eax
    jns     21f
    xor     eax, eax
21: cmp     r10d, eax
    cmovg   r10d, eax
    cvttss2si r11d, xmm2
    lea     eax, [r14-2]
    test    eax, eax
    jns     22f
    xor     eax, eax
22: cmp     r11d, eax
    cmovg   r11d, eax
    cvtsi2ss xmm1, r10d
    subss   xmm0, xmm1                  # u
    cvtsi2ss xmm1, r11d
    subss   xmm2, xmm1                  # v
    mov     eax, r11d
    imul    eax, r13d
    add     eax, r10d
    mov     ecx, 1                      # (one column / row: no step)
    cmp     r13d, 1
    ja      23f
    xor     ecx, ecx
23: mov     edx, r13d
    cmp     r14d, 1
    ja      24f
    xor     edx, edx
24: movss   xmm3, [r12+rax*4]
    lea     r8d, [rax+rcx]
    movss   xmm4, [r12+r8*4]
    lea     r8d, [rax+rdx]
    movss   xmm5, [r12+r8*4]
    add     r8d, ecx
    movss   xmm7, [r12+r8*4]
    subss   xmm4, xmm3
    mulss   xmm4, xmm0
    addss   xmm3, xmm4
    subss   xmm7, xmm5
    mulss   xmm7, xmm0
    addss   xmm5, xmm7
    subss   xmm5, xmm3
    mulss   xmm5, xmm2
    addss   xmm3, xmm5
    mov     eax, ebx
    imul    eax, [rsp]
    add     eax, r9d
    movss   [r15+rax*4], xmm3
    inc     r9d
    jmp     2b
8:  inc     ebx
    jmp     1b
9:  add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# li_write(rdi=path) -> eax = 0 when wb went out to it
li_write:
    push    rbx
    mov     rbx, rdi
    call    path_expand
    lea     rdi, [rip+path_buf]
    mov     rsi, [rip+wb_ptr]
    mov     rdx, [rip+wb_len]
    call    file_write_atomic
    pop     rbx
    ret

# do_la_export - landscape.export <file.png|file.exr> [splat]
do_la_export:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 32
    call    la_active
    test    rax, rax
    jz      9f
    mov     r15, rdx                    # the block
    mov     rsi, [rip+op_arg]
    call    li_word_path
    test    eax, eax
    jz      .Lxp_bad
    mov     r12, rsi
    mov     dword ptr [rsp], 0          # splat?
    mov     rsi, r12
    call    im_next_word
    test    eax, eax
    jz      1f
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_li_splat]
    call    str_eq
    test    eax, eax
    jz      .Lxp_bad
    mov     dword ptr [rsp], 1
1:  mov     ebx, [r15+LB_N]
    cmp     dword ptr [rsp], 0
    jne     .Lxp_splat
    lea     rsi, [rip+k_li_exr]
    call    li_ext
    test    eax, eax
    jnz     .Lxp_exr
    lea     rsi, [rip+k_li_png]
    call    li_ext
    test    eax, eax
    jz      .Lxp_bad
    # ---- a 16-bit grey PNG: lowest..highest -> 0..65535 ---------------------
    lea     eax, [rbx*2+1]              # rows: a filter byte, then big-endian
    imul    rax, rbx                    #  u16s
    mov     [rsp+8], rax
    mov     rsi, rax
    call    li_map
    test    rax, rax
    jz      .Lxp_mem
    mov     r13, rax
    movss   xmm6, [r15+LB_HMIN]
    movss   xmm7, [r15+LB_HMAX]
    subss   xmm7, xmm6
    maxss   xmm7, [rip+li_tiny]
    mov     r14, [r15+LB_H]
    add     r14, r15
    xor     r8d, r8d                    # row
2:  cmp     r8d, ebx
    jae     4f
    lea     eax, [rbx*2+1]
    imul    eax, r8d
    lea     rdi, [r13+rax]
    mov     byte ptr [rdi], 0
    xor     ecx, ecx
3:  cmp     ecx, ebx
    jae     31f
    mov     eax, r8d
    imul    eax, ebx
    add     eax, ecx
    movss   xmm0, [r14+rax*4]
    subss   xmm0, xmm6
    divss   xmm0, xmm7
    mulss   xmm0, [rip+li_65535]
    addss   xmm0, [rip+li_half]
    cvttss2si eax, xmm0
    test    eax, eax
    jns     32f
    xor     eax, eax
32: cmp     eax, 65535
    jbe     33f
    mov     eax, 65535
33: mov     [rdi+rcx*2+2], al
    mov     [rdi+rcx*2+1], ah
    inc     ecx
    jmp     3b
31: inc     r8d
    jmp     2b
4:  call    wb_reset
    mov     rsi, r13
    mov     rdx, [rsp+8]
    mov     ecx, ebx
    mov     r8d, ebx
    mov     r9d, 16                     # 16 bits, grey
    call    png_raw
    mov     r12d, eax
    mov     rdi, r13
    mov     rsi, [rsp+8]
    call    li_unmap
    test    r12d, r12d
    jz      .Lxp_mem
    lea     rdi, [rip+li_path]
    call    li_write
    test    eax, eax
    jnz     .Lxp_fail
    jmp     .Lxp_done
.Lxp_exr:
    # ---- a float EXR: Y, no compression ----------------------------------------
    call    wb_reset
    lea     eax, [rbx-1]
    mov     [rip+exr_dw_tmp+8], eax
    mov     [rip+exr_dw_tmp+12], eax
    lea     rsi, [rip+exr_hdr]          # the header (dataWindow and
    lea     rdx, [rip+exr_hdr_dw]       #  displayWindow: 0 0 n-1 n-1)
    sub     rdx, rsi
    call    wb_bytes
    lea     rsi, [rip+exr_dw_tmp]
    mov     edx, 16
    call    wb_bytes
    lea     rsi, [rip+exr_hdr_dw+16]
    lea     rdx, [rip+exr_hdr_vw]
    sub     rdx, rsi
    call    wb_bytes
    lea     rsi, [rip+exr_dw_tmp]
    mov     edx, 16
    call    wb_bytes
    lea     rsi, [rip+exr_hdr_vw+16]
    lea     rdx, [rip+exr_hdr_end]
    sub     rdx, rsi
    call    wb_bytes
    mov     r12, [rip+wb_len]           # the offset table: each line
    mov     eax, ebx
    lea     r13, [r12+rax*8]            # (the first line's place)
    xor     r8d, r8d
5:  cmp     r8d, ebx
    jae     6f
    lea     eax, [rbx*4+8]
    imul    rax, r8
    add     rax, r13
    push    r8
    push    r8
    mov     rdi, rax
    call    wb_u64
    pop     r8
    pop     r8
    inc     r8d
    jmp     5b
6:  mov     r14, [r15+LB_H]
    add     r14, r15
    xor     r8d, r8d
7:  cmp     r8d, ebx
    jae     8f
    push    r8
    push    r8
    mov     edi, r8d
    call    wb_u32
    lea     edi, [rbx*4]
    call    wb_u32
    mov     r8, [rsp]
    mov     eax, r8d
    imul    eax, ebx
    lea     rsi, [r14+rax*4]
    lea     edx, [rbx*4]
    call    wb_bytes
    pop     r8
    pop     r8
    inc     r8d
    jmp     7b
8:  lea     rdi, [rip+li_path]
    call    li_write
    test    eax, eax
    jnz     .Lxp_fail
    jmp     .Lxp_done
.Lxp_splat:
    # ---- the splat map: RGBA 8-bit, layers 1-4 (and 5-8: <file>_2.png) ------
    cmp     qword ptr [r15+LB_SPLAT], 0
    je      .Lxp_bad
    mov     dword ptr [rsp+4], 0        # (which half)
.Lxp_sp:
    lea     eax, [rbx*4+1]
    imul    rax, rbx
    mov     [rsp+8], rax
    mov     rsi, rax
    call    li_map
    test    rax, rax
    jz      .Lxp_mem
    mov     r13, rax
    mov     r14, [r15+LB_SPLAT]
    add     r14, r15
    xor     r8d, r8d
51: cmp     r8d, ebx
    jae     53f
    lea     eax, [rbx*4+1]
    imul    eax, r8d
    lea     rdi, [r13+rax]
    mov     byte ptr [rdi], 0
    xor     ecx, ecx
52: cmp     ecx, ebx
    jae     521f
    mov     eax, r8d
    imul    eax, ebx
    add     eax, ecx
    lea     rsi, [r14+rax*8]
    mov     eax, [rsp+4]
    mov     eax, [rsi+rax*4]
    mov     [rdi+rcx*4+1], eax
    inc     ecx
    jmp     52b
521:inc     r8d
    jmp     51b
53: call    wb_reset
    mov     rsi, r13
    mov     rdx, [rsp+8]
    mov     ecx, ebx
    mov     r8d, ebx
    mov     r9d, 8 | 6 << 8             # 8 bits, RGBA
    call    png_raw
    mov     r12d, eax
    mov     rdi, r13
    mov     rsi, [rsp+8]
    call    li_unmap
    test    r12d, r12d
    jz      .Lxp_mem
    lea     rdi, [rip+li_path]
    call    li_write
    test    eax, eax
    jnz     .Lxp_fail
    cmp     dword ptr [rsp+4], 0        # paint layers past 4: the second file
    jne     .Lxp_done
    cmp     dword ptr [r15+LB_NP], 4
    jbe     .Lxp_done
    lea     rdi, [rip+li_path]          # <file>.png -> <file>_2.png
    call    str_len
    cmp     eax, 4
    jb      .Lxp_done
    lea     rdi, [rip+li_path]
    lea     rdi, [rdi+rax-4]
    lea     rsi, [rip+k_li_2]
    mov     ecx, 7
    rep     movsb
    mov     dword ptr [rsp+4], 1
    jmp     .Lxp_sp
.Lxp_done:
    lea     rdi, [rip+s_li_exp]
    lea     rsi, [rip+li_path]
    call    log_pair
    jmp     9f
.Lxp_bad:
    lea     rdi, [rip+s_li_bad]
    mov     rsi, [rip+op_arg]
    call    log_pair
    jmp     9f
.Lxp_fail:
    lea     rdi, [rip+s_li_wfail]
    lea     rsi, [rip+li_path]
    call    log_pair
    jmp     9f
.Lxp_mem:
    lea     rdi, [rip+s_li_mem]
    call    log_line
9:  add     rsp, 32
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# wb_u64(rdi)
wb_u64:
    push    rdi
    call    wb_u32
    pop     rdi
    shr     rdi, 32
    jmp     wb_u32

# do_la_tomesh - landscape.to_mesh [full]: a plain mesh
do_la_tomesh:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 16
    call    la_active
    test    rax, rax
    jz      9f
    mov     rbx, rax
    mov     r12, rdx
    mov     rsi, [rip+op_arg]
    call    im_next_word
    test    eax, eax
    jz      1f
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_li_full]
    call    str_eq
    test    eax, eax
    jz      1f
    cmp     dword ptr [r12+LB_N], 2049  # every sample
    ja      .Ltm_big
    mov     edi, [r12+LB_N]
    dec     edi
    call    prim_grid_n
    test    rax, rax
    jz      9f
    mov     r13, rax
    mov     rsi, [r13+ME_POS]
    mov     rdx, [r12+LB_H]
    add     rdx, r12
    movss   xmm5, [r12+LB_SIZE]         # cell, half
    mov     eax, [r12+LB_N]
    dec     eax
    cvtsi2ss xmm6, eax
    divss   xmm5, xmm6
    movss   xmm4, [r12+LB_SIZE]
    mulss   xmm4, [rip+li_half]
    xor     r8d, r8d
2:  cmp     r8d, [r12+LB_N]
    jae     4f
    xor     r9d, r9d
3:  cmp     r9d, [r12+LB_N]
    jae     31f
    mov     eax, r8d
    imul    eax, [r12+LB_N]
    add     eax, r9d
    cvtsi2ss xmm0, r9d
    mulss   xmm0, xmm5
    subss   xmm0, xmm4
    movss   [rsi], xmm0
    mov     ecx, [rdx+rax*4]
    mov     [rsi+4], ecx
    cvtsi2ss xmm0, r8d
    mulss   xmm0, xmm5
    subss   xmm0, xmm4
    movss   [rsi+8], xmm0
    add     rsi, 12
    inc     r9d
    jmp     3b
31: inc     r8d
    jmp     2b
4:  mov     rdi, r13
    call    mesh_bbox
    mov     rdi, r12                    # (painted: its colours)
    mov     rsi, r13
    call    ls_vcol
    jmp     5f
1:  mov     rdi, [rbx+OB_MESH]          # the display grid as it is (a copy
    call    mesh_copy                   #  is a plain mesh)
    test    rax, rax
    jz      9f
    mov     r13, rax
5:  mov     rdi, [rbx+OB_MESH]
    mov     [rbx+OB_MESH], r13
    call    mesh_unref
    mov     dword ptr [rip+dirty], 1
    jmp     9f
.Ltm_big:
    lea     rdi, [rip+s_li_full]
    call    log_line
9:  add     rsp, 16
    pop     r13
    pop     r12
    pop     rbx
    ret

# do_la_tiles - landscape.tiles <k>: k x k landscapes in its place
do_la_tiles:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 72                     # +0 k, +4 tile samples, +8 tile
    call    la_active                   #  size, +12 a, +16 b, +24 object
    test    rax, rax
    jz      9f
    mov     [rsp+24], rax
    mov     rbx, rdx
    mov     rsi, [rip+op_arg]
    call    la_num
    test    eax, eax
    jz      .Ltl_bad
    cvttss2si eax, xmm0
    cmp     eax, 2
    jl      .Ltl_bad
    mov     [rsp], eax
    mov     ecx, eax
    mov     eax, [rbx+LB_N]
    dec     eax
    xor     edx, edx
    div     ecx
    test    edx, edx
    jnz     .Ltl_bad
    cmp     eax, 64
    jb      .Ltl_bad
    inc     eax
    mov     [rsp+4], eax
    movss   xmm0, [rbx+LB_SIZE]
    cvtsi2ss xmm1, dword ptr [rsp]
    divss   xmm0, xmm1
    movss   [rsp+8], xmm0
    mov     dword ptr [rsp+16], 0       # b (z)
1:  mov     eax, [rsp+16]
    cmp     eax, [rsp]
    jae     8f
    mov     dword ptr [rsp+12], 0       # a (x)
2:  mov     eax, [rsp+12]
    cmp     eax, [rsp]
    jae     7f
    xor     edx, edx                    # a block: one Heightmap layer, the
    cmp     qword ptr [rbx+LB_SPLAT], 0 #  paint
    je      21f
    mov     edx, 1
21: or      edx, 2
    xor     edi, edi
    mov     esi, [rsp+4]
    call    la_make
    test    rax, rax
    jz      .Ltl_mem
    mov     r12, rax
    lea     rsi, [rbx+LB_PAINT]         # the paint layers
    lea     rdi, [r12+LB_PAINT]
    mov     ecx, LP_SZ*LA_MAXP
    rep     movsb
    mov     eax, [rbx+LB_NP]
    mov     [r12+LB_NP], eax
    mov     eax, [rbx+LB_DISP]
    mov     [r12+LB_DISP], eax
    mov     eax, [rsp+8]
    mov     [r12+LB_SIZE], eax
    mov     dword ptr [r12+LB_NL], 1
    lea     rdi, [r12+LB_LAY]
    mov     dword ptr [rdi+LY_TYPE], 6
    mov     dword ptr [rdi+LY_FLG], 0
    mov     eax, [rip+li_one]
    mov     [rdi+LY_STR], eax
    mov     rax, [rip+lv_extra]
    mov     [rdi+LY_DATA], rax
    mov     r13, rax                    # the heights (and paint) under it
    add     r13, r12
    mov     r14, [rbx+LB_H]
    add     r14, rbx
    xor     r8d, r8d
3:  cmp     r8d, [rsp+4]
    jae     5f
    xor     r9d, r9d
4:  cmp     r9d, [rsp+4]
    jae     41f
    mov     eax, [rsp+16]               # the sample in the landscape
    mov     ecx, [rsp+4]
    dec     ecx
    imul    eax, ecx
    add     eax, r8d
    imul    eax, [rbx+LB_N]
    mov     edx, [rsp+12]
    imul    edx, ecx
    add     edx, r9d
    add     eax, edx
    mov     r10d, r8d                   # in the tile
    imul    r10d, [rsp+4]
    add     r10d, r9d
    mov     ecx, [r14+rax*4]
    mov     [r13+r10*4], ecx
    cmp     qword ptr [rbx+LB_SPLAT], 0
    je      42f
    mov     rcx, [rbx+LB_SPLAT]
    add     rcx, rbx
    mov     rcx, [rcx+rax*8]
    mov     rdx, [r12+LB_SPLAT]
    add     rdx, r12
    mov     [rdx+r10*8], rcx
42: inc     r9d
    jmp     4b
41: inc     r8d
    jmp     3b
5:  mov     rdi, r12
    xor     esi, esi
    call    la_eval
    mov     rdi, r12
    xor     esi, esi
    call    la_display
    mov     r15, rax
    mov     rdi, r12
    call    la_unref
    test    r15, r15
    jz      .Ltl_mem
    mov     edi, OT_MESH
    lea     rsi, [rip+s_li_land]
    mov     rdx, r15
    call    obj_new
    test    eax, eax
    jz      .Ltl_mem
    mov     edi, eax
    call    obj_get
    mov     rcx, [rsp+24]               # its place: the landscape's + the
    lea     rsi, [rcx+OB_LOC]           #  tile's centre (scaled)
    lea     rdi, [rax+OB_LOC]
    mov     ecx, 36                     # (location, rotation, scale)
    rep     movsb
    sub     rdi, 36
    cvtsi2ss xmm0, dword ptr [rsp+12]
    addss   xmm0, [rip+li_half]
    mulss   xmm0, [rsp+8]
    mov     rcx, [rsp+24]
    movss   xmm1, [rbx+LB_SIZE]
    mulss   xmm1, [rip+li_half]
    subss   xmm0, xmm1
    mulss   xmm0, [rcx+OB_SCALE]
    addss   xmm0, [rdi]
    movss   [rdi], xmm0
    cvtsi2ss xmm0, dword ptr [rsp+16]
    addss   xmm0, [rip+li_half]
    mulss   xmm0, [rsp+8]
    subss   xmm0, xmm1
    mulss   xmm0, [rcx+OB_SCALE+8]
    addss   xmm0, [rdi+8]
    movss   [rdi+8], xmm0
    inc     dword ptr [rsp+12]
    jmp     2b
7:  inc     dword ptr [rsp+16]
    jmp     1b
8:  mov     rbp, [rsp+24]               # the landscape goes
    xor     ecx, ecx
81: cmp     ecx, [rip+obj_count]
    jae     82f
    push    rcx
    push    rcx
    mov     edi, ecx
    call    obj_at
    pop     rcx
    pop     rcx
    cmp     rax, rbp
    je      83f
    inc     ecx
    jmp     81b
83: mov     edi, ecx
    call    obj_remove_at
82: call    fmt_reset
    lea     rdi, [rip+s_li_tiles]
    call    fmt_str
    mov     edi, [rsp]
    imul    edi, edi
    call    fmt_int
    lea     rdi, [rip+fmt_buf]
    call    log_line
    mov     dword ptr [rip+dirty], 1
    jmp     9f
.Ltl_bad:
    lea     rdi, [rip+s_li_ntiles]
    call    log_line
    jmp     9f
.Ltl_mem:
    lea     rdi, [rip+s_li_mem]
    call    log_line
9:  add     rsp, 72
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.section .bss
exr_dw_tmp:     .skip 16

.section .note.GNU-stack,"",@progbits
