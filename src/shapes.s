# =============================================================================
#  BeeModel - anti-aliased UI shapes on top of draw.s: rounded rectangles
#  (opaque or translucent), circles, soft drop shadows and anti-aliased
#  lines. Logical coordinates and themed colours, like the other primitives;
#  everything honours the clip rectangle.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.equ ICON_DATA, 1
.include "icons.inc"

# exports
.globl fill_rrect
.globl fill_rrect_a
.globl fill_rect_a
.globl fill_circle
.globl draw_shadow
.globl draw_line_aa
.globl popup_frame
.globl draw_icon

.section .rodata
.align 4
f_half:     .float 0.5
f_one:      .float 1.0
f_256:      .float 256.0

.section .bss
.align 4
rr_x0:      .skip 4                     # the shape, physical pixels
rr_y0:      .skip 4
rr_x1:      .skip 4
rr_y1:      .skip 4
rr_r:       .skip 4                     # corner radius
rr_col:     .skip 4
rr_a:       .skip 4                     # 0..256

.text

# blend(eax = dst, r8d = src colour, edx = alpha 0..256) -> eax
#   clobbers ecx, r9d, r10d (lanes: red|blue together, then green)
.macro BLEND_PX
    mov     ecx, eax
    and     eax, 0xff00ff
    mov     r10d, 256
    sub     r10d, edx
    imul    eax, r10d
    mov     r9d, r8d
    and     r9d, 0xff00ff
    imul    r9d, edx
    add     eax, r9d
    shr     eax, 8
    and     eax, 0xff00ff
    and     ecx, 0x00ff00
    imul    ecx, r10d
    mov     r9d, r8d
    and     r9d, 0x00ff00
    imul    r9d, edx
    add     ecx, r9d
    shr     ecx, 8
    and     ecx, 0x00ff00
    or      eax, ecx
.endm

# fill_rrect(edi=x, esi=y, edx=w, ecx=h, r8d=colour, r9d=radius)
fill_rrect:
    mov     eax, 256
    jmp     rrect

# fill_rect_a(edi=x, esi=y, edx=w, ecx=h, r8d=colour, r9d=alpha 0..255)
fill_rect_a:
    lea     eax, [r9+1]                 # 0..255 -> 1..256 (255 = opaque)
    xor     r9d, r9d
    jmp     rrect

# fill_rrect_a(edi=x, esi=y, edx=w, ecx=h, r8d=colour, r9d=radius,
#   [rsp+8] = alpha 0..255)
fill_rrect_a:
    mov     eax, [rsp+8]
    inc     eax
    jmp     rrect

# fill_circle(edi=centre x, esi=centre y, edx=radius, r8d=colour)
fill_circle:
    sub     edi, edx
    sub     esi, edx
    mov     r9d, edx
    lea     edx, [rdx+rdx]
    mov     ecx, edx
    mov     eax, 256
    jmp     rrect

# rrect(edi, esi, edx, ecx, r8d, r9d radius, eax alpha 1..256) - the shared
#   body: scale to physical pixels, then fill row by row; corner pixels get
#   their coverage of the quarter circles
rrect:
    test    edx, edx
    jle     .Lrr_ret
    test    ecx, ecx
    jle     .Lrr_ret
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    mov     [rip+rr_a], eax
    call    th_map
    mov     [rip+rr_col], r8d
    mov     ebx, r9d
    call    scale4                      # physical x, y, w, h
    add     edx, edi
    add     ecx, esi
    mov     [rip+rr_x0], edi
    mov     [rip+rr_y0], esi
    mov     [rip+rr_x1], edx
    mov     [rip+rr_y1], ecx
    mov     edi, ebx
    call    to_px
    mov     ecx, [rip+rr_x1]            # radius <= half the smaller side
    sub     ecx, [rip+rr_x0]
    shr     ecx, 1
    cmp     eax, ecx
    cmovg   eax, ecx
    mov     ecx, [rip+rr_y1]
    sub     ecx, [rip+rr_y0]
    shr     ecx, 1
    cmp     eax, ecx
    cmovg   eax, ecx
    test    eax, eax
    jns     1f
    xor     eax, eax
