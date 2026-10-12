# =============================================================================
#  BeeModel - software rasterizer primitives (XRGB8888 framebuffer)
#
#  Every primitive honours the clip rectangle [clip_x0,clip_x1) x
#  [clip_y0,clip_y1). Coordinates are signed 32-bit, colors 0x00RRGGBB.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"

# exports
.globl clip_x0
.globl clip_x1
.globl clip_y0
.globl clip_y1
.globl draw_line
.globl draw_text
.globl fb_h
.globl fb_ptr
.globl fb_w
.globl fill_rect
.globl fill_vgradient
.globl rect_outline
.globl reset_clip
.globl set_clip
.globl str_len

.section .bss
.align 8
fb_ptr:     .skip 8
fb_w:       .skip 4
fb_h:       .skip 4
clip_x0:    .skip 4
clip_y0:    .skip 4
clip_x1:    .skip 4
clip_y1:    .skip 4

.text

# reset_clip - clip = whole framebuffer
reset_clip:
    mov     dword ptr [rip+clip_x0], 0
    mov     dword ptr [rip+clip_y0], 0
    mov     eax, [rip+fb_w]
    mov     [rip+clip_x1], eax
    mov     eax, [rip+fb_h]
    mov     [rip+clip_y1], eax
    ret

# set_clip(edi=x0, esi=y0, edx=x1, ecx=y1) - intersected with the framebuffer
set_clip:
    xor     eax, eax
    cmp     edi, eax
    cmovl   edi, eax
    cmp     esi, eax
    cmovl   esi, eax
    mov     eax, [rip+fb_w]
    cmp     edx, eax
    cmovg   edx, eax
    mov     eax, [rip+fb_h]
    cmp     ecx, eax
    cmovg   ecx, eax
    mov     [rip+clip_x0], edi
    mov     [rip+clip_y0], esi
    mov     [rip+clip_x1], edx
    mov     [rip+clip_y1], ecx
    ret

# -----------------------------------------------------------------------------
# fill_rect(edi=x, esi=y, edx=w, ecx=h, r8d=color)
# -----------------------------------------------------------------------------
fill_rect:
    add     edx, edi                    # x1
    add     ecx, esi                    # y1
    mov     eax, [rip+clip_x0]
    cmp     edi, eax
    cmovl   edi, eax
    mov     eax, [rip+clip_y0]
    cmp     esi, eax
    cmovl   esi, eax
    mov     eax, [rip+clip_x1]
    cmp     edx, eax
    cmovg   edx, eax
    mov     eax, [rip+clip_y1]
    cmp     ecx, eax
    cmovg   ecx, eax
    sub     edx, edi                    # clipped width
    jle     9f
    sub     ecx, esi                    # clipped height
    jle     9f
    mov     r9d, [rip+fb_w]
    mov     eax, esi
    imul    eax, r9d
    add     eax, edi
    mov     r10, [rip+fb_ptr]
    lea     rdi, [r10+rax*4]
    shl     r9, 2                       # stride in bytes
    mov     r10d, ecx                   # rows
    mov     r11d, edx                   # pixels per row
    mov     eax, r8d
1:  mov     rsi, rdi
    mov     ecx, r11d
    rep     stosd
    lea     rdi, [rsi+r9]
    dec     r10d
    jnz     1b
9:  ret

# -----------------------------------------------------------------------------
# rect_outline(edi=x, esi=y, edx=w, ecx=h, r8d=color) - 1px frame
# -----------------------------------------------------------------------------
rect_outline:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     ebx, edi
    mov     r12d, esi
    mov     r13d, edx
    mov     r14d, ecx
    mov     r15d, r8d
    mov     ecx, 1                      # top
    call    fill_rect
    mov     edi, ebx                    # bottom
    lea     esi, [r12+r14-1]
    mov     edx, r13d
    mov     ecx, 1
    mov     r8d, r15d
    call    fill_rect
    mov     edi, ebx                    # left
    mov     esi, r12d
    mov     edx, 1
    mov     ecx, r14d
    mov     r8d, r15d
    call    fill_rect
    lea     edi, [rbx+r13-1]            # right
    mov     esi, r12d
    mov     edx, 1
    mov     ecx, r14d
    mov     r8d, r15d
    call    fill_rect
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# -----------------------------------------------------------------------------
# fill_vgradient(edi=x, esi=y, edx=w, ecx=h, r8d=top color, r9d=bottom color)
# -----------------------------------------------------------------------------
fill_vgradient:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    test    ecx, ecx
    jle     9f
    mov     ebx, edi
    mov     ebp, esi
    mov     r12d, edx
    mov     r13d, ecx                   # h
    mov     r14d, r8d
    mov     r15d, r9d
    xor     ecx, ecx                    # row
1:  push    rcx
    # color = top + (bot - top) * row / h, per channel
    xor     r8d, r8d
    mov     r10d, 16
2:  mov     ecx, r10d
    mov     eax, r14d
    shr     eax, cl
    and     eax, 255
    mov     edx, r15d
    shr     edx, cl
    and     edx, 255
    sub     edx, eax                    # delta (signed)
    mov     r11d, eax
    mov     eax, edx
    imul    eax, [rsp]                  # * row
    cdq
    idiv    r13d
    add     eax, r11d
    shl     eax, cl
    or      r8d, eax
    sub     r10d, 8
    jns     2b
    mov     edi, ebx
    mov     esi, ebp
    add     esi, [rsp]
    mov     edx, r12d
    mov     ecx, 1
    call    fill_rect
    pop     rcx
    inc     ecx
    cmp     ecx, r13d
    jb      1b
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

