# =============================================================================
#  BeeModel - TrueType font engine: table parsing (cmap 4/12, loca, glyf,
#  hmtx), simple + composite glyph outlines, anti-aliased signed-area
#  rasterizer and a glyph cache. No FreeType - everything below is ours.
#
#  Rasterizer: every outline edge adds signed coverage to a float
#  accumulation buffer; a running prefix sum turns it into exact area
#  coverage (the font-rs approach). Quadratic curves are flattened to lines.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"

# exports
.globl fonts
.globl font_load
.globl font_load_at
.globl glyph_index
.globl outline_glyph
.globl xf_ident
.globl r_font
.globl r_scale
.globl r_ox
.globl r_oy
.globl ol_begin
.globl ol_line
.globl ol_end
.globl font_set_size
.globl glyph_get
.globl glyph_cache_flush
.globl utf8_next
.globl gamma_init
.globl gamma_lut
.globl arena

.equ SYS_OPEN,      2
.equ SYS_FSTAT,     5
.equ O_RDONLY_CLOEXEC, 0x80000
.equ MAP_PRIVATE,   2
.equ PROT_READ,     1
.equ MAP_ARENA,     0x4022              # private | anonymous | noreserve
.equ ARENA_BYTES,   0x400000            # 4 MiB of glyph bitmaps, then flush
.equ CACHE_N,       4096                # glyph cache slots (power of two)
.equ CACHE_MAX,     3000                # flush when this full
.equ MAXPTS,        4096
.equ MAXDIM,        256                 # largest glyph bitmap edge

.section .bss
.align 64
fonts:          .skip FNT_SZ*FONT_SLOTS # UI (sans), mono, small, heading
gcache:         .skip CACHE_N*32
acc:            .skip MAXDIM*MAXDIM*4   # float coverage accumulator
ptx:            .skip MAXPTS*4
pty:            .skip MAXPTS*4
ixs:            .skip MAXPTS*4
iys:            .skip MAXPTS*4
flagbuf:        .skip MAXPTS
gamma_lut:      .skip 256
statbuf:        .skip 144
.align 8
arena:          .skip 8
arena_used:     .skip 8
r_font:         .skip 8                 # font being rasterized
cache_count:    .skip 4
r_w:            .skip 4
r_h:            .skip 4
r_left:         .skip 4
r_top:          .skip 4
r_scale:        .skip 4
r_ox:           .skip 4
r_oy:           .skip 4
# contour walk state (floats)
c_sx:           .skip 4
c_sy:           .skip 4
c_px:           .skip 4
c_py:           .skip 4
c_cx:           .skip 4
c_cy:           .skip 4
q_n:            .skip 4
.align 8
ol_begin:       .skip 8                 # outline hooks (text3d.s): a contour starts at
ol_line:        .skip 8                 #  xmm0, xmm1; an edge to xmm2, xmm3 (0: rasterize);
ol_end:         .skip 8                 #  a simple glyph (or component) is done

.section .rodata
.align 16
f_absmask:      .long 0x7fffffff, 0x7fffffff, 0x7fffffff, 0x7fffffff
f1:             .float 1.0
f_neg1:         .float -1.0
f_half:         .float 0.5
f_onehalf:      .float 1.5
f_two:          .float 2.0
f_255:          .float 255.0
f_65536:        .float 65536.0
f_16384:        .float 16384.0
f_flat:         .float 1.5
f_eight:        .float 8.0
# identity transform (a, b, c, d, e, f) in font units
xf_ident:       .float 1.0, 0.0, 0.0, 1.0, 0.0, 0.0

.text

# ---- big-endian readers -------------------------------------------------------
.macro BE16 r32, r16, mem
    movzx   \r32, word ptr \mem
    rol     \r16, 8
.endm
.macro BE16S r32, r16, mem
    movzx   \r32, word ptr \mem
    rol     \r16, 8
    movsx   \r32, \r16
.endm
.macro BE32 r32, mem
    mov     \r32, dword ptr \mem
    bswap   \r32
.endm

# -----------------------------------------------------------------------------
# utf8_next(rsi=ptr) -> eax = code point (0 at end), rsi advanced
# -----------------------------------------------------------------------------
utf8_next:
    movzx   eax, byte ptr [rsi]
    test    eax, eax
    jz      9f
    inc     rsi
    cmp     eax, 0x80
    jb      9f
    cmp     eax, 0xc0
    jb      8f
    mov     ecx, 1
    and     eax, 0x1f
    cmp     byte ptr [rsi-1], 0xe0
    jb      2f
    mov     ecx, 2
    movzx   eax, byte ptr [rsi-1]
    and     eax, 0x0f
    cmp     byte ptr [rsi-1], 0xf0
    jb      2f
    mov     ecx, 3
    movzx   eax, byte ptr [rsi-1]
    and     eax, 0x07
    cmp     byte ptr [rsi-1], 0xf8
    jae     8f
2:  movzx   edx, byte ptr [rsi]
    mov     r8d, edx
    and     r8d, 0xc0
    cmp     r8d, 0x80
    jne     8f
    shl     eax, 6
    and     edx, 0x3f
    or      eax, edx
    inc     rsi
    dec     ecx
    jnz     2b
9:  ret
8:  mov     eax, 0xfffd
    ret

# gamma_init - coverage boost so light-on-dark text does not look thin
gamma_init:
    lea     rdi, [rip+gamma_lut]
    xor     ecx, ecx
1:  mov     eax, ecx                    # (a + sqrt(a*255)) / 2
    imul    eax, 255
    cvtsi2ss xmm0, eax
    sqrtss  xmm0, xmm0
    cvtss2si eax, xmm0
    add     eax, ecx
    shr     eax, 1
    mov     [rdi+rcx], al
    inc     ecx
    cmp     ecx, 256
    jb      1b
    ret

# -----------------------------------------------------------------------------
# font_load(edi=slot, rsi=path) -> eax = 1 on success
# font_load_at(rdi=font struct, rsi=path): the same, into any struct (text3d.s)
# -----------------------------------------------------------------------------
font_load:
    imul    edi, FNT_SZ
    lea     rax, [rip+fonts]
    add     rdi, rax