1:  mov     [rip+rr_r], eax
    # rows inside the clip
    mov     r12d, [rip+rr_y0]           # y
    mov     eax, [rip+clip_y0]
    cmp     r12d, eax
    cmovl   r12d, eax
    mov     r13d, [rip+rr_y1]
    mov     eax, [rip+clip_y1]
    cmp     r13d, eax
    cmovg   r13d, eax
.Lrr_row:
    cmp     r12d, r13d
    jge     .Lrr_done
    # vertical distance into a corner band: dy > 0 when the row is in one
    mov     eax, [rip+rr_y0]
    add     eax, [rip+rr_r]
    sub     eax, r12d                   # (y0 + r) - y  > 0: top band
    mov     ecx, r12d
    sub     ecx, [rip+rr_y1]
    add     ecx, [rip+rr_r]
    inc     ecx                         # y - (y1 - r - 1) > 0: bottom band
    cmp     eax, ecx
    cmovl   eax, ecx
    mov     r15d, eax                   # > 0: corner rows (distance in rows)
    mov     r14d, [rip+rr_x0]           # x
    mov     eax, [rip+clip_x0]
    cmp     r14d, eax
    cmovl   r14d, eax
    mov     ebp, [rip+rr_x1]
    mov     eax, [rip+clip_x1]
    cmp     ebp, eax
    cmovg   ebp, eax
    mov     eax, r12d
    imul    eax, [rip+fb_w]
    mov     rbx, [rip+fb_ptr]
    lea     rbx, [rbx+rax*4]
.Lrr_px:
    cmp     r14d, ebp
    jge     .Lrr_next
    mov     edx, [rip+rr_a]             # coverage x alpha
    test    r15d, r15d
    jle     .Lrr_full
    mov     eax, [rip+rr_x0]            # horizontal distance into a corner
    add     eax, [rip+rr_r]
    sub     eax, r14d
    mov     ecx, r14d
    sub     ecx, [rip+rr_x1]
    add     ecx, [rip+rr_r]
    inc     ecx
    cmp     eax, ecx
    cmovl   eax, ecx
    test    eax, eax
    jle     .Lrr_full
    # pixel centre to the corner circle's centre: (dx - 0.5, dy - 0.5)
    cvtsi2ss xmm0, eax
    subss   xmm0, [rip+f_half]
    mulss   xmm0, xmm0
    cvtsi2ss xmm1, r15d
    subss   xmm1, [rip+f_half]
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    sqrtss  xmm0, xmm0
    cvtsi2ss xmm1, dword ptr [rip+rr_r]
    subss   xmm1, xmm0                  # r - d
    addss   xmm1, [rip+f_half]
    xorps   xmm2, xmm2
    maxss   xmm1, xmm2
    minss   xmm1, [rip+f_one]
    cvtsi2ss xmm2, edx
    mulss   xmm1, xmm2
    cvttss2si edx, xmm1
    test    edx, edx
    jz      .Lrr_skip
.Lrr_full:
    mov     r8d, [rip+rr_col]
    cmp     edx, 256
    jb      1f
    mov     [rbx+r14*4], r8d
    jmp     .Lrr_skip
1:  mov     eax, [rbx+r14*4]
    BLEND_PX
    mov     [rbx+r14*4], eax
.Lrr_skip:
    inc     r14d
    jmp     .Lrr_px
.Lrr_next:
    inc     r12d
    jmp     .Lrr_row
.Lrr_done:
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
.Lrr_ret:
    ret

# draw_shadow(edi=x, esi=y, edx=w, ecx=h, r8d=spread) - a soft shadow
#   around a popup of that rectangle (drawn before the popup itself)
draw_shadow:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    mov     ebx, edi
    mov     ebp, esi
    mov     r12d, edx
    mov     r13d, ecx
    mov     r14d, r8d                   # i = spread .. 1
1:  test    r14d, r14d
    jle     9f
    mov     edi, ebx
    sub     edi, r14d
    lea     esi, [rbp+2]                # (light from above: a little lower)
    sub     esi, r14d
    lea     edx, [r12+r14*2]
    lea     ecx, [r13+r14*2]
    mov     r8d, COL_SHADOW
    lea     r9d, [r14+4]                # rounder further out
    push    0
    push    22                          # alpha per layer
    call    fill_rrect_a
    add     rsp, 16
    dec     r14d
    jmp     1b
