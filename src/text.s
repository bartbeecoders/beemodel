# =============================================================================
#  BeeModel - text: font selection, UTF-8 text drawing with alpha-blended
#  anti-aliased glyphs, and text measurement. Falls back to the built-in 8x16
#  bitmap font when no TrueType font can be loaded.
#
#  Fonts are read from the system at start-up (no font is embedded, keeping
#  the binary tiny). Override with BEEMODEL_FONT / BEEMODEL_MONO_FONT
#  (a .ttf path, or "none" for the bitmap font).
# =============================================================================
.intel_syntax noprefix
.include "const.inc"

# exports
.globl text_init
.globl draw_text
.globl text_width
.globl text_width_n
.globl text_use
.globl cur_font

.section .data
.align 4
cur_font:       .long FONT_UI

.section .rodata
s_env_font:     .asciz "BEEMODEL_FONT="
s_env_mono:     .asciz "BEEMODEL_MONO_FONT="
s_none:         .asciz "none"
sp1: .asciz "/usr/share/fonts/noto/NotoSans-Regular.ttf"
sp2: .asciz "/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf"
sp3: .asciz "/usr/share/fonts/TTF/DejaVuSans.ttf"
sp4: .asciz "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
sp5: .asciz "/usr/share/fonts/dejavu-sans-fonts/DejaVuSans.ttf"
sp6: .asciz "/usr/share/fonts/liberation/LiberationSans-Regular.ttf"
sp7: .asciz "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf"
mp1: .asciz "/usr/share/fonts/noto/NotoSansMono-Regular.ttf"
mp2: .asciz "/usr/share/fonts/truetype/noto/NotoSansMono-Regular.ttf"
mp3: .asciz "/usr/share/fonts/TTF/DejaVuSansMono.ttf"
mp4: .asciz "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"
mp5: .asciz "/usr/share/fonts/dejavu-sans-mono-fonts/DejaVuSansMono.ttf"
mp6: .asciz "/usr/share/fonts/liberation/LiberationMono-Regular.ttf"
mp7: .asciz "/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf"
.align 8
sans_paths:     .quad sp1, sp2, sp3, sp4, sp5, sp6, sp7, 0
mono_paths:     .quad mp1, mp2, mp3, mp4, mp5, mp6, mp7, 0

.text

# one colour channel at bit offset \sh: src in r14d, dst in r8d, a in eax,
# 255-a in edx, result OR-ed into r9d
.macro BLEND sh
    mov     ecx, r14d
    shr     ecx, \sh
    and     ecx, 255
    imul    ecx, eax
    mov     esi, r8d
    shr     esi, \sh
    and     esi, 255
    imul    esi, edx
    add     ecx, esi
    add     ecx, 128
    mov     esi, ecx
    shr     esi, 8
    add     ecx, esi
    shr     ecx, 8
    shl     ecx, \sh
    or      r9d, ecx
.endm

# load_slot(edi=slot, rsi=env name, rdx=candidate list)
load_slot:
    push    rbx
    push    r12
    push    r13
    mov     ebx, edi
    mov     r13, rdx
    mov     rdi, rsi
    call    getenv
    test    rax, rax
    jz      2f
    mov     r12, rax
    mov     rdi, rax
    lea     rsi, [rip+s_none]
    call    str_eq
    test    eax, eax
    jnz     9f                          # explicitly disabled
    mov     edi, ebx
    mov     rsi, r12
    call    font_load
    test    eax, eax
    jnz     9f
2:  mov     rsi, [r13]
    test    rsi, rsi
    jz      9f
    mov     edi, ebx
    call    font_load
    test    eax, eax
    jnz     9f
    add     r13, 8
    jmp     2b
9:  pop     r13
    pop     r12
    pop     rbx
    ret

text_init:
    call    gamma_init
    mov     edi, FONT_UI
    lea     rsi, [rip+s_env_font]
    lea     rdx, [rip+sans_paths]
    call    load_slot
    mov     edi, FONT_MONO
    lea     rsi, [rip+s_env_mono]
    lea     rdx, [rip+mono_paths]
    call    load_slot
    mov     edi, FONT_UI
    mov     esi, UI_FONT_PX
    call    font_set_size
    mov     edi, FONT_MONO
    mov     esi, MONO_FONT_PX
    jmp     font_set_size

# text_use(edi=slot) -> eax = previous slot
text_use:
    mov     eax, [rip+cur_font]
    mov     [rip+cur_font], edi
    ret

# active_slot -> eax = slot with a loaded font, or -1 (bitmap fallback)
active_slot:
    mov     eax, [rip+cur_font]
    mov     ecx, eax
    imul    ecx, FNT_SZ
    lea     rdx, [rip+fonts]
    cmp     dword ptr [rdx+rcx+FNT_LOADED], 0
    jne     9f
    xor     eax, eax                    # try the UI font instead
    cmp     dword ptr [rdx+FNT_LOADED], 0
    jne     9f
    mov     eax, -1
9:  ret