font_load_at:
    push    rbx
    push    r12
    push    r13
    push    r14
    mov     rbx, rdi                    # font struct
    mov     rdi, rsi
    mov     esi, O_RDONLY_CLOEXEC
    xor     edx, edx
    call    plat_open
    test    eax, eax
    js      .Lfl_fail
    mov     r12d, eax
    mov     edi, eax
    lea     rsi, [rip+statbuf]
    call    plat_fstat
    mov     r13, [rip+statbuf+48]       # st_size
    test    eax, eax
    jnz     .Lfl_close
    cmp     r13, 12
    jb      .Lfl_close
    xor     edi, edi
    mov     rsi, r13
    mov     edx, PROT_READ
    mov     r10d, MAP_PRIVATE
    mov     r8d, r12d
    xor     r9d, r9d
    call    plat_mmap
    cmp     rax, -4096
    ja      .Lfl_close
    mov     r14, rax
    mov     edi, r12d
    call    plat_close
    mov     [rbx+FNT_BASE], r14
    mov     [rbx+FNT_SIZE], r13

    # table directory
    xor     eax, eax
    mov     [rbx+FNT_GLYF], rax
    mov     [rbx+FNT_LOCA], rax
    mov     [rbx+FNT_HMTX], rax
    mov     [rbx+FNT_CMAP], rax
    BE16    ecx, cx, [r14+4]            # numTables
    lea     rdx, [r14+12]
    xor     r8, r8                      # head
    xor     r9, r9                      # hhea
    xor     r10, r10                    # maxp
    xor     r11, r11                    # cmap table
1:  test    ecx, ecx
    jz      2f
    BE32    eax, [rdx+8]                # offset
    cmp     rax, r13
    jae     19f
    add     rax, r14
    mov     edi, [rdx]                  # tag
    cmp     edi, 0x64616568             # 'head'
    jne     11f
    mov     r8, rax
11: cmp     edi, 0x61656868             # 'hhea'
    jne     12f
    mov     r9, rax
12: cmp     edi, 0x7078616d             # 'maxp'
    jne     13f
    mov     r10, rax
13: cmp     edi, 0x70616d63             # 'cmap'
    jne     14f
    mov     r11, rax
14: cmp     edi, 0x78746d68             # 'hmtx'
    jne     15f
    mov     [rbx+FNT_HMTX], rax
15: cmp     edi, 0x61636f6c             # 'loca'
    jne     16f
    mov     [rbx+FNT_LOCA], rax
16: cmp     edi, 0x66796c67             # 'glyf'
    jne     19f
    mov     [rbx+FNT_GLYF], rax
19: add     rdx, 16
    dec     ecx
    jmp     1b
2:  test    r8, r8
    jz      .Lfl_unmap
    test    r9, r9
    jz      .Lfl_unmap
    test    r10, r10
    jz      .Lfl_unmap
    test    r11, r11
    jz      .Lfl_unmap
    cmp     qword ptr [rbx+FNT_GLYF], 0 # CFF-flavoured fonts are not supported
    je      .Lfl_unmap
    cmp     qword ptr [rbx+FNT_LOCA], 0
    je      .Lfl_unmap
    cmp     qword ptr [rbx+FNT_HMTX], 0
    je      .Lfl_unmap
    BE16    eax, ax, [r8+18]
    test    eax, eax
    jz      .Lfl_unmap
    mov     [rbx+FNT_UPEM], eax
    BE16S   eax, ax, [r8+50]
    mov     [rbx+FNT_LOCFMT], eax
    BE16S   eax, ax, [r9+4]
    mov     [rbx+FNT_ASCU], eax
    BE16S   eax, ax, [r9+6]
    mov     [rbx+FNT_DESCU], eax
    BE16    eax, ax, [r9+34]
    test    eax, eax
    jz      .Lfl_unmap
    mov     [rbx+FNT_NHM], eax
    BE16    eax, ax, [r10+4]
    mov     [rbx+FNT_NGLYPH], eax

    # pick the best cmap subtable: format 12 (full Unicode) over format 4
    BE16    ecx, cx, [r11+2]
    lea     rdx, [r11+4]
    xor     r12d, r12d                  # best score
3:  test    ecx, ecx
    jz      4f
    BE16    eax, ax, [rdx]              # platform
    BE16    edi, di, [rdx+2]            # encoding
    BE32    esi, [rdx+4]
    add     rsi, r11
    BE16    r8d, r8w, [rsi]             # format
    xor     r9d, r9d
    cmp     eax, 3
    je      31f
    test    eax, eax                    # platform 0 = Unicode
    jnz     39f
    mov     r9d, 1
    jmp     32f
31: cmp     edi, 1                      # Windows: 1 = BMP, 10 = full
    je      32f
    cmp     edi, 10
    jne     39f
32: cmp     r8d, 4
    jne     33f
    add     r9d, 1
    jmp     34f
33: cmp     r8d, 12
    jne     39f
    add     r9d, 3
34: cmp     r9d, r12d
    jbe     39f
    mov     r12d, r9d
    mov     [rbx+FNT_CMAP], rsi
    mov     [rbx+FNT_CMAPFMT], r8d
39: add     rdx, 8
    dec     ecx
    jmp     3b
4:  test    r12d, r12d
    jz      .Lfl_unmap
    mov     dword ptr [rbx+FNT_LOADED], 1
    mov     eax, 1
    jmp     .Lfl_out
.Lfl_unmap:
    mov     rdi, [rbx+FNT_BASE]
    mov     rsi, [rbx+FNT_SIZE]
    call    plat_munmap
    jmp     .Lfl_fail
.Lfl_close:
    mov     edi, r12d
    call    plat_close
.Lfl_fail:
    mov     dword ptr [rbx+FNT_LOADED], 0
    xor     eax, eax
