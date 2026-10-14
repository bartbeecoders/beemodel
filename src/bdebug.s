# =============================================================================
#  BeeModel - B-rep debugging: BEEMODEL_BREP_KEEP=1 keeps a boolean's result
#  even when it is not a valid solid, and dumps its topology to stderr
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "brep.inc"

.globl bk_keep
.globl bk_dump
.globl bk_dump_he
.globl bk_note

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
s_av:           .asciz " area/vol*1000 "
s_pc:           .asciz " pc"
s_bar:          .asciz " |"
s_lf:           .asciz "arrangement of local face "
s_note:         .asciz "note "
s_shoe:         .asciz " shoelace "

.align 8
d_k:            .double 1000000.0
d_half:         .double 0.5
.section .bss
db_buf:         .skip 32
.align 8
db_uv:          .skip 32

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

# d_vpos(edi=vertex) - (x y z) in thousandths
d_vpos:
    push    rbx
    push    r12
    sub     rsp, 8
    call    p_vx
    mov     rbx, rax
    mov     byte ptr [rip+db_buf], '('
    mov     byte ptr [rip+db_buf+1], 0
    lea     rdi, [rip+db_buf]
    call    d_str
    xor     r12d, r12d
1:  movsd   xmm0, [rbx+r12*8]
    mulsd   xmm0, [rip+d_k]
    cvtsd2si edi, xmm0
    call    d_int
    mov     byte ptr [rip+db_buf], ' '
    mov     byte ptr [rip+db_buf+1], 0
    lea     rdi, [rip+db_buf]
    call    d_str
    inc     r12d
    cmp     r12d, 3
    jb      1b
    mov     byte ptr [rip+db_buf], ')'
    mov     byte ptr [rip+db_buf+1], 0
    lea     rdi, [rip+db_buf]
    call    d_str
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# bk_dump_he(rdi=half-edge records, esi=count, edx=local face) - a face's
#   arrangement: each half-edge's edge, ends, angles (thousandths)
bk_dump_he:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12d, esi
    mov     r13d, edx
    lea     rdi, [rip+s_lf]
    call    d_str
    mov     edi, r13d
    call    d_int
    call    d_nl
    xor     r13d, r13d
1:  cmp     r13d, r12d
    jae     9f
    lea     rdi, [rip+s_ce]
    call    d_str
    mov     edi, [rbx]
    call    d_int
    lea     rdi, [rip+s_rev]
    call    d_str
    mov     edi, [rbx+4]
    call    d_int
    lea     rdi, [rip+s_colon]
    call    d_str
    mov     edi, [rbx+8]
    call    d_int
    mov     edi, [rbx+8]
    call    d_vpos
    lea     rdi, [rip+s_arrow]
    call    d_str
    mov     edi, [rbx+12]
    call    d_int
    mov     edi, [rbx+12]
    call    d_vpos
    lea     rdi, [rip+s_ce]
    call    d_str
    movsd   xmm0, [rbx+32]
    mulsd   xmm0, [rip+d_k]
    cvtsd2si edi, xmm0
    call    d_int
    lea     rdi, [rip+s_ce]
    call    d_str
    movsd   xmm0, [rbx+40]
    mulsd   xmm0, [rip+d_k]
    cvtsd2si edi, xmm0
    call    d_int
    call    d_nl
    add     rbx, 64
    inc     r13d
    jmp     1b
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# bk_note(edi, esi, edx) - three numbers on a line ("note a b c")
bk_note:
    push    rbx
    push    r12
    push    r13
    mov     ebx, edi
    mov     r12d, esi
    mov     r13d, edx
    lea     rdi, [rip+s_note]
    call    d_str
    mov     edi, ebx
    call    d_int
    lea     rdi, [rip+s_ce]
    call    d_str
    mov     edi, r12d
    call    d_int
    lea     rdi, [rip+s_ce]
    call    d_str
    mov     edi, r13d
    call    d_int
    call    d_nl
    pop     r13
    pop     r12
    pop     rbx
    ret

# lp_shoelace(edi=loop) -> xmm0 = the signed area of its pcurves' points
#   (polylines: their own points; others: 64 each)
lp_shoelace:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 56
    call    p_lp
    mov     ebx, [rax+LP_FIRST]
    mov     r12d, [rax+LP_N]
    add     r12d, ebx
    xorpd   xmm0, xmm0
    movsd   [rsp+40], xmm0
