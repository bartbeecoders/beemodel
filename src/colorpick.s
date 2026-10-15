# =============================================================================
#  BeeModel - the colour picker: a click on a colour field (WK_COLOR) opens
#  it under the field. A saturation x value square and a hue strip (both
#  widget pads, dragged), the old and new colour side by side, the hex code
#  (typed) and Pick, an eyedropper: the next click anywhere takes the
#  colour on screen there. A click outside or Esc closes it.
#
#  Colours are stored linear (renderer, materials); the picker works in
#  display values, taken as their square roots (as the swatches are).
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "widgets.inc"
.include "macros.inc"

.globl cpk_on
.globl cpk_floor
.globl cpk_open
.globl cpk_close
.globl cpk_draw
.globl cpk_inside
.globl cpk_outside
.globl cpk_rgb_of
.globl cpk_hex_of

.equ SQ_W,      170
.equ SQ_H,      130
.equ HUE_W,     16
.equ CP_W,      10+SQ_W+8+HUE_W+10
.equ CP_H,      10+SQ_H+8+22+10

.section .bss
.align 8
cpk_ptr:         .skip 8                 # the colour (float[3] linear)
cpk_desc:        .skip 8                 # its field (callback)
cpk_on:          .skip 4
cpk_floor:       .skip 4                 # (widgets.s: below this index no hits)
cpk_sub:         .skip 4
cpk_x:           .skip 4
cpk_y:           .skip 4
cpk_drop:        .skip 4                 # Pick: the next click takes a colour
cpk_obj:         .skip 4                 # the active object when it opened
cpk_old:         .skip 4                 # its colour then (packed)
.align 16
cpk_hsv:         .skip 16                # h s v (display)
cpk_sv:          .skip 8                 # pad values
cpk_hue:         .skip 8
cpk_hex:         .skip 32

.section .rodata
.align 4
f_0:            .float 0.0
f_1:            .float 1.0
f_6:            .float 6.0
f_255:          .float 255.0
f_half:         .float 0.5
s_pick_hint:    .asciz "  Pick: click anywhere to take the colour there (Esc: never mind)"
hexd:           .ascii "0123456789abcdef"

.text
WIDGET wd_cp_sv,  WK_PAD, "color.sv", undo="Colour", cb=sv_cb, n=SQ_H, tip="Saturation (across) and brightness (up)", sect=.data
WIDGET wd_cp_hue, WK_PAD, "color.hue", undo="Colour", cb=hue_cb, n=SQ_H, tip="Hue", sect=.data
WIDGET wd_cp_hex, WK_TEXT, "color.hex", cb=hex_cb, undo="Colour", tip="The colour as #rrggbb (Enter)", sect=.data
WIDGET wd_cp_pick, WK_BUTTON, "color.pick", "Pick", aux=op_cpk_pick, tip="Take a colour from anywhere on the screen: click Pick, then click there"

OPERATOR op_cpk_pick, "color.pick", "Pick a Colour", do_pick, flags=OPF_QUIET|OPF_HIDDEN, doc="The open colour picker's eyedropper: the next click anywhere takes the colour on screen there"
do_pick:
    cmp     dword ptr [rip+cpk_on], 0
    je      9f
    mov     dword ptr [rip+cpk_drop], 1
    lea     rdi, [rip+s_pick_hint]
    jmp     log_line
9:  ret

# cpk_open(rdi=the colour field's widget entry) - open the picker for it
cpk_open:
    push    rbx
    mov     rbx, rdi
    mov     rax, [rbx+24]               # (E_PTR, E_DESC, E_SUB)
    mov     [rip+cpk_ptr], rax
    mov     rax, [rbx+32]
    mov     [rip+cpk_desc], rax
    mov     rax, [rax+WD_UNDO]          # undo steps when its field has them
    mov     [rip+wd_cp_sv+WD_UNDO], rax
    mov     [rip+wd_cp_hue+WD_UNDO], rax
    mov     [rip+wd_cp_hex+WD_UNDO], rax
    mov     eax, [rbx+40]
    mov     [rip+cpk_sub], eax
    mov     eax, [rbx+8]                # under the field, right-aligned
    add     eax, [rbx+16]
    sub     eax, CP_W
    cmp     eax, 4
    jge     1f
    mov     eax, 4