.Lfl_out:
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# -----------------------------------------------------------------------------
# font_set_size(edi=slot, esi=pixels per em) - also places the baseline in a
# CHAR_H tall text row so TrueType text lines up with the existing layout
# -----------------------------------------------------------------------------
font_set_size:
    imul    edi, FNT_SZ
    lea     rax, [rip+fonts]
    add     rax, rdi
    cmp     dword ptr [rax+FNT_LOADED], 0
    je      9f
    push    rax
    mov     edi, esi
    call    to_px                       # logical em size -> physical
    mov     esi, eax
    mov     edi, CHAR_H
    call    to_px
    cvtsi2ss xmm3, eax                  # physical text row height
    pop     rax
    mov     [rax+FNT_PX], esi
    cvtsi2ss xmm0, esi
    cvtsi2ss xmm1, dword ptr [rax+FNT_UPEM]
    divss   xmm0, xmm1
    movss   [rax+FNT_SCALE], xmm0
    cvtsi2ss xmm1, dword ptr [rax+FNT_ASCU]
    mulss   xmm1, xmm0
    cvtsi2ss xmm2, dword ptr [rax+FNT_DESCU]
    mulss   xmm2, xmm0
    addss   xmm1, xmm2                  # asc + desc (desc < 0)
    addss   xmm1, xmm3                  # centre of the (scaled) text row
    mulss   xmm1, [rip+f_half]
    cvtss2si ecx, xmm1
    mov     [rax+FNT_BASELINE], ecx
    call    glyph_cache_flush
9:  ret

glyph_cache_flush:
    lea     rdi, [rip+gcache]
    xor     eax, eax
    mov     ecx, CACHE_N*32/8
    rep     stosq
    mov     dword ptr [rip+cache_count], 0
    mov     qword ptr [rip+arena_used], 0
    ret

# -----------------------------------------------------------------------------
# glyph_index(rdi=font, esi=code point) -> eax = glyph id (0 = missing)
# -----------------------------------------------------------------------------
glyph_index:
    mov     r8, [rdi+FNT_CMAP]
    cmp     dword ptr [rdi+FNT_CMAPFMT], 12
    je      .Lgi_12
    cmp     esi, 0xffff
    ja      .Lgi_none
    BE16    ecx, cx, [r8+6]             # segCountX2
    lea     r9, [r8+14]                 # endCode[]
    xor     edx, edx
1:  cmp     edx, ecx
    jae     .Lgi_none
    BE16    eax, ax, [r9+rdx]
    cmp     esi, eax
    jbe     2f
    add     edx, 2
    jmp     1b
2:  lea     r10, [r9+rcx+2]             # startCode[]
    BE16    eax, ax, [r10+rdx]
    cmp     esi, eax
    jb      .Lgi_none
    mov     r11d, eax                   # start
    add     r10, rcx                    # idDelta[]
    BE16    edi, di, [r10+rdx]
    add     r10, rcx                    # idRangeOffset[]
    BE16    eax, ax, [r10+rdx]
    test    eax, eax
    jnz     3f
    lea     eax, [rsi+rdi]
    and     eax, 0xffff
    ret
3:  lea     r10, [r10+rdx]
    add     r10, rax
    mov     eax, esi
    sub     eax, r11d
    BE16    eax, ax, [r10+rax*2]
    test    eax, eax
    jz      9f
    add     eax, edi
    and     eax, 0xffff
9:  ret
.Lgi_12:
    BE32    ecx, [r8+12]                # nGroups
    lea     r9, [r8+16]
1:  test    ecx, ecx
    jz      .Lgi_none
    BE32    eax, [r9]
    cmp     esi, eax
    jb      2f
    BE32    edx, [r9+4]
    cmp     esi, edx
    ja      2f
    BE32    edx, [r9+8]
    sub     esi, eax
    lea     eax, [rdx+rsi]
    ret
2:  add     r9, 12
    dec     ecx
    jmp     1b
.Lgi_none:
    xor     eax, eax
    ret

# glyph_data(rdi=font, esi=glyph) -> rax = data, edx = length (0 = empty)
glyph_data:
    xor     edx, edx
    cmp     esi, [rdi+FNT_NGLYPH]
    jae     9f
    mov     r8, [rdi+FNT_LOCA]
    cmp     dword ptr [rdi+FNT_LOCFMT], 0
    jne     1f
    BE16    eax, ax, [r8+rsi*2]
    BE16    ecx, cx, [r8+rsi*2+2]
    add     eax, eax
    add     ecx, ecx
    jmp     2f
1:  BE32    eax, [r8+rsi*4]
    BE32    ecx, [r8+rsi*4+4]
2:  cmp     ecx, eax
    jbe     9f
    mov     edx, ecx
    sub     edx, eax
    add     rax, [rdi+FNT_GLYF]
    ret
9:  xor     eax, eax
    xor     edx, edx
    ret

# -----------------------------------------------------------------------------
# glyph_get(edi=slot, esi=code point) -> rax = cache entry (rendered on miss)
#   entry: +0 key, +4 bitmap offset, +8 w(u16), +10 h(u16),
#          +12 left(i16), +14 top(i16), +16 advance (16.16 px)
# -----------------------------------------------------------------------------
glyph_get:
    push    rbx
    push    r12
    push    r13
    mov     r12d, edi
    mov     r13d, esi
    mov     ebx, edi
    shl     ebx, 24
    or      ebx, esi
    or      ebx, 0x80000000             # key
1:  mov     eax, r13d
    imul    eax, 0x9e3779b1
    xor     eax, r12d
    shr     eax, 20
    and     eax, CACHE_N-1
    lea     rcx, [rip+gcache]
2:  mov     rdx, rax
    shl     rdx, 5
    add     rdx, rcx
    mov     r8d, [rdx]
    cmp     r8d, ebx
    je      8f                          # hit
    test    r8d, r8d
    jz      3f
    inc     eax
    and     eax, CACHE_N-1
    jmp     2b
3:  cmp     dword ptr [rip+cache_count], CACHE_MAX
    jb      4f
    call    glyph_cache_flush
    jmp     1b
4:  mov     [rdx], ebx
    inc     dword ptr [rip+cache_count]
    push    rdx
    sub     rsp, 8
    mov     rdi, rdx
    mov     esi, r12d
    mov     edx, r13d
    call    glyph_render
    add     rsp, 8
    pop     rdx
8:  mov     rax, rdx
    pop     r13
    pop     r12
    pop     rbx
    ret

