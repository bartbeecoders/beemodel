# =============================================================================
#  BeeModel - what the Windows platform files share: plat_win.s (the
#  platform layer) and plat_win_wnd.s (the window). Calling Windows from
#  code with the Linux contract, and the import tables written by hand.
# =============================================================================
.equ IMAGE_BASE,        0x400000        # (scripts/build.sh links there)
.equ SV_RDX,            -8              # where WENTER keeps the arguments
.equ SV_RSI,            -16
.equ SV_RDI,            -24
.equ SV_R8,             -32
.equ SV_R9,             -40
.equ SV_R10,            -48

# WENTER locals / WLEAVE: around the calls into Windows, keep what the
# contract keeps and Windows does not (rdx, rsi, rdi, r8-r10, xmm0-xmm5),
# align the stack and leave the shadow space; [rsp+32...] holds `locals`
# bytes (a multiple of 16) for stack arguments and results.
.macro WENTER locals=0
    push    rbp
    mov     rbp, rsp
    push    rdx
    push    rsi
    push    rdi
    push    r8
    push    r9
    push    r10
    sub     rsp, 96
    movdqu  [rbp-144], xmm0
    movdqu  [rbp-128], xmm1
    movdqu  [rbp-112], xmm2
    movdqu  [rbp-96], xmm3
    movdqu  [rbp-80], xmm4
    movdqu  [rbp-64], xmm5
    and     rsp, -16
    sub     rsp, 32+\locals
.endm
.macro WLEAVE
    movdqu  xmm0, [rbp-144]
    movdqu  xmm1, [rbp-128]
    movdqu  xmm2, [rbp-112]
    movdqu  xmm3, [rbp-96]
    movdqu  xmm4, [rbp-80]
    movdqu  xmm5, [rbp-64]
    lea     rsp, [rbp-48]
    pop     r10
    pop     r9
    pop     r8
    pop     rdi
    pop     rsi
    pop     rdx
    pop     rbp
.endm

# The imports. ld puts the .idata$N sections in order and points the PE
# header at them: $2 one entry per DLL (and an empty one to end), $4 the
# lookup table, $5 the address table the loader fills (__imp_X, global:
# call [rip+__imp_X] from either file), $6 the names, $7 the DLL names.
# Subsection n of $4/$5 is DLL n's run, ended by 0. Each DLL is listed in
# one file, with an n of its own; src/plat_win.ld ends the $2 list.
.macro DLL n, name
    .section .idata$2,"a"
    .long   dll_ilt_\n - IMAGE_BASE, 0, 0, dll_name_\n - IMAGE_BASE, dll_iat_\n - IMAGE_BASE
    .section .idata$4,"a"
    .subsection \n
dll_ilt_\n:
    .section .idata$5,"aw"
    .subsection \n
dll_iat_\n:
    .section .idata$7,"a"
dll_name_\n: .asciz "\name"
.endm
.macro IMPORT n, func
    .section .idata$6,"a"
    .balign 2
imp_name_\func: .short 0
    .asciz "\func"
    .section .idata$4,"a"
    .subsection \n
    .quad   imp_name_\func - IMAGE_BASE
    .section .idata$5,"aw"
    .subsection \n
.globl __imp_\func
__imp_\func: .quad imp_name_\func - IMAGE_BASE
.endm
.macro DLL_END n
    .section .idata$4,"a"
    .subsection \n
    .quad   0
    .section .idata$5,"aw"
    .subsection \n
    .quad   0
.endm