9:  add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

# draw_icon(edi=x, esi=y, edx=icon (ICON_*), r8d=colour) - a 16 x 16 icon
#   (logical), its 4-bit mask tinted with the theme's colour; scaled output
#   samples the nearest mask pixel
draw_icon:
    cmp     edx, ICON_COUNT
    jae     .Ldi_ret
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 24
    shl     edx, 7                      # 128 bytes an icon
    lea     rbx, [rip+icon_masks]
    add     rbx, rdx
    call    th_map
    mov     [rip+rr_col], r8d
    push    rsi
    call    to_px                       # physical x0
    mov     r12d, eax
    pop     rdi
    call    to_px                       # physical y0
    mov     r13d, eax
    mov     edi, 16
    call    to_px
    mov     [rsp], eax                  # physical size
    xor     r14d, r14d                  # row
.Ldi_row:
    cmp     r14d, [rsp]
    jge     .Ldi_done
    lea     eax, [r13+r14]
    cmp     eax, [rip+clip_y0]
    jl      .Ldi_nrow
    cmp     eax, [rip+clip_y1]
    jge     .Ldi_nrow
    imul    eax, [rip+fb_w]
    mov     rbp, [rip+fb_ptr]
    lea     rbp, [rbp+rax*4]
    mov     eax, r14d                   # mask row = row x 16 / size
    shl     eax, 4
    xor     edx, edx
    div     dword ptr [rsp]
    shl     eax, 3
    mov     [rsp+4], eax                # its byte offset
    xor     r15d, r15d                  # column
.Ldi_px:
    cmp     r15d, [rsp]
    jge     .Ldi_nrow
    lea     eax, [r12+r15]
    cmp     eax, [rip+clip_x0]
    jl      .Ldi_npx
    cmp     eax, [rip+clip_x1]
    jge     .Ldi_npx
    mov     [rsp+8], eax
    mov     eax, r15d                   # mask column
    shl     eax, 4
    xor     edx, edx
    div     dword ptr [rsp]
    mov     ecx, eax
    shr     eax, 1
    add     eax, [rsp+4]
    movzx   edx, byte ptr [rbx+rax]
    test    ecx, 1
    jz      1f
    shr     edx, 4
1:  and     edx, 15
    jz      .Ldi_npx
    imul    edx, edx, 17                # 0..255
    inc     edx                         # (16 -> 256: opaque)
    cmp     edx, 256
    jb      2f
    mov     edx, 256
2:  mov     ecx, [rsp+8]
    mov     r8d, [rip+rr_col]
    mov     eax, [rbp+rcx*4]
    push    rcx
    BLEND_PX
    pop     rcx
    mov     [rbp+rcx*4], eax
.Ldi_npx:
    inc     r15d
    jmp     .Ldi_px
.Ldi_nrow:
    inc     r14d
    jmp     .Ldi_row
.Ldi_done:
    add     rsp, 24
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
.Ldi_ret:
    ret

# popup_frame(edi=x, esi=y, edx=w, ecx=h, r8d=border colour) - menus,
#   the palette and dialogs: soft shadow, rounded border, popup background
popup_frame:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    mov     ebx, edi
    mov     ebp, esi
    mov     r12d, edx
    mov     r13d, ecx
    mov     r14d, r8d
    mov     r8d, 6
    call    draw_shadow
    mov     edi, ebx
    mov     esi, ebp
    mov     edx, r12d
    mov     ecx, r13d
    mov     r8d, r14d
    mov     r9d, POPUP_R
    call    fill_rrect
    lea     edi, [rbx+1]
    lea     esi, [rbp+1]
    lea     edx, [r12-2]
    lea     ecx, [r13-2]
    mov     r8d, COL_DROP_BG
    mov     r9d, POPUP_R-1
    call    fill_rrect
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