# glyph_render(rdi=entry, esi=slot, edx=code point)
glyph_render:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    mov     rbx, rdi                    # entry
    imul    esi, FNT_SZ
    lea     rbp, [rip+fonts]
    add     rbp, rsi                    # font
    mov     [rip+r_font], rbp
    mov     rdi, rbp
    mov     esi, edx
    call    glyph_index
    mov     r12d, eax                   # glyph id
    # advance (16.16)
    mov     ecx, [rbp+FNT_NHM]
    dec     ecx
    cmp     eax, ecx
    cmova   eax, ecx
    mov     r8, [rbp+FNT_HMTX]
    BE16    eax, ax, [r8+rax*4]
    cvtsi2ss xmm0, eax
    mulss   xmm0, [rbp+FNT_SCALE]
    mulss   xmm0, [rip+f_65536]
    cvtss2si eax, xmm0
    mov     [rbx+16], eax
    xor     eax, eax
    mov     [rbx+8], eax                # w = h = 0
    mov     [rbx+12], eax
    # outline
    mov     rdi, rbp
    mov     esi, r12d
    call    glyph_data
    test    edx, edx
    jz      .Lgr_done
    cmp     edx, 10
    jb      .Lgr_done
    mov     r13, rax                    # glyph data
    movss   xmm7, [rbp+FNT_SCALE]
    movss   [rip+r_scale], xmm7
    BE16S   eax, ax, [r13+2]            # xMin
    cvtsi2ss xmm0, eax
    mulss   xmm0, xmm7
    roundss xmm0, xmm0, 9               # floor
    cvtss2si r14d, xmm0                 # fx0
    BE16S   eax, ax, [r13+6]            # xMax
    cvtsi2ss xmm0, eax
    mulss   xmm0, xmm7
    roundss xmm0, xmm0, 10              # ceil
    cvtss2si eax, xmm0
    sub     eax, r14d
    add     eax, 3                      # w (+ AA slack)
    mov     [rip+r_w], eax
    BE16S   eax, ax, [r13+8]            # yMax -> top
    neg     eax
    cvtsi2ss xmm0, eax
    mulss   xmm0, xmm7
    roundss xmm0, xmm0, 9
    cvtss2si r15d, xmm0                 # fy0
    BE16S   eax, ax, [r13+4]            # yMin -> bottom
    neg     eax
    cvtsi2ss xmm0, eax
    mulss   xmm0, xmm7
    roundss xmm0, xmm0, 10
    cvtss2si eax, xmm0
    sub     eax, r15d
    add     eax, 2                      # h
    mov     [rip+r_h], eax
    cmp     eax, MAXDIM
    ja      .Lgr_done
    cmp     dword ptr [rip+r_w], MAXDIM
    ja      .Lgr_done
    mov     eax, r14d
    neg     eax
    cvtsi2ss xmm0, eax
    movss   [rip+r_ox], xmm0
    mov     eax, r15d
    neg     eax
    cvtsi2ss xmm0, eax
    movss   [rip+r_oy], xmm0
    # zero the accumulator
    mov     ecx, [rip+r_w]
    imul    ecx, [rip+r_h]
    inc     ecx
    lea     rdi, [rip+acc]
    xor     eax, eax
    rep     stosd
    mov     esi, r12d
    lea     rdx, [rip+xf_ident]
    xor     ecx, ecx
    call    outline_glyph
    # allocate the bitmap in the arena
    mov     ecx, [rip+r_w]
    imul    ecx, [rip+r_h]
    mov     rax, [rip+arena_used]
    lea     rdx, [rax+rcx]
    cmp     rdx, ARENA_BYTES
    ja      .Lgr_done                   # full: drawn empty until the next flush
    cmp     qword ptr [rip+arena], 0
    jne     1f
    push    rcx
    push    rax
    xor     edi, edi
    mov     esi, ARENA_BYTES
    mov     edx, PROT_RW
    mov     r10d, MAP_ARENA
    mov     r8d, -1
    xor     r9d, r9d
    call    plat_mmap
    cmp     rax, -4096
    ja      2f
    mov     [rip+arena], rax
2:  pop     rax
    pop     rcx
    cmp     qword ptr [rip+arena], 0
    je      .Lgr_done
1:  mov     [rbx+4], eax                # bitmap offset
    add     rax, rcx
    mov     [rip+arena_used], rax
    mov     eax, [rip+r_w]
    mov     [rbx+8], ax
    mov     eax, [rip+r_h]
    mov     [rbx+10], ax
    mov     [rbx+12], r14w
    mov     [rbx+14], r15w
    # prefix-sum coverage -> gamma corrected bytes
    mov     edi, [rbx+4]
    add     rdi, [rip+arena]
    lea     rsi, [rip+acc]
    lea     r8, [rip+gamma_lut]
    xorps   xmm0, xmm0                  # running sum
    movss   xmm2, [rip+f1]
    movss   xmm3, [rip+f_255]
    movss   xmm4, [rip+f_absmask]
3:  addss   xmm0, [rsi]
    movss   xmm1, xmm0
    andps   xmm1, xmm4
    minss   xmm1, xmm2
    mulss   xmm1, xmm3
    cvtss2si eax, xmm1
    movzx   eax, byte ptr [r8+rax]
    mov     [rdi], al
    add     rsi, 4
    inc     rdi
    dec     ecx
    jnz     3b
    cmp     dword ptr [rbp+FNT_BOLD], 0
    je      .Lgr_done
    mov     edi, [rbx+4]                # bold: each pixel takes the darker
    add     rdi, [rip+arena]            #  of itself and its left neighbour
    mov     r9d, [rip+r_h]
4:  mov     ecx, [rip+r_w]
    dec     ecx
    jle     .Lgr_done
5:  movzx   eax, byte ptr [rdi+rcx]
    movzx   edx, byte ptr [rdi+rcx-1]
    cmp     eax, edx
    jae     6f
    mov     [rdi+rcx], dl
6:  dec     ecx
    jnz     5b
    mov     eax, [rip+r_w]
    add     rdi, rax
    dec     r9d
    jnz     4b
    add     dword ptr [rbx+16], 65536   # one pixel wider