# -----------------------------------------------------------------------------
# draw_text(edi=x, esi=y, rdx=asciz, ecx=color) -> eax = x after last glyph
#   8x16 bitmap font, glyphs fully outside the clip are skipped.
# -----------------------------------------------------------------------------
draw_text:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r12d, edi                   # pen x
    mov     r13d, esi                   # pen y
    mov     r14, rdx
    mov     r15d, ecx
    mov     rbx, [rip+fb_ptr]
    mov     ebp, [rip+fb_w]
    # whole line above/below the clip? just advance the pen.
    lea     eax, [r13+CHAR_H]
    cmp     eax, [rip+clip_y0]
    jle     .Ldt_skipall
    cmp     r13d, [rip+clip_y1]
    jge     .Ldt_skipall
.Ldt_char:
    movzx   eax, byte ptr [r14]
    test    eax, eax
    jz      .Ldt_done
    inc     r14
    mov     ecx, eax                    # UTF-8 continuation byte: no glyph
    and     ecx, 0xc0
    cmp     ecx, 0x80
    je      .Ldt_char
    cmp     r12d, [rip+clip_x1]
    jge     .Ldt_next                   # right of clip
    lea     ecx, [r12+CHAR_W]
    cmp     ecx, [rip+clip_x0]
    jle     .Ldt_next                   # left of clip
    sub     eax, 32
    cmp     eax, 94
    jbe     1f
    mov     eax, '?'-32
1:  shl     eax, 4
    lea     rsi, [rip+font_8x16]
    add     rsi, rax                    # glyph rows
    xor     r8d, r8d                    # row
.Ldt_row:
    lea     eax, [r13+r8]               # py
    cmp     eax, [rip+clip_y0]
    jl      .Ldt_nextrow
    cmp     eax, [rip+clip_y1]
    jge     .Ldt_nextrow
    movzx   r10d, byte ptr [rsi+r8]
    test    r10d, r10d
    jz      .Ldt_nextrow
    imul    eax, ebp
    add     eax, r12d
    movsxd  rax, eax
    lea     r9, [rbx+rax*4]
    xor     r11d, r11d                  # col
.Ldt_col:
    mov     ecx, 7
    sub     ecx, r11d
    bt      r10d, ecx
    jnc     .Ldt_nextcol
    lea     eax, [r12+r11]
    cmp     eax, [rip+clip_x0]
    jl      .Ldt_nextcol
    cmp     eax, [rip+clip_x1]
    jge     .Ldt_nextcol
    mov     [r9+r11*4], r15d
.Ldt_nextcol:
    inc     r11d
    cmp     r11d, 8
    jb      .Ldt_col
.Ldt_nextrow:
    inc     r8d
    cmp     r8d, CHAR_H
    jb      .Ldt_row
.Ldt_next:
    add     r12d, CHAR_W
    jmp     .Ldt_char
.Ldt_skipall:
    mov     rdi, r14
    call    str_len
    lea     r12d, [r12+rax*CHAR_W]
.Ldt_done:
    mov     eax, r12d
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

# str_len(rdi) -> eax
str_len:
    xor     eax, eax
1:  cmp     byte ptr [rdi+rax], 0
    je      2f
    inc     eax
    jmp     1b
2:  ret

# -----------------------------------------------------------------------------
# draw_line(edi=x0, esi=y0, edx=x1, ecx=y1, r8d=color) - Bresenham, clipped
# -----------------------------------------------------------------------------
draw_line:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r9d, edi                    # x
    mov     r10d, esi                   # y
    mov     r11d, edx                   # dx = |x1-x0|
    sub     r11d, edi
    mov     r13d, 1                     # sx
    jge     1f
    neg     r11d
    neg     r13d
1:  mov     r12d, ecx                   # dy = -|y1-y0|
    sub     r12d, esi
    mov     r14d, 1                     # sy
    jge     2f
    neg     r12d
    neg     r14d
2:  neg     r12d
    lea     r15d, [r11+r12]             # err
    mov     rbx, [rip+fb_ptr]
    mov     ebp, [rip+fb_w]
    mov     edi, [rip+clip_x0]
    mov     esi, [rip+clip_x1]
    sub     esi, edi                    # clip width (unsigned range test)
    push    rdx
    push    rcx
.Ldl_loop:
    mov     eax, r9d
    sub     eax, edi
    cmp     eax, esi
    jae     3f
    mov     eax, r10d
    cmp     eax, [rip+clip_y0]
    jl      3f
    cmp     eax, [rip+clip_y1]
    jge     3f
    imul    eax, ebp
    add     eax, r9d
    mov     [rbx+rax*4], r8d
3:  cmp     r9d, [rsp+8]
    jne     4f
    cmp     r10d, [rsp]
    je      .Ldl_end
4:  lea     eax, [r15+r15]              # e2
    cmp     eax, r12d
    jl      5f
    add     r15d, r12d
    add     r9d, r13d
5:  cmp     eax, r11d
    jg      .Ldl_loop
    add     r15d, r11d
    add     r10d, r14d
    jmp     .Ldl_loop
.Ldl_end:
    add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

.section .note.GNU-stack,"",@progbits