# draw_line_aa(edi=x0, esi=y0, edx=x1, ecx=y1, r8d=colour) - Xiaolin Wu's
#   anti-aliased line, logical endpoints
draw_line_aa:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 24
    call    th_map
    mov     [rip+rr_col], r8d
    mov     ebx, esi
    mov     r12d, edx
    mov     r13d, ecx
    call    to_px
    cvtsi2ss xmm8, eax                  # x0
    mov     edi, ebx
    call    to_px
    cvtsi2ss xmm9, eax                  # y0
    mov     edi, r12d
    call    to_px
    cvtsi2ss xmm10, eax                 # x1
    mov     edi, r13d
    call    to_px
    cvtsi2ss xmm11, eax                 # y1
    # steep: |dy| > |dx| -> walk y (swap the axes)
    movss   xmm0, xmm11
    subss   xmm0, xmm9
    movss   xmm1, xmm10
    subss   xmm1, xmm8
    mov     eax, 0x7fffffff
    movd    xmm2, eax
    movss   xmm3, xmm0
    andps   xmm3, xmm2
    movss   xmm4, xmm1
    andps   xmm4, xmm2
    xor     r15d, r15d
    comiss  xmm3, xmm4
    jbe     1f
    mov     r15d, 1
    movss   xmm5, xmm8                  # swap x <-> y of both ends
    movss   xmm8, xmm9
    movss   xmm9, xmm5
    movss   xmm5, xmm10
    movss   xmm10, xmm11
    movss   xmm11, xmm5
1:  comiss  xmm8, xmm10                 # walk left to right
    jbe     2f
    movss   xmm5, xmm8
    movss   xmm8, xmm10
    movss   xmm10, xmm5
    movss   xmm5, xmm9
    movss   xmm9, xmm11
    movss   xmm11, xmm5
2:  movss   xmm0, xmm10
    subss   xmm0, xmm8                  # dx
    movss   xmm1, xmm11
    subss   xmm1, xmm9                  # dy
    xorps   xmm12, xmm12                # gradient
    xorps   xmm2, xmm2
    comiss  xmm0, xmm2
    je      3f
    movss   xmm12, xmm1
    divss   xmm12, xmm0
3:  cvttss2si r12d, xmm8                # x
    cvttss2si r13d, xmm10               # x end
    movss   xmm13, xmm9                 # y at x
.Lla_step:
    cmp     r12d, r13d
    jg      .Lla_done
    roundss xmm0, xmm13, 9              # floor(y)
    cvttss2si r14d, xmm0
    movss   xmm1, xmm13
    subss   xmm1, xmm0                  # fraction
    movss   xmm2, [rip+f_one]
    subss   xmm2, xmm1
    mulss   xmm2, [rip+f_256]
    cvttss2si edx, xmm2                 # weight of the upper pixel
    mov     edi, r12d
    mov     esi, r14d
    call    la_plot
    mulss   xmm1, [rip+f_256]
    cvttss2si edx, xmm1                 # the lower one
    mov     edi, r12d
    lea     esi, [r14+1]
    call    la_plot
    addss   xmm13, xmm12
    inc     r12d
    jmp     .Lla_step
.Lla_done:
    add     rsp, 24
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

# la_plot(edi=a, esi=b, edx=weight 0..256) - (a, b) is (x, y), or (y, x)
#   when r15d (steep) is set; clipped; keeps the xmm registers
la_plot:
    test    edx, edx
    jle     9f
    test    r15d, r15d
    jz      1f
    xchg    edi, esi
1:  cmp     edi, [rip+clip_x0]
    jl      9f
    cmp     edi, [rip+clip_x1]
    jge     9f
    cmp     esi, [rip+clip_y0]
    jl      9f
    cmp     esi, [rip+clip_y1]
    jge     9f
    imul    esi, [rip+fb_w]
    add     esi, edi
    mov     rdi, [rip+fb_ptr]
    lea     rdi, [rdi+rsi*4]
    mov     r8d, [rip+rr_col]
    mov     eax, [rdi]
    cmp     edx, 256
    jb      2f
    mov     edx, 256
2:  BLEND_PX
    mov     [rdi], eax
9:  ret

.section .note.GNU-stack,"",@progbits