.Lgr_done:
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

# -----------------------------------------------------------------------------
# outline_glyph(esi=glyph, rdx=transform[6], ecx=depth) - adds the glyph's
# contours to the accumulator (recurses into composite glyphs)
# -----------------------------------------------------------------------------
outline_glyph:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 40                     # child transform (24 bytes) + pad
    cmp     ecx, 6
    ja      .Log_out
    mov     r14, rdx                    # parent transform
    mov     r15d, ecx                   # depth
    mov     rdi, [rip+r_font]
    call    glyph_data
    test    edx, edx
    jz      .Log_out
    mov     r12, rax
    BE16S   eax, ax, [r12]              # numberOfContours
    test    eax, eax
    js      .Log_composite
    jz      .Log_out
    mov     rdi, r12
    mov     rsi, r14
    call    outline_simple
    jmp     .Log_out

.Log_composite:
    lea     r12, [r12+10]
.Log_comp_next:
    BE16    r13d, r13w, [r12]           # flags
    BE16    ebx, bx, [r12+2]            # component glyph
    add     r12, 4
    test    r13d, 1                     # ARG_1_AND_2_ARE_WORDS
    jz      1f
    BE16S   eax, ax, [r12]
    BE16S   ebp, bp, [r12+2]
    add     r12, 4
    jmp     2f
1:  movsx   eax, byte ptr [r12]
    movsx   ebp, byte ptr [r12+1]
    add     r12, 2
2:  test    r13d, 2                     # ARGS_ARE_XY_VALUES (else: point match)
    jnz     3f
    xor     eax, eax
    xor     ebp, ebp
3:  cvtsi2ss xmm4, eax                  # component offset e
    cvtsi2ss xmm5, ebp                  # f
    movss   xmm0, [rip+f1]              # a
    xorps   xmm1, xmm1                  # b
    xorps   xmm2, xmm2                  # c
    movss   xmm3, [rip+f1]              # d
    test    r13d, 0x08                  # WE_HAVE_A_SCALE
    jz      4f
    BE16S   eax, ax, [r12]
    cvtsi2ss xmm0, eax
    divss   xmm0, [rip+f_16384]
    movss   xmm3, xmm0
    add     r12, 2
    jmp     6f
4:  test    r13d, 0x40                  # X_AND_Y_SCALE
    jz      5f
    BE16S   eax, ax, [r12]
    cvtsi2ss xmm0, eax
    divss   xmm0, [rip+f_16384]
    BE16S   eax, ax, [r12+2]
    cvtsi2ss xmm3, eax
    divss   xmm3, [rip+f_16384]
    add     r12, 4
    jmp     6f
5:  test    r13d, 0x80                  # TWO_BY_TWO
    jz      6f
    BE16S   eax, ax, [r12]
    cvtsi2ss xmm0, eax
    divss   xmm0, [rip+f_16384]
    BE16S   eax, ax, [r12+2]
    cvtsi2ss xmm1, eax
    divss   xmm1, [rip+f_16384]
    BE16S   eax, ax, [r12+4]
    cvtsi2ss xmm2, eax
    divss   xmm2, [rip+f_16384]
    BE16S   eax, ax, [r12+6]
    cvtsi2ss xmm3, eax
    divss   xmm3, [rip+f_16384]
    add     r12, 8
6:  # child = parent o component
    #   a' = pa*a + pc*b   b' = pb*a + pd*b
    #   c' = pa*c + pc*d   d' = pb*c + pd*d
    #   e' = pa*e + pc*f + pe   f' = pb*e + pd*f + pf
    movss   xmm6, [r14]
    mulss   xmm6, xmm0
    movss   xmm7, [r14+8]
    mulss   xmm7, xmm1
    addss   xmm6, xmm7
    movss   [rsp], xmm6
    movss   xmm6, [r14+4]
    mulss   xmm6, xmm0
    movss   xmm7, [r14+12]
    mulss   xmm7, xmm1
    addss   xmm6, xmm7
    movss   [rsp+4], xmm6
    movss   xmm6, [r14]
    mulss   xmm6, xmm2
    movss   xmm7, [r14+8]
    mulss   xmm7, xmm3
    addss   xmm6, xmm7
    movss   [rsp+8], xmm6
    movss   xmm6, [r14+4]
    mulss   xmm6, xmm2
    movss   xmm7, [r14+12]
    mulss   xmm7, xmm3
    addss   xmm6, xmm7
    movss   [rsp+12], xmm6
    movss   xmm6, [r14]
    mulss   xmm6, xmm4
    movss   xmm7, [r14+8]
    mulss   xmm7, xmm5
    addss   xmm6, xmm7
    addss   xmm6, [r14+16]
    movss   [rsp+16], xmm6
    movss   xmm6, [r14+4]
    mulss   xmm6, xmm4
    movss   xmm7, [r14+12]
    mulss   xmm7, xmm5
    addss   xmm6, xmm7
    addss   xmm6, [r14+20]
    movss   [rsp+20], xmm6
    mov     esi, ebx
    mov     rdx, rsp
    lea     ecx, [r15+1]
    call    outline_glyph
    test    r13d, 0x20                  # MORE_COMPONENTS
    jnz     .Log_comp_next
.Log_out:
    add     rsp, 40
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

# -----------------------------------------------------------------------------
# outline_simple(rdi=glyph data, rsi=transform)
# -----------------------------------------------------------------------------
outline_simple:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    mov     r15, rsi                    # transform
    BE16    r12d, r12w, [rdi]           # contours
    lea     r13, [rdi+10]               # endPtsOfContours[]
    BE16    eax, ax, [r13+r12*2-2]
    inc     eax
    mov     r14d, eax                   # points
    cmp     r14d, MAXPTS
    ja      .Los_out
    BE16    eax, ax, [r13+r12*2]        # instructionLength
    lea     rbx, [r13+r12*2+2]
    add     rbx, rax                    # flags stream
    # flags (with repeats)
    lea     rdi, [rip+flagbuf]
    xor     ecx, ecx
