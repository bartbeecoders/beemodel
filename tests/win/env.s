# =============================================================================
#  BeeModel - the Windows start's environment, tested on its own
#  (Vibecoding/BeeModel-Win11-Port-Plan.html, W3d): HOME is BEEMODEL_HOME,
#  else HOME, else USERPROFILE; XDG_RUNTIME_DIR is TEMP unless set; both
#  with / for \. Linked with src/plat_win.s into build/test-env.exe by
#  scripts/build.sh; run by ci/check-exe.sh under Wine and in the Windows 11
#  VM. Prints a line per check; the exit code is the number that failed.
# =============================================================================
.intel_syntax noprefix

.globl bee_main
.globl envp

.macro CHECK cc, text
    lea     rdi, [rip+9f]
    set\cc  al
    movzx   esi, al
    call    report
    .section .rodata
9:  .asciz "\text"
    .text
.endm

.text
bee_main:
    and     rsp, -16
    push    rbx
    push    r12
    push    r13
    push    r14

    lea     rdi, [rip+s_home]
    call    getenv
    mov     rbx, rax
    test    rax, rax
    CHECK   nz, "HOME is set"
    test    rbx, rbx
    jz      9f
    mov     rdi, rbx
    call    no_backslash
    test    eax, eax
    CHECK   nz, "HOME: / between the folders, no \\"
    lea     rdi, [rip+s_bmhome]         # where it came from
    call    getenv
    mov     r12, rax
    test    rax, rax
    jnz     1f
    lea     rdi, [rip+s_uprof]
    call    getenv
    mov     r12, rax
1:  mov     rdi, rbx
    mov     rsi, r12
    call    same_path
    test    eax, eax
    CHECK   nz, "HOME: BEEMODEL_HOME, else USERPROFILE (as Windows has no HOME)"

9:  lea     rdi, [rip+s_xdg]
    call    getenv
    mov     rbx, rax
    lea     rdi, [rip+s_temp]
    call    getenv
    mov     rsi, rax
    mov     rdi, rbx
    test    rbx, rbx
    jnz     2f
    test    rsi, rsi                    # no TEMP (a bare Wine prefix): none
    sete    al
    movzx   eax, al
    jmp     3f
2:  call    same_path
3:  test    eax, eax
    CHECK   nz, "XDG_RUNTIME_DIR: TEMP, with / (none without TEMP)"

    mov     edi, [rip+fails]
    call    plat_exit_group

# no_backslash(rdi) -> eax = 1 when there is no \ in it
no_backslash:
    mov     eax, 1
1:  mov     cl, [rdi]
    test    cl, cl
    jz      2f
    inc     rdi
    cmp     cl, '\\'
    jne     1b
    xor     eax, eax
2:  ret

# same_path(rdi, rsi) -> eax = 1 when they are the same with \ read as /
#   (rsi 0: no)
same_path:
    xor     eax, eax
    test    rsi, rsi
    jz      3f
1:  mov     cl, [rdi]
    mov     dl, [rsi]
    cmp     dl, '\\'
    jne     2f
    mov     dl, '/'
2:  cmp     cl, dl
    jne     3f
    inc     rdi
    inc     rsi
    test    cl, cl
    jnz     1b
    mov     eax, 1
3:  ret

# getenv(rdi="NAME=") -> rax = its value, 0 when not set
getenv:
    mov     r8, [rip+envp]
1:  mov     rsi, [r8]
    test    rsi, rsi
    jz      4f
    add     r8, 8
    xor     ecx, ecx
2:  mov     al, [rdi+rcx]
    test    al, al
    jz      3f
    cmp     al, [rsi+rcx]
    jne     1b
    inc     ecx
    jmp     2b
3:  lea     rax, [rsi+rcx]
    ret
4:  xor     eax, eax
    ret

report:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    mov     r12d, esi
    lea     rsi, [rip+s_ok]
    test    r12d, r12d
    jnz     1f
    inc     dword ptr [rip+fails]
    lea     rsi, [rip+s_fail]
1:  mov     edi, 1
    mov     edx, 7
    call    plat_write
    mov     rdi, rbx
    xor     edx, edx
2:  cmp     byte ptr [rdi+rdx], 0
    je      3f
    inc     edx
    jmp     2b
3:  mov     rsi, rbx
    mov     edi, 1
    call    plat_write
    mov     edi, 1
    lea     rsi, [rip+s_nl]
    mov     edx, 1
    call    plat_write
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

.section .rodata
s_ok:     .ascii "  ok   "
s_fail:   .ascii "  FAIL "
s_nl:     .ascii "\n"
s_home:   .asciz "HOME="
s_bmhome: .asciz "BEEMODEL_HOME="
s_uprof:  .asciz "USERPROFILE="
s_xdg:    .asciz "XDG_RUNTIME_DIR="
s_temp:   .asciz "TEMP="

.section .bss
.align 8
envp:     .skip 8
fails:    .skip 4