1:  mov     [rip+cpk_x], eax
    mov     eax, [rbx+12]
    add     eax, [rbx+20]
    add     eax, 2
    lea     ecx, [rax+CP_H]
    cmp     ecx, [rip+win_h]
    jle     2f
    mov     eax, [rbx+12]               # (no room: above it)
    sub     eax, CP_H+2
    jns     2f
    xor     eax, eax
2:  mov     [rip+cpk_y], eax
    mov     eax, [rip+active_obj]
    mov     [rip+cpk_obj], eax
    mov     rdi, [rip+cpk_ptr]
    call    cpk_rgb_of
    mov     [rip+cpk_old], eax
    call    to_hsv
    mov     dword ptr [rip+cpk_drop], 0
    mov     dword ptr [rip+cpk_on], 1
    mov     dword ptr [rip+dirty], 1
    pop     rbx
    ret

cpk_close:
    mov     dword ptr [rip+cpk_on], 0
    mov     dword ptr [rip+cpk_drop], 0
    mov     dword ptr [rip+cpk_floor], 0
    mov     dword ptr [rip+dirty], 1
    ret

# cpk_inside(edi=x, esi=y) -> eax = 1 inside the picker
cpk_inside:
    xor     eax, eax
    sub     edi, [rip+cpk_x]
    js      9f
    cmp     edi, CP_W
    jge     9f
    sub     esi, [rip+cpk_y]
    js      9f
    cmp     esi, CP_H
    jge     9f
    inc     eax
9:  ret

# cpk_outside(edi=x, esi=y) - a press outside: Pick takes the colour there,
#   else the picker closes
cpk_outside:
    cmp     dword ptr [rip+cpk_drop], 0
    je      cpk_close
    push    rbx
    push    r12
    sub     rsp, 8
    mov     ebx, edi
    mov     r12d, esi
    mov     dword ptr [rip+cpk_drop], 0
    mov     rax, [rip+cpk_desc]
    mov     rdi, [rax+WD_UNDO]
    test    rdi, rdi
    jz      1f
    call    undo_push
1:
    mov     edi, ebx                    # the framebuffer pixel there
    call    to_px
    mov     ebx, eax
    mov     edi, r12d
    call    to_px
    cmp     ebx, [rip+fb_w]
    jae     9f
    cmp     eax, [rip+fb_h]
    jae     9f
    imul    eax, [rip+fb_w]
    add     eax, ebx
    mov     rcx, [rip+fb_ptr]
    test    rcx, rcx
    jz      9f
    mov     eax, [rcx+rax*4]
    call    set_packed
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# set_packed(eax=0xrrggbb display) - the colour, its hsv, the owner told
set_packed:
    sub     rsp, 8
    mov     rdi, [rip+cpk_ptr]
    mov     ecx, 2
1:  mov     edx, eax                    # each channel: (c / 255)^2
    shr     edx, 16
    and     edx, 255
    cvtsi2ss xmm0, edx
    divss   xmm0, [rip+f_255]
    mulss   xmm0, xmm0
    movss   [rdi], xmm0
    add     rdi, 4
    shl     eax, 8
    dec     ecx
    jns     1b
    mov     rdi, [rip+cpk_ptr]
    call    cpk_rgb_of
    call    to_hsv
    add     rsp, 8
    jmp     changed

# changed - the owner's callback, a redraw
changed:
    mov     dword ptr [rip+dirty], 1
    mov     rax, [rip+cpk_desc]
    mov     rax, [rax+WD_CB]
    test    rax, rax
    jz      1f
    mov     rdi, [rip+cpk_ptr]
    mov     esi, [rip+cpk_sub]
    jmp     rax
1:  ret

# from_hsv - cpk_hsv into the colour
from_hsv:
    sub     rsp, 24
    movss   xmm0, [rip+cpk_hsv]
    movss   xmm1, [rip+cpk_hsv+4]
    movss   xmm2, [rip+cpk_hsv+8]
    call    hsv_rgb                     # -> xmm0..2 display
    mov     rdi, [rip+cpk_ptr]
    mulss   xmm0, xmm0
    mulss   xmm1, xmm1
    mulss   xmm2, xmm2
    movss   [rdi], xmm0
    movss   [rdi+4], xmm1
    movss   [rdi+8], xmm2
    add     rsp, 24
    jmp     changed

sv_cb:                                  # the square: s across, v up
    movss   xmm0, [rip+cpk_sv]
    movss   [rip+cpk_hsv+4], xmm0
    movss   xmm0, [rip+f_1]
    subss   xmm0, [rip+cpk_sv+4]
    movss   [rip+cpk_hsv+8], xmm0
    jmp     from_hsv