1:  cmp     ecx, r14d
    jae     3f
    movzx   eax, byte ptr [rbx]
    inc     rbx
    mov     [rdi+rcx], al
    inc     ecx
    test    al, 8
    jz      1b
    movzx   edx, byte ptr [rbx]
    inc     rbx
2:  test    edx, edx
    jz      1b
    cmp     ecx, r14d
    jae     3f
    mov     [rdi+rcx], al
    inc     ecx
    dec     edx
    jmp     2b
3:  # x coordinates (short: bit1, same/positive: bit4)
    lea     r8, [rip+ixs]
    mov     r9d, 0x02
    mov     r10d, 0x10
    call    decode_coords
    lea     r8, [rip+iys]
    mov     r9d, 0x04
    mov     r10d, 0x20
    call    decode_coords
    # transform to pixel space
    lea     rsi, [rip+ixs]
    lea     rdi, [rip+iys]
    lea     r8, [rip+ptx]
    lea     r9, [rip+pty]
    movss   xmm6, [rip+r_scale]
    xor     ecx, ecx
4:  cmp     ecx, r14d
    jae     5f
    cvtsi2ss xmm0, dword ptr [rsi+rcx*4]
    cvtsi2ss xmm1, dword ptr [rdi+rcx*4]
    movss   xmm2, [r15]                 # x' = a*x + c*y + e
    mulss   xmm2, xmm0
    movss   xmm3, [r15+8]
    mulss   xmm3, xmm1
    addss   xmm2, xmm3
    addss   xmm2, [r15+16]
    mulss   xmm2, xmm6
    addss   xmm2, [rip+r_ox]
    movss   [r8+rcx*4], xmm2
    movss   xmm2, [r15+4]               # y' = b*x + d*y + f  (flipped)
    mulss   xmm2, xmm0
    movss   xmm3, [r15+12]
    mulss   xmm3, xmm1
    addss   xmm2, xmm3
    addss   xmm2, [r15+20]
    mulss   xmm2, xmm6
    movss   xmm3, [rip+r_oy]
    subss   xmm3, xmm2
    movss   [r9+rcx*4], xmm3
    inc     ecx
    jmp     4b
5:  # contours
    xor     ebp, ebp                    # start
    xor     ebx, ebx                    # contour index
6:  cmp     ebx, r12d
    jae     .Los_out
    BE16    edx, dx, [r13+rbx*2]
    cmp     edx, r14d
    jae     .Los_out
    mov     esi, ebp
    push    rdx
    sub     rsp, 8
    call    emit_contour
    add     rsp, 8
    pop     rdx
    lea     ebp, [rdx+1]
    inc     ebx
    jmp     6b
.Los_out:
    mov     rax, [rip+ol_end]
    test    rax, rax
    jz      7f
    call    rax
7:  add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

# decode_coords(rbx=stream, r8=out int32[], r9d=short bit, r10d=same bit,
#               r14d=count) - advances rbx
decode_coords:
    lea     rdi, [rip+flagbuf]
    xor     eax, eax                    # running coordinate
    xor     ecx, ecx
1:  cmp     ecx, r14d
    jae     9f
    movzx   edx, byte ptr [rdi+rcx]
    test    edx, r9d
    jz      2f
    movzx   r11d, byte ptr [rbx]        # 1-byte delta, sign from the same bit
    inc     rbx
    test    edx, r10d
    jnz     11f
    neg     r11d
11: add     eax, r11d
    jmp     3f
2:  test    edx, r10d
    jnz     3f                          # same as previous
    BE16S   r11d, r11w, [rbx]
    add     rbx, 2
    add     eax, r11d
3:  mov     [r8+rcx*4], eax
    inc     ecx
    jmp     1b
9:  ret

# -----------------------------------------------------------------------------
# emit_contour(esi=first point, edx=last point) - walks on/off-curve points
# -----------------------------------------------------------------------------
emit_contour:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     ecx, edx
    sub     ecx, esi
    inc     ecx                         # count
    cmp     ecx, 2
    jb      .Lec_out
    lea     r8, [rip+ptx]
    lea     r9, [rip+pty]
    lea     r10, [rip+flagbuf]
    test    byte ptr [r10+rsi], 1
    jz      1f
    movss   xmm0, [r8+rsi*4]            # first point is on-curve
    movss   xmm1, [r9+rsi*4]
    lea     r12d, [rsi+1]
    lea     r13d, [rcx-1]
    jmp     3f
1:  test    byte ptr [r10+rdx], 1
    jz      2f
    movss   xmm0, [r8+rdx*4]            # last point is on-curve
    movss   xmm1, [r9+rdx*4]
    mov     r12d, esi
    lea     r13d, [rcx-1]
    jmp     3f
2:  movss   xmm0, [r8+rsi*4]            # all off: start between first and last
    addss   xmm0, [r8+rdx*4]
    mulss   xmm0, [rip+f_half]
    movss   xmm1, [r9+rsi*4]
    addss   xmm1, [r9+rdx*4]
    mulss   xmm1, [rip+f_half]
    mov     r12d, esi
    mov     r13d, ecx
3:  movss   [rip+c_sx], xmm0
    movss   [rip+c_sy], xmm1
    movss   [rip+c_px], xmm0
    movss   [rip+c_py], xmm1
    mov     rax, [rip+ol_begin]         # (collecting outlines: a new loop)
    test    rax, rax
    jz      39f
    call    rax
39: xor     r14d, r14d                  # pending control point?
4:  test    r13d, r13d
    jz      .Lec_close
    lea     r8, [rip+ptx]
    lea     r9, [rip+pty]
    lea     r10, [rip+flagbuf]
    movss   xmm2, [r8+r12*4]            # q
    movss   xmm3, [r9+r12*4]
    test    byte ptr [r10+r12], 1
    jz      6f
    test    r14d, r14d                  # on-curve
    jz      5f
    call    quad_to                     # prev -> ctrl -> q
    jmp     55f
5:  movss   xmm0, [rip+c_px]
    movss   xmm1, [rip+c_py]
    movss   [rsp], xmm2
    movss   [rsp+4], xmm3
    call    line_acc
    movss   xmm2, [rsp]
    movss   xmm3, [rsp+4]