# -----------------------------------------------------------------------------
# draw_text(edi=x, esi=y, rdx=UTF-8 string, ecx=color) -> eax = pen x after
#   y is the top of a CHAR_H (16px) text row, as with the bitmap font.
# -----------------------------------------------------------------------------
draw_text:
    push    rdi
    push    rsi
    push    rdx
    push    rcx
    call    active_slot
    pop     rcx
    pop     rdx
    pop     rsi
    pop     rdi
    test    eax, eax
    js      draw_text_bitmap
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    mov     ebp, eax                    # slot
    mov     r12d, edi
    shl     r12d, 16                    # pen, 16.16
    mov     r14, rdx
    mov     r15d, ecx
    mov     eax, ebp
    imul    eax, FNT_SZ
    lea     rcx, [rip+fonts]
    mov     r13d, [rcx+rax+FNT_BASELINE]
    add     r13d, esi                   # baseline y
    mov     ebx, 1                      # draw (0 = only measure)
    lea     eax, [rsi+CHAR_H+8]
    cmp     eax, [rip+clip_y0]
    jle     1f
    lea     eax, [rsi-8]
    cmp     eax, [rip+clip_y1]
    jl      2f
1:  xor     ebx, ebx
2:  mov     rsi, r14
    call    utf8_next
    mov     r14, rsi
    test    eax, eax
    jz      9f
    mov     edi, ebp
    mov     esi, eax
    call    glyph_get
    test    ebx, ebx
    jz      3f
    mov     esi, r12d
    add     esi, 0x8000
    sar     esi, 16
    cmp     esi, [rip+clip_x1]
    jge     3f
    movsx   ecx, word ptr [rax+12]
    add     esi, ecx                    # x = pen + left
    movsx   edx, word ptr [rax+14]
    add     edx, r13d                   # y = baseline + top
    mov     rdi, rax
    mov     ecx, r15d
    push    rax
    sub     rsp, 8
    call    blit_glyph
    add     rsp, 8
    pop     rax
3:  add     r12d, [rax+16]
    jmp     2b
9:  mov     eax, r12d
    add     eax, 0x8000
    sar     eax, 16
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

# blit_glyph(rdi=entry, esi=x, edx=y, ecx=color) - alpha blend, clipped
blit_glyph:
    movzx   eax, word ptr [rdi+8]
    test    eax, eax
    jz      .Lbg_ret
    movzx   r8d, word ptr [rdi+10]
    test    r8d, r8d
    jz      .Lbg_ret
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    mov     ebx, eax                    # w
    mov     ebp, r8d                    # h
    mov     r12d, esi                   # x
    mov     r13d, edx                   # y
    mov     r14d, ecx                   # color
    mov     r15d, [rdi+4]
    add     r15, [rip+arena]            # bitmap
    # column range inside the clip
    xor     r8d, r8d                    # c0
    mov     eax, [rip+clip_x0]
    sub     eax, r12d
    cmp     eax, r8d
    cmovg   r8d, eax
    mov     r9d, [rip+clip_x1]          # c1
    sub     r9d, r12d
    cmp     r9d, ebx
    cmovg   r9d, ebx
    cmp     r8d, r9d
    jge     .Lbg_done
    xor     r10d, r10d                  # row
1:  cmp     r10d, ebp
    jge     .Lbg_done
    lea     eax, [r13+r10]              # py
    cmp     eax, [rip+clip_y0]
    jl      6f
    cmp     eax, [rip+clip_y1]
    jge     .Lbg_done
    imul    eax, [rip+fb_w]
    add     eax, r12d
    movsxd  rax, eax
    mov     rdi, [rip+fb_ptr]
    lea     rdi, [rdi+rax*4]            # framebuffer at (x, py)
    mov     eax, r10d
    imul    eax, ebx
    lea     rsi, [r15+rax]              # glyph row
    mov     r11d, r8d                   # col
2:  cmp     r11d, r9d
    jge     6f
    movzx   eax, byte ptr [rsi+r11]
    test    eax, eax
    jz      5f
    cmp     eax, 255
    jne     3f
    mov     [rdi+r11*4], r14d
    jmp     5f
3:  # out = (src*a + dst*(255-a) + 128) / 255, per channel
    push    r8
    push    r9
    push    rsi
    mov     r8d, [rdi+r11*4]            # dst
    mov     edx, 255
    sub     edx, eax                    # 255 - a
    xor     r9d, r9d
    BLEND   0
    BLEND   8
    BLEND   16
    mov     [rdi+r11*4], r9d
    pop     rsi
    pop     r9
    pop     r8
5:  inc     r11d
    jmp     2b
6:  inc     r10d
    jmp     1b
.Lbg_done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
.Lbg_ret:
    ret

# -----------------------------------------------------------------------------
# text_width(rdi=string) -> eax ; text_width_n(rdi=string, esi=bytes) -> eax
# -----------------------------------------------------------------------------
text_width:
    mov     esi, -1
text_width_n:
    push    rbx
    push    rbp
    push    r12
    push    r13
    sub     rsp, 8
    mov     r12, rdi
    mov     r13, rdi
    mov     eax, esi
    add     r13, rax                    # end (wraps to "unlimited" for -1)
    cmp     esi, -1
    jne     1f
    mov     r13, -1
1:  call    active_slot
    mov     ebp, eax
    xor     ebx, ebx                    # width (16.16, or px for bitmap)
2:  cmp     r12, r13
    jae     8f
    mov     rsi, r12
    call    utf8_next
    mov     r12, rsi
    test    eax, eax
    jz      8f
    test    ebp, ebp
    js      3f
    mov     edi, ebp
    mov     esi, eax
    call    glyph_get
    add     ebx, [rax+16]
    jmp     2b
3:  add     ebx, CHAR_W << 16
    jmp     2b
8:  mov     eax, ebx
    add     eax, 0x8000
    sar     eax, 16
    add     rsp, 8
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

.section .note.GNU-stack,"",@progbits