hue_cb:
    movss   xmm0, [rip+cpk_hue+4]
    movss   [rip+cpk_hsv], xmm0
    jmp     from_hsv

hex_cb:                                 # rdi = "#rrggbb" or "rrggbb"
    cmp     byte ptr [rdi], '#'
    jne     1f
    inc     rdi
1:  xor     eax, eax
    mov     ecx, 6
2:  movzx   edx, byte ptr [rdi]
    inc     rdi
    sub     edx, '0'
    cmp     edx, 9
    jbe     3f
    or      edx, 0x20                   # (letters, either case)
    sub     edx, 'a'-'0'
    cmp     edx, 5
    ja      9f
    add     edx, 10
3:  shl     eax, 4
    or      eax, edx
    dec     ecx
    jnz     2b
    jmp     set_packed
9:  ret

# to_hsv(eax=0xrrggbb display) -> cpk_hsv (the hue kept for greys)
to_hsv:
    mov     edx, eax                    # xmm0..2 = r g b in 0..1
    shr     edx, 16
    and     edx, 255
    cvtsi2ss xmm0, edx
    mov     edx, eax
    shr     edx, 8
    and     edx, 255
    cvtsi2ss xmm1, edx
    and     eax, 255
    cvtsi2ss xmm2, eax
    divss   xmm0, [rip+f_255]
    divss   xmm1, [rip+f_255]
    divss   xmm2, [rip+f_255]
    movss   xmm3, xmm0                  # max
    maxss   xmm3, xmm1
    maxss   xmm3, xmm2
    movss   xmm4, xmm0                  # min
    minss   xmm4, xmm1
    minss   xmm4, xmm2
    movss   [rip+cpk_hsv+8], xmm3        # v
    movss   xmm5, xmm3                  # d
    subss   xmm5, xmm4
    xorps   xmm6, xmm6
    ucomiss xmm5, xmm6
    jbe     8f                          # grey: s 0, hue as it was
    movss   xmm6, xmm5
    divss   xmm6, xmm3
    movss   [rip+cpk_hsv+4], xmm6        # s
    ucomiss xmm3, xmm0
    jne     1f
    movss   xmm7, xmm1                  # max r: (g - b) / d
    subss   xmm7, xmm2
    divss   xmm7, xmm5
    jmp     4f
1:  ucomiss xmm3, xmm1
    jne     2f
    movss   xmm7, xmm2                  # max g: (b - r) / d + 2
    subss   xmm7, xmm0
    divss   xmm7, xmm5
    addss   xmm7, [rip+f_1]
    addss   xmm7, [rip+f_1]
    jmp     4f
2:  movss   xmm7, xmm0                  # max b: (r - g) / d + 4
    subss   xmm7, xmm1
    divss   xmm7, xmm5
    addss   xmm7, [rip+f_6]
    subss   xmm7, [rip+f_1]
    subss   xmm7, [rip+f_1]
4:  divss   xmm7, [rip+f_6]
    xorps   xmm6, xmm6
    ucomiss xmm7, xmm6
    jae     5f
    addss   xmm7, [rip+f_1]
5:  movss   [rip+cpk_hsv], xmm7
    ret
8:  movss   [rip+cpk_hsv+4], xmm6
    ret

# hsv_rgb(xmm0=h 0..1, xmm1=s, xmm2=v) -> xmm0, xmm1, xmm2 = r g b
hsv_rgb:
    mulss   xmm0, [rip+f_6]
    cvttss2si eax, xmm0
    cvtsi2ss xmm3, eax
    subss   xmm0, xmm3                  # f
    cmp     eax, 5
    jbe     1f
    mov     eax, eax                    # (h = 1: as 0)
    xor     eax, eax
1:  movss   xmm4, [rip+f_1]             # p = v (1 - s)
    subss   xmm4, xmm1
    mulss   xmm4, xmm2
    movss   xmm5, xmm1                  # q = v (1 - s f)
    mulss   xmm5, xmm0
    movss   xmm6, [rip+f_1]
    subss   xmm6, xmm5
    mulss   xmm6, xmm2
    movss   xmm5, [rip+f_1]             # t = v (1 - s (1 - f))
    subss   xmm5, xmm0
    mulss   xmm5, xmm1
    movss   xmm7, [rip+f_1]
    subss   xmm7, xmm5
    mulss   xmm7, xmm2                  # xmm2 v, xmm4 p, xmm6 q, xmm7 t
    lea     rcx, [rip+.Lhsv_tab]
    movsxd  rax, dword ptr [rcx+rax*4]
    add     rax, rcx
    jmp     rax