55: movss   [rip+c_px], xmm2
    movss   [rip+c_py], xmm3
    xor     r14d, r14d
    jmp     8f
6:  test    r14d, r14d                  # off-curve
    jz      7f
    movss   [rsp], xmm2                 # implied on-curve midpoint
    movss   [rsp+4], xmm3
    addss   xmm2, [rip+c_cx]
    mulss   xmm2, [rip+f_half]
    addss   xmm3, [rip+c_cy]
    mulss   xmm3, [rip+f_half]
    movss   xmm4, xmm2
    movss   xmm5, xmm3
    call    quad_to
    movss   [rip+c_px], xmm4
    movss   [rip+c_py], xmm5
    movss   xmm2, [rsp]
    movss   xmm3, [rsp+4]
7:  movss   [rip+c_cx], xmm2
    movss   [rip+c_cy], xmm3
    mov     r14d, 1
8:  inc     r12d
    dec     r13d
    jmp     4b
.Lec_close:
    movss   xmm2, [rip+c_sx]
    movss   xmm3, [rip+c_sy]
    test    r14d, r14d
    jz      9f
    call    quad_to
    jmp     .Lec_out
9:  movss   xmm0, [rip+c_px]
    movss   xmm1, [rip+c_py]
    call    line_acc
.Lec_out:
    add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# quad_to(xmm2,xmm3 = end) - from (c_px,c_py) via (c_cx,c_cy); preserves
# xmm4/xmm5 for the caller
quad_to:
    sub     rsp, 56
    movss   [rsp], xmm2                 # p1
    movss   [rsp+4], xmm3
    movss   [rsp+40], xmm4
    movss   [rsp+44], xmm5
    movss   xmm0, [rip+c_px]
    movss   [rsp+8], xmm0               # last point
    movss   xmm1, [rip+c_py]
    movss   [rsp+12], xmm1
    # segments ~ sqrt(curvature)
    movss   xmm6, [rip+c_cx]
    addss   xmm6, xmm6
    movss   xmm7, xmm0
    subss   xmm7, xmm6
    addss   xmm7, xmm2                  # p0 - 2c + p1 (x)
    andps   xmm7, [rip+f_absmask]
    movss   xmm6, [rip+c_cy]
    addss   xmm6, xmm6
    movss   xmm5, xmm1
    subss   xmm5, xmm6
    addss   xmm5, xmm3
    andps   xmm5, [rip+f_absmask]
    addss   xmm7, xmm5
    mulss   xmm7, [rip+f_flat]
    sqrtss  xmm7, xmm7
    cvttss2si eax, xmm7
    inc     eax
    cmp     eax, 16
    jbe     1f
    mov     eax, 16
1:  mov     [rip+q_n], eax
    mov     dword ptr [rsp+16], 1       # i
2:  mov     eax, [rsp+16]
    cmp     eax, [rip+q_n]
    ja      9f
    cvtsi2ss xmm6, eax
    cvtsi2ss xmm7, dword ptr [rip+q_n]
    divss   xmm6, xmm7                  # t
    movss   xmm7, [rip+f1]
    subss   xmm7, xmm6                  # mt
    movss   xmm4, xmm7
    mulss   xmm4, xmm7                  # mt^2
    movss   xmm5, xmm6
    mulss   xmm5, xmm7
    addss   xmm5, xmm5                  # 2 t mt
    mulss   xmm6, xmm6                  # t^2
    movss   xmm2, [rip+c_px]
    mulss   xmm2, xmm4
    movss   xmm0, [rip+c_cx]
    mulss   xmm0, xmm5
    addss   xmm2, xmm0
    movss   xmm0, [rsp]
    mulss   xmm0, xmm6
    addss   xmm2, xmm0                  # x
    movss   xmm3, [rip+c_py]
    mulss   xmm3, xmm4
    movss   xmm0, [rip+c_cy]
    mulss   xmm0, xmm5
    addss   xmm3, xmm0
    movss   xmm0, [rsp+4]
    mulss   xmm0, xmm6
    addss   xmm3, xmm0                  # y
    movss   xmm0, [rsp+8]
    movss   xmm1, [rsp+12]
    movss   [rsp+8], xmm2
    movss   [rsp+12], xmm3
    call    line_acc
    inc     dword ptr [rsp+16]
    jmp     2b
9:  movss   xmm2, [rsp]
    movss   xmm3, [rsp+4]
    movss   xmm4, [rsp+40]
    movss   xmm5, [rsp+44]
    add     rsp, 56
    ret

# -----------------------------------------------------------------------------
# line_acc(xmm0,xmm1 = p0, xmm2,xmm3 = p1) - signed area coverage of one edge
#   (clobbers xmm0-xmm1 and xmm6-xmm15; keeps xmm2-xmm5)
# -----------------------------------------------------------------------------
line_acc:
    mov     rax, [rip+ol_line]          # (collecting outlines instead)
    test    rax, rax
    jz      .Lla_raster
    jmp     rax
.Lla_raster:
    ucomiss xmm1, xmm3
    je      .Lla_ret
    push    rbx
    push    r12
    push    r13
    sub     rsp, 40
    movss   [rsp+16], xmm2
    movss   [rsp+20], xmm3
    movss   [rsp+24], xmm4
    movss   [rsp+28], xmm5
    movss   xmm8, [rip+f1]              # dir
    movaps  xmm9, xmm0                  # x0
    movaps  xmm10, xmm1                 # y0
    movaps  xmm11, xmm2                 # x1
    movaps  xmm12, xmm3                 # y1
    ucomiss xmm10, xmm12
    jb      1f
    movaps  xmm9, xmm2                  # go downwards: swap ends
    movaps  xmm10, xmm3
    movaps  xmm11, xmm0
    movaps  xmm12, xmm1
    movss   xmm8, [rip+f_neg1]
