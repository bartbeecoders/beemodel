# =============================================================================
#  BeeModel - B-rep debugging: BEEMODEL_BREP_KEEP=1 keeps a boolean's result
#  even when it is not a valid solid, and dumps its topology to stderr
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "brep.inc"

.globl bk_keep
.globl bk_dump

.section .rodata
s_keep:         .asciz "BEEMODEL_BREP_KEEP="
s_face:         .asciz "face "
s_surf:         .asciz " surf "
s_sense:        .asciz " sense "
s_loop:         .asciz "  loop:"
s_ce:           .asciz " "
s_rev:          .asciz "r"
s_arrow:        .asciz ">"
s_colon:        .asciz ":"
s_mark:         .asciz " m"

.section .bss
db_buf:         .skip 32

.text
# bk_keep -> eax = 1 when the debug switch is set
bk_keep:
    sub     rsp, 8
    lea     rdi, [rip+s_keep]
    call    getenv
    xor     ecx, ecx
    test    rax, rax
    setnz   cl
    mov     eax, ecx
    add     rsp, 8
    ret

# d_str(rdi) / d_int(edi) / d_nl - to stderr
d_str:
    mov     rsi, rdi
    xor     edx, edx
1:  cmp     byte ptr [rsi+rdx], 0
    je      2f
    inc     edx
    jmp     1b
2:  mov     edi, 2
    mov     eax, SYS_WRITE
    syscall
    ret
d_int:
    lea     rsi, [rip+db_buf+31]
    mov     byte ptr [rsi], 0
    mov     eax, edi
    xor     r8d, r8d
    test    eax, eax
    jns     1f
    neg     eax
    mov     r8d, 1
1:  xor     edx, edx
    mov     ecx, 10
    div     ecx
    add     dl, '0'
    dec     rsi
    mov     [rsi], dl
    test    eax, eax
    jnz     1b
    test    r8d, r8d
    jz      2f
    dec     rsi
    mov     byte ptr [rsi], '-'
2:  mov     rdi, rsi
    jmp     d_str
d_nl:
    sub     rsp, 8
    mov     byte ptr [rip+db_buf], 10
    mov     byte ptr [rip+db_buf+1], 0
    lea     rdi, [rip+db_buf]
    call    d_str
    add     rsp, 8
    ret

# bk_dump(edi=body) - every face, loop and coedge (edge, direction, ends,
#   use marks) to stderr
bk_dump:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 8
    call    p_bd
    mov     ebx, [rax+BD_FIRST]
    mov     r12d, [rax+BD_NF]
    add     r12d, ebx
1:  cmp     ebx, r12d
    jae     9f
    lea     rdi, [rip+s_face]
    call    d_str
    mov     edi, ebx
    call    d_int
    lea     rdi, [rip+s_surf]
    call    d_str
    mov     edi, ebx
    call    p_fc
    mov     r15, rax
    mov     edi, [r15+FC_SURF]
    call    p_sf
    mov     edi, [rax+SF_TYPE]
    call    d_int
    lea     rdi, [rip+s_sense]
    call    d_str
    mov     edi, [r15+FC_SENSE]
    call    d_int
    call    d_nl
    mov     r13d, [r15+FC_LOOP]
    mov     r14d, [r15+FC_NLOOP]
    add     r14d, r13d
2:  cmp     r13d, r14d
    jae     5f
    lea     rdi, [rip+s_loop]
    call    d_str
    mov     edi, r13d
    call    p_lp
    mov     ebp, [rax+LP_FIRST]
    mov     ecx, [rax+LP_N]
    add     ecx, ebp
    mov     [rsp], ecx
3:  cmp     ebp, [rsp]
    jae     4f
    lea     rdi, [rip+s_ce]
    call    d_str
    mov     edi, ebp
    call    p_ce
    mov     r15, rax
    cmp     dword ptr [r15+CE_REV], 0
    je      31f
    lea     rdi, [rip+s_rev]
    call    d_str
31: mov     edi, [r15+CE_EDGE]
    call    d_int
    lea     rdi, [rip+s_colon]
    call    d_str
    mov     edi, [r15+CE_EDGE]
    call    p_ed
    mov     r15, rax
    mov     edi, [r15+ED_V0]
    call    d_int
    lea     rdi, [rip+s_arrow]
    call    d_str
    mov     edi, [r15+ED_V1]
    call    d_int
    lea     rdi, [rip+s_mark]
    call    d_str
    mov     edi, [r15+ED_MARK]
    call    d_int
    inc     ebp
    jmp     3b
4:  call    d_nl
    inc     r13d
    jmp     2b
5:  inc     ebx
    jmp     1b
9:  add     rsp, 8
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.section .note.GNU-stack,"",@progbits