.Lh0: movss xmm0, xmm2
    movss   xmm1, xmm7
    movss   xmm2, xmm4
    ret
.Lh1: movss xmm0, xmm6
    movss   xmm1, xmm2
    movss   xmm2, xmm4
    ret
.Lh2: movss xmm0, xmm4
    movss   xmm1, xmm2
    movss   xmm2, xmm7
    ret
.Lh3: movss xmm0, xmm4
    movss   xmm1, xmm6
    ret
.Lh4: movss xmm0, xmm7
    movss   xmm1, xmm4
    ret
.Lh5: movss xmm0, xmm2
    movss   xmm1, xmm4
    movss   xmm2, xmm6
    ret
.section .rodata
.align 4
.Lhsv_tab:
    .long .Lh0-.Lhsv_tab, .Lh1-.Lhsv_tab, .Lh2-.Lhsv_tab
    .long .Lh3-.Lhsv_tab, .Lh4-.Lhsv_tab, .Lh5-.Lhsv_tab
s_colour:       .asciz "Colour"
.text

# pack3(xmm0, xmm1, xmm2 = display 0..1) -> eax = 0xrrggbb
pack3:
    xor     eax, eax
    call    pack1
    movss   xmm0, xmm1
    call    pack1
    movss   xmm0, xmm2
pack1:
    xorps   xmm3, xmm3
    maxss   xmm0, xmm3
    minss   xmm0, [rip+f_1]
    mulss   xmm0, [rip+f_255]
    addss   xmm0, [rip+f_half]
    cvttss2si ecx, xmm0
    shl     eax, 8
    or      eax, ecx
    ret

# cpk_rgb_of(rdi=float[3] linear) -> eax = 0xrrggbb for the screen
cpk_rgb_of:
    test    rdi, rdi
    jz      1f
    xorps   xmm3, xmm3
    movss   xmm0, [rdi]
    maxss   xmm0, xmm3
    sqrtss  xmm0, xmm0
    movss   xmm1, [rdi+4]
    maxss   xmm1, xmm3
    sqrtss  xmm1, xmm1
    movss   xmm2, [rdi+8]
    maxss   xmm2, xmm3
    sqrtss  xmm2, xmm2
    jmp     pack3
1:  xor     eax, eax
    ret

# cpk_hex_of(rdi=float[3] linear, rsi=dest) - "#rrggbb"
cpk_hex_of:
    push    rsi
    call    cpk_rgb_of
    pop     rsi
    mov     byte ptr [rsi], '#'
    mov     ecx, 6
1:  mov     edx, eax
    and     edx, 15
    lea     r8, [rip+hexd]
    mov     dl, [r8+rdx]
    mov     [rsi+rcx], dl
    shr     eax, 4
    dec     ecx
    jnz     1b
    mov     byte ptr [rsi+7], 0
    ret

# cpk_draw - the picker, over everything but tooltips
cpk_draw:
    cmp     dword ptr [rip+cpk_on], 0
    je      9f
    mov     eax, [rip+active_obj]       # (another object: its colour is gone)
    cmp     eax, [rip+cpk_obj]
    jne     cpk_close
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 24
    call    reset_clip
    mov     eax, [rip+wg_n]             # widgets from here on are the picker's
    mov     [rip+cpk_floor], eax
    mov     r12d, [rip+cpk_x]
    mov     r13d, [rip+cpk_y]
    mov     edi, r12d
    mov     esi, r13d
    mov     edx, CP_W
    mov     ecx, CP_H
    mov     r8d, COL_DROP_BORDER
    call    popup_frame
    xor     ebx, ebx                    # the square: a column at a time
1:  cvtsi2ss xmm1, ebx
    mov     eax, SQ_W-1
    cvtsi2ss xmm3, eax
    divss   xmm1, xmm3
    movss   xmm0, [rip+cpk_hsv]
    movss   xmm2, [rip+f_1]
    call    hsv_rgb
    call    pack3
    mov     r8d, eax
    lea     edi, [r12+10+rbx]
    lea     esi, [r13+10]
    mov     edx, 1
    mov     ecx, SQ_H
    xor     r9d, r9d
    call    fill_vgradient
    inc     ebx
    cmp     ebx, SQ_W
    jb      1b
    xor     ebx, ebx                    # the hue strip