1:  cmp     ebx, r12d
    jae     9f
    mov     edi, ebx
    call    p_ce
    mov     edi, [rax+CE_PC]
    cmp     edi, -1
    je      8f
    call    p_cv
    mov     r14d, 64
    cmp     dword ptr [rax+CV_TYPE], CT_NURBS
    jne     2f
    mov     r14d, [rax+CV_N]
    shl     r14d, 1
2:  xor     r13d, r13d
3:  cmp     r13d, r14d
    jae     8f
    cvtsi2sd xmm0, r13d                 # segment s0 -> s1
    cvtsi2sd xmm1, r14d
    divsd   xmm0, xmm1
    mov     edi, ebx
    lea     rsi, [rsp]
    call    ce_uv
    lea     eax, [r13+1]
    cvtsi2sd xmm0, eax
    cvtsi2sd xmm1, r14d
    divsd   xmm0, xmm1
    mov     edi, ebx
    lea     rsi, [rsp+16]
    sub     rsp, 32
    lea     rsi, [rsp]
    call    ce_uv
    movsd   xmm0, [rsp]
    movsd   xmm1, [rsp+8]
    add     rsp, 32
    movsd   xmm2, [rsp]                 # x0 y1 - x1 y0
    mulsd   xmm2, xmm1
    movsd   xmm3, [rsp+8]
    mulsd   xmm3, xmm0
    subsd   xmm2, xmm3
    mulsd   xmm2, [rip+d_half]
    addsd   xmm2, [rsp+40]
    movsd   [rsp+40], xmm2
    inc     r13d
    jmp     3b
8:  inc     ebx
    jmp     1b
9:  movsd   xmm0, [rsp+40]
    add     rsp, 56
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
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
    lea     rdi, [rip+s_av]
    call    d_str
    mov     edi, ebx
    call    fc_area
    mulsd   xmm0, [rip+d_k]
    cvtsd2si edi, xmm0
    call    d_int
    lea     rdi, [rip+s_ce]
    call    d_str
    mov     edi, ebx
    call    fc_volume
    mulsd   xmm0, [rip+d_k]
    cvtsd2si edi, xmm0
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
    mov     edi, [r15+ED_V0]
    call    d_vpos
    lea     rdi, [rip+s_arrow]
    call    d_str
    mov     edi, [r15+ED_V1]
    call    d_int
    lea     rdi, [rip+s_mark]
    call    d_str
    mov     edi, [r15+ED_MARK]
    call    d_int
    mov     edi, ebp                    # its pcurve: type, (u, v) at 0, .5, 1
    call    p_ce
    mov     edi, [rax+CE_PC]
    cmp     edi, -1
    je      34f
    call    p_cv
    mov     r15d, [rax+CV_TYPE]
    push    qword ptr [rax+CV_N]
    sub     rsp, 8
    lea     rdi, [rip+s_pc]
    call    d_str
    mov     edi, r15d
    call    d_int
    lea     rdi, [rip+s_colon]
    call    d_str
    mov     edi, [rsp+8]
    call    d_int
    add     rsp, 16
    xor     r15d, r15d
33: cmp     r15d, 2
    ja      34f
    cvtsi2sd xmm0, r15d
    mulsd   xmm0, [rip+d_half]
    mov     edi, ebp
    lea     rsi, [rip+db_uv]
    call    ce_uv
    lea     rdi, [rip+s_ce]
    call    d_str
    movsd   xmm0, [rip+db_uv]
    mulsd   xmm0, [rip+d_k]
    cvtsd2si edi, xmm0
    call    d_int
    lea     rdi, [rip+s_colon]
    call    d_str
    movsd   xmm0, [rip+db_uv+8]
    mulsd   xmm0, [rip+d_k]
    cvtsd2si edi, xmm0
    call    d_int
    inc     r15d
    jmp     33b
34: lea     rdi, [rip+s_bar]
    call    d_str
    inc     ebp
    jmp     3b
4:  lea     rdi, [rip+s_shoe]
    call    d_str
    mov     edi, r13d
    call    lp_shoelace
    mulsd   xmm0, [rip+d_k]
    cvtsd2si edi, xmm0
    call    d_int
    call    d_nl
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
