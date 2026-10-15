# =============================================================================
#  BeeModel - string builder and console log ring buffer
# =============================================================================
.intel_syntax noprefix
.include "const.inc"

# exports
.globl fmt_char
.globl fmt_pad
.globl fmt_buf
.globl fmt_deg
.globl fmt_fix1
.globl fmt_int
.globl fmt_pos
.globl fmt_reset
.globl fmt_str
.globl log_buf
.globl log_head
.globl log_line
.globl log_pair

.section .bss
.align 4
log_head:       .skip 4
fmt_pos:        .skip 4
log_buf:        .skip LOG_LINES*LOG_LINE_LEN
fmt_buf:        .skip 128

.text

# -----------------------------------------------------------------------------
# String builder + console log
# -----------------------------------------------------------------------------
fmt_reset:
    mov     dword ptr [rip+fmt_pos], 0
    mov     byte ptr [rip+fmt_buf], 0
    ret

# fmt_char(edi=char)
fmt_char:
    mov     eax, [rip+fmt_pos]
    cmp     eax, 126
    jae     1f
    lea     rcx, [rip+fmt_buf]
    mov     [rcx+rax], dil
    mov     byte ptr [rcx+rax+1], 0
    inc     eax
    mov     [rip+fmt_pos], eax
1:  ret

# fmt_pad(edi=column) - append spaces up to the column
fmt_pad:
    push    rbx
    mov     ebx, edi
1:  cmp     [rip+fmt_pos], ebx
    jae     2f
    mov     edi, ' '
    call    fmt_char
    jmp     1b
2:  pop     rbx
    ret

# fmt_str(rdi=asciz)
fmt_str:
    push    rbx
    mov     rbx, rdi
1:  movzx   edi, byte ptr [rbx]
    test    edi, edi
    jz      2f
    call    fmt_char
    inc     rbx
    jmp     1b
2:  pop     rbx
    ret

# fmt_int(edi=signed int)
fmt_int:
    push    rbx
    sub     rsp, 16
    mov     eax, edi
    test    eax, eax
    jns     1f
    push    rax
    mov     edi, '-'
    call    fmt_char
    pop     rax
    neg     eax
1:  xor     ebx, ebx                    # digit count
    mov     ecx, 10
2:  xor     edx, edx
    div     ecx
    add     dl, '0'
    mov     [rsp+rbx], dl
    inc     ebx
    test    eax, eax
    jnz     2b
3:  dec     ebx
    movzx   edi, byte ptr [rsp+rbx]
    call    fmt_char
    test    ebx, ebx
    jnz     3b
    add     rsp, 16
    pop     rbx
    ret

# fmt_fix1(xmm0=float) - one decimal
fmt_fix1:
    push    rbx
    mulss   xmm0, [rip+f_ten]
    cvtss2si ebx, xmm0
    test    ebx, ebx
    jns     1f
    mov     edi, '-'
    call    fmt_char
    neg     ebx
1:  mov     eax, ebx
    xor     edx, edx
    mov     ecx, 10
    div     ecx
    mov     ebx, edx
    mov     edi, eax
    call    fmt_int
    mov     edi, '.'
    call    fmt_char
    lea     edi, [rbx+'0']
    call    fmt_char
    pop     rbx
    ret

# fmt_deg(xmm0=radians) - wrapped to [0,360)
fmt_deg:
    mulss   xmm0, [rip+f_rad2deg]
    mulss   xmm0, [rip+f_ten]
    cvtss2si eax, xmm0
    cdq
    mov     ecx, 3600
    idiv    ecx
    test    edx, edx
    jns     1f
    add     edx, 3600
1:  cvtsi2ss xmm0, edx
    divss   xmm0, [rip+f_ten]
    jmp     fmt_fix1

# log_line(rdi=asciz) - append to the console ring buffer
log_line:
    mov     eax, [rip+log_head]
    and     eax, LOG_LINES-1
    imul    eax, LOG_LINE_LEN
    lea     rdx, [rip+log_buf]
    add     rdx, rax
    xor     ecx, ecx
1:  mov     al, [rdi+rcx]
    mov     [rdx+rcx], al
    test    al, al
    jz      2f
    inc     ecx
    cmp     ecx, LOG_LINE_LEN-1
    jb      1b
    mov     byte ptr [rdx+rcx], 0
2:  inc     dword ptr [rip+log_head]
    mov     dword ptr [rip+dirty], 1
    mov     edi, [rip+log_head]         # a toast for it (status.s)
    dec     edi
    jmp     toast_note

# log_pair(rdi=prefix, rsi=text)
log_pair:
    push    rbx
    mov     rbx, rsi
    push    rdi
    call    fmt_reset
    pop     rdi
    call    fmt_str
    mov     rdi, rbx
    call    fmt_str
    lea     rdi, [rip+fmt_buf]
    call    log_line
    pop     rbx
    ret

.section .note.GNU-stack,"",@progbits