2:  cvtsi2ss xmm0, ebx
    mov     eax, SQ_H-1
    cvtsi2ss xmm3, eax
    divss   xmm0, xmm3
    movss   xmm1, [rip+f_1]
    movss   xmm2, [rip+f_1]
    call    hsv_rgb
    call    pack3
    mov     r8d, eax
    lea     edi, [r12+10+SQ_W+8]
    lea     esi, [r13+10+rbx]
    mov     edx, HUE_W
    mov     ecx, 1
    call    fill_rect
    inc     ebx
    cmp     ebx, SQ_H
    jb      2b
    movss   xmm0, [rip+cpk_hsv+4]        # the square's ring: s, 1 - v
    mov     eax, SQ_W-1
    cvtsi2ss xmm1, eax
    mulss   xmm0, xmm1
    cvtss2si ebx, xmm0
    movss   xmm0, [rip+f_1]
    subss   xmm0, [rip+cpk_hsv+8]
    mov     eax, SQ_H-1
    cvtsi2ss xmm1, eax
    mulss   xmm0, xmm1
    cvtss2si ebp, xmm0
    lea     edi, [r12+10+rbx]
    lea     esi, [r13+10+rbp]
    mov     edx, 6
    mov     r8d, 0xffffff
    call    fill_circle
    mov     rdi, [rip+cpk_ptr]
    call    cpk_rgb_of
    mov     r8d, eax
    lea     edi, [r12+10+rbx]
    lea     esi, [r13+10+rbp]
    mov     edx, 4
    call    fill_circle
    movss   xmm0, [rip+cpk_hsv]          # the strip's marker
    mov     eax, SQ_H-1
    cvtsi2ss xmm1, eax
    mulss   xmm0, xmm1
    cvtss2si ebx, xmm0
    lea     edi, [r12+10+SQ_W+6]
    lea     esi, [r13+10+rbx-1]
    mov     edx, HUE_W+4
    mov     ecx, 3
    mov     r8d, 0xffffff
    call    fill_rect
    lea     r14d, [r13+10+SQ_H+8]       # old | new
    lea     edi, [r12+10]
    mov     esi, r14d
    mov     edx, 24
    mov     ecx, 22
    mov     r8d, [rip+cpk_old]
    call    fill_rect
    mov     rdi, [rip+cpk_ptr]
    call    cpk_rgb_of
    mov     r8d, eax
    lea     edi, [r12+34]
    mov     esi, r14d
    mov     edx, 24
    mov     ecx, 22
    call    fill_rect
    # the pads, the hex code, Pick
    mov     eax, [rip+cpk_hsv+4]
    mov     [rip+cpk_sv], eax
    movss   xmm0, [rip+f_1]
    subss   xmm0, [rip+cpk_hsv+8]
    movss   [rip+cpk_sv+4], xmm0
    mov     eax, [rip+cpk_hsv]
    mov     [rip+cpk_hue+4], eax
    lea     rdi, [rip+wd_cp_sv]
    lea     esi, [r12+10]
    lea     edx, [r13+10]
    mov     ecx, SQ_W
    lea     r8, [rip+cpk_sv]
    xor     r9d, r9d
    call    wg
    lea     rdi, [rip+wd_cp_hue]
    lea     esi, [r12+10+SQ_W+8]
    lea     edx, [r13+10]
    mov     ecx, HUE_W
    lea     r8, [rip+cpk_hue]
    xor     r9d, r9d
    call    wg
    mov     rdi, [rip+cpk_ptr]
    lea     rsi, [rip+cpk_hex]
    call    cpk_hex_of
    lea     rdi, [rip+wd_cp_hex]
    lea     esi, [r12+66]
    mov     edx, r14d
    mov     ecx, 90
    lea     r8, [rip+cpk_hex]
    xor     r9d, r9d
    call    wg
    lea     rdi, [rip+wd_cp_pick]
    lea     esi, [r12+CP_W-10-66]
    mov     edx, r14d
    mov     ecx, 66
    xor     r8d, r8d
    xor     r9d, r9d
    call    wg
    add     rsp, 24
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
9:  ret

.section .note.GNU-stack,"",@progbits
