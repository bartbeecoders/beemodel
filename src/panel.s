# =============================================================================
#  BeeModel - property panel rows (the CAD, material, scene and modifier
#  panels): pnl_begin sets the column from the editor; each helper draws at
#  the caller's y in r12d and moves it down.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "widgets.inc"

.globl pnl_x
.globl pnl_w
.globl pnl_begin
.globl pnl_heading
.globl pnl_hint
.globl pnl_text
.globl pnl_full
.globl pnl_left
.globl pnl_right
.globl pnl_draw_right
.globl pnl_list
.globl pnl_caption

.section .bss
.align 8
pnl_x:          .skip 4
pnl_w:          .skip 4

.text
# pnl_begin - the column: the editor's width less a margin each side
pnl_begin:
    mov     eax, [rip+ed_x]
    add     eax, 14
    mov     [rip+pnl_x], eax
    mov     eax, [rip+ed_w]
    sub     eax, 28
    mov     [rip+pnl_w], eax
    ret

# heading(rdx=text) / hint(rdx=text) / hint_text(rdx=text) at r12d
pnl_heading:
    mov     edi, [rip+pnl_x]
    mov     esi, r12d
    mov     ecx, COL_ACCENT
    sub     rsp, 8
    call    draw_heading
    add     rsp, 8
    add     r12d, 24
    ret
pnl_hint:
    mov     ecx, COL_TEXT_DIM
    jmp     1f
pnl_text:
    mov     ecx, COL_TEXT
1:  mov     edi, [rip+pnl_x]
    mov     esi, r12d
    sub     rsp, 8
    call    draw_small
    add     rsp, 8
    add     r12d, 18
    ret

# pnl_full / pnl_left / pnl_right(rdi=desc, r8=ptr) -> eax (wg's) at r12d
#   (only pnl_full moves down)
pnl_full:
    mov     esi, [rip+pnl_x]
    mov     ecx, [rip+pnl_w]
    mov     edx, r12d
    xor     r9d, r9d
    sub     rsp, 8
    call    wg
    add     rsp, 8
    add     r12d, WG_H+4
    ret
pnl_left:
    mov     esi, [rip+pnl_x]
    mov     ecx, [rip+pnl_w]
    shr     ecx, 1
    sub     ecx, 3
    mov     edx, r12d
    xor     r9d, r9d
    sub     rsp, 8
    call    wg
    add     rsp, 8
    ret
pnl_right:
    mov     ecx, [rip+pnl_w]
    shr     ecx, 1
    mov     esi, [rip+pnl_x]
    add     esi, ecx
    add     esi, 3
    sub     ecx, 3
    mov     edx, r12d
    xor     r9d, r9d
    sub     rsp, 8
    call    wg
    add     rsp, 8
    ret

# draw_right(rdx=text, edi=right edge, esi=y, ecx=colour) - small text
pnl_draw_right:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     rbx, rdx
    mov     r12d, edi
    mov     r13d, esi
    mov     r14d, ecx
    mov     rdi, rdx
    call    text_width_small
    mov     edi, r12d
    sub     edi, eax
    mov     esi, r13d
    mov     rdx, rbx
    mov     ecx, r14d
    call    draw_small
    add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret


# pnl_caption(rdx=text) - a field's caption at the left of the row at r12d
pnl_caption:
    mov     edi, [rip+pnl_x]
    lea     esi, [r12+4]
    mov     ecx, COL_TEXT_DIM
    sub     rsp, 8
    call    draw_small
    add     rsp, 8
    ret

# pnl_list(rdi=out, rsi=first label, edx=count, rcx=fn(edi=i) -> rax name,
#   r8d=room) -> eax = labels: the first, then a name per i (dynamic enums)
pnl_list:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rbx, rdi
    mov     [rbx], rsi
    mov     r12d, edx
    mov     r13, rcx
    lea     r14d, [r8-1]
    cmp     r12d, r14d
    jbe     1f
    mov     r12d, r14d
1:  xor     r15d, r15d
2:  cmp     r15d, r12d
    jae     3f
    mov     edi, r15d
    call    r13
    mov     [rbx+r15*8+8], rax
    inc     r15d
    jmp     2b
3:  lea     eax, [r12+1]
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.section .note.GNU-stack,"",@progbits