1:  movaps  xmm13, xmm11
    subss   xmm13, xmm9
    movaps  xmm0, xmm12
    subss   xmm0, xmm10
    divss   xmm13, xmm0                 # dxdy
    movaps  xmm14, xmm9                 # x
    xorps   xmm0, xmm0
    xor     ebx, ebx                    # y start
    ucomiss xmm10, xmm0
    jae     2f
    movaps  xmm0, xmm10                 # starts above the box
    mulss   xmm0, xmm13
    subss   xmm14, xmm0
    jmp     3f
2:  roundss xmm0, xmm10, 9
    cvtss2si ebx, xmm0
3:  roundss xmm0, xmm12, 10
    cvtss2si r12d, xmm0                 # y end (exclusive)
    cmp     r12d, [rip+r_h]
    jle     4f
    mov     r12d, [rip+r_h]
4:  mov     eax, [rip+r_w]
    sub     eax, 2
    cvtsi2ss xmm15, eax                 # x clamp max
.Lla_row:
    cmp     ebx, r12d
    jge     .Lla_done
    cvtsi2ss xmm0, ebx                  # dy = min(y+1, y1) - max(y, y0)
    movaps  xmm1, xmm0
    addss   xmm1, [rip+f1]
    minss   xmm1, xmm12
    maxss   xmm0, xmm10
    subss   xmm1, xmm0                  # dy
    movaps  xmm6, xmm13
    mulss   xmm6, xmm1
    addss   xmm6, xmm14                 # xnext
    mulss   xmm1, xmm8                  # d = dy * dir
    movaps  xmm2, xmm14                 # lo / hi, clamped into the box
    minss   xmm2, xmm6
    movaps  xmm3, xmm14
    maxss   xmm3, xmm6
    xorps   xmm0, xmm0
    maxss   xmm2, xmm0
    minss   xmm2, xmm15
    maxss   xmm3, xmm0
    minss   xmm3, xmm15
    roundss xmm4, xmm2, 9               # x0floor
    cvtss2si ecx, xmm4                  # x0i
    roundss xmm5, xmm3, 10              # x1ceil
    cvtss2si edx, xmm5                  # x1i
    mov     eax, ebx
    imul    eax, [rip+r_w]
    lea     r13, [rip+acc]
    lea     r13, [r13+rax*4]            # row
    lea     eax, [rcx+1]
    cmp     edx, eax
    jg      .Lla_span
    # within one pixel: split by the mean x
    movaps  xmm7, xmm2
    addss   xmm7, xmm3
    mulss   xmm7, [rip+f_half]
    subss   xmm7, xmm4                  # xmf
    mulss   xmm7, xmm1                  # d*xmf
    movaps  xmm0, xmm1
    subss   xmm0, xmm7
    addss   xmm0, [r13+rcx*4]
    movss   [r13+rcx*4], xmm0
    addss   xmm7, [r13+rcx*4+4]
    movss   [r13+rcx*4+4], xmm7
    jmp     .Lla_next
.Lla_span:
    movss   xmm7, [rip+f1]
    movaps  xmm0, xmm3
    subss   xmm0, xmm2
    divss   xmm7, xmm0                  # s = 1/(x1-x0)
    movaps  xmm0, xmm2
    subss   xmm0, xmm4                  # x0f
    movss   xmm9, [rip+f1]
    subss   xmm9, xmm0
    mulss   xmm9, xmm9
    mulss   xmm9, xmm7
    mulss   xmm9, [rip+f_half]          # a0
    movaps  xmm11, xmm3
    subss   xmm11, xmm5
    addss   xmm11, [rip+f1]             # x1f
    mulss   xmm11, xmm11
    mulss   xmm11, xmm7
    mulss   xmm11, [rip+f_half]         # am
    movaps  xmm3, xmm1                  # row[x0i] += d*a0
    mulss   xmm3, xmm9
    addss   xmm3, [r13+rcx*4]
    movss   [r13+rcx*4], xmm3
    lea     eax, [rcx+2]
    cmp     edx, eax
    jne     1f
    movss   xmm3, [rip+f1]              # row[x0i+1] += d*(1-a0-am)
    subss   xmm3, xmm9
    subss   xmm3, xmm11
    mulss   xmm3, xmm1
    addss   xmm3, [r13+rcx*4+4]
    movss   [r13+rcx*4+4], xmm3
    jmp     3f
1:  movss   xmm2, [rip+f_onehalf]       # a1 = s*(1.5 - x0f)
    subss   xmm2, xmm0
    mulss   xmm2, xmm7
    movaps  xmm0, xmm2                  # row[x0i+1] += d*(a1-a0)
    subss   xmm0, xmm9
    mulss   xmm0, xmm1
    addss   xmm0, [r13+rcx*4+4]
    movss   [r13+rcx*4+4], xmm0
    movaps  xmm0, xmm7                  # full pixels: += d*s
    mulss   xmm0, xmm1
    lea     eax, [rcx+2]
2:  lea     r8d, [rdx-1]
    cmp     eax, r8d
    jge     21f
    movss   xmm9, [r13+rax*4]
    addss   xmm9, xmm0
    movss   [r13+rax*4], xmm9
    inc     eax
    jmp     2b
21: mov     eax, edx                    # a2 = a1 + (x1i - x0i - 3)*s
    sub     eax, ecx
    sub     eax, 3
    cvtsi2ss xmm0, eax
    mulss   xmm0, xmm7
    addss   xmm0, xmm2
    movss   xmm9, [rip+f1]              # row[x1i-1] += d*(1-a2-am)
    subss   xmm9, xmm0
    subss   xmm9, xmm11
    mulss   xmm9, xmm1
    addss   xmm9, [r13+rdx*4-4]
    movss   [r13+rdx*4-4], xmm9
3:  mulss   xmm11, xmm1                 # row[x1i] += d*am
    addss   xmm11, [r13+rdx*4]
    movss   [r13+rdx*4], xmm11
.Lla_next:
    movaps  xmm14, xmm6
    inc     ebx
    jmp     .Lla_row
.Lla_done:
    movss   xmm2, [rsp+16]
    movss   xmm3, [rsp+20]
    movss   xmm4, [rsp+24]
    movss   xmm5, [rsp+28]
    add     rsp, 40
    pop     r13
    pop     r12
    pop     rbx
.Lla_ret:
    ret

.section .note.GNU-stack,"",@progbits
