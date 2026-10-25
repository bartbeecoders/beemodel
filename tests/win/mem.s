# =============================================================================
#  BeeModel - the Windows platform layer's memory routines, tested on their
#  own (Vibecoding/BeeModel-Win11-Port-Plan.html, W3a). Linked with
#  src/plat_win.s into build/test-mem.exe by ci/check-exe.sh, which runs it
#  under Wine and in the Windows 11 VM. Prints a line per check; the exit
#  code is the number that failed.
# =============================================================================
.intel_syntax noprefix

.globl bee_main
.globl envp

.equ PROT_R,     1
.equ PROT_RW,    3
.equ PROT_RX,    5
.equ MAP_PRIV,   0x22                   # private | anonymous
.equ MAP_NORES,  0x4022                 # ... | noreserve
.equ MAP_FILE,   0x02                   # private, from a file
.equ MADV_DONTNEED, 4
.equ GIB,        0x40000000

# CHECK cc, "what": counts a failure unless the flags say cc
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

    # a 1 GiB MAP_NORESERVE range: reserved, committed where touched
    xor     edi, edi
    mov     esi, GIB
    mov     edx, PROT_RW
    mov     r10d, MAP_NORES
    mov     r8d, -1
    xor     r9d, r9d
    call    plat_mmap
    mov     rbx, rax
    cmp     rax, -4096
    CHECK   b, "noreserve: 1 GiB mapped"
    mov     byte ptr [rbx], 7
    mov     rax, GIB/2
    mov     byte ptr [rbx+rax], 9
    mov     byte ptr [rbx+GIB-1], 11
    mov     rax, GIB/2
    movzx   eax, byte ptr [rbx+rax]
    add     al, [rbx]
    add     al, [rbx+GIB-1]
    cmp     al, 27
    CHECK   e, "noreserve: written at the start, the middle and the end"
    lea     rdi, [rbx+0x100000]         # untouched: reads zero
    cmp     byte ptr [rdi], 0
    CHECK   e, "noreserve: an untouched page reads zero"
    mov     rdi, rbx                    # mincore: touched / not
    mov     esi, 0x400000
    lea     rdx, [rip+vec]
    call    plat_mincore
    test    rax, rax
    CHECK   z, "mincore: answers"
    cmp     byte ptr [rip+vec], 1
    CHECK   e, "mincore: a touched page is in"
    cmp     byte ptr [rip+vec+0x200], 0
    CHECK   e, "mincore: a page never touched is not"
    mov     rdi, rbx                    # DONTNEED: zero again, still usable
    mov     esi, 4096
    mov     edx, MADV_DONTNEED
    call    plat_madvise
    test    rax, rax
    CHECK   z, "noreserve: MADV_DONTNEED"
    cmp     byte ptr [rbx], 0
    CHECK   e, "noreserve: a page given back reads zero"
    mov     byte ptr [rbx], 5
    cmp     byte ptr [rbx], 5
    CHECK   e, "noreserve: and takes a write again"
    mov     rdi, rbx
    mov     esi, GIB
    call    plat_munmap
    test    rax, rax
    CHECK   z, "noreserve: unmapped"
    mov     rdi, rbx
    mov     esi, 4096
    lea     rdx, [rip+vec]
    call    plat_mincore
    cmp     rax, -12
    CHECK   e, "noreserve: gone after munmap (mincore: -ENOMEM)"

    # a plain 1 MiB map: DONTNEED zeroes it, it stays mapped
    xor     edi, edi
    mov     esi, 0x100000
    mov     edx, PROT_RW
    mov     r10d, MAP_PRIV
    mov     r8d, -1
    xor     r9d, r9d
    call    plat_mmap
    mov     rbx, rax
    cmp     rax, -4096
    CHECK   b, "plain: 1 MiB mapped"
    mov     rdi, rbx
    mov     al, 0x5a
    mov     ecx, 0x100000
    rep stosb
    lea     rdi, [rbx+0x10000]
    mov     esi, 0x20000
    mov     edx, MADV_DONTNEED
    call    plat_madvise
    cmp     byte ptr [rbx+0x10000], 0
    sete    al
    cmp     byte ptr [rbx+0x2ffff], 0
    sete    cl
    and     al, cl
    cmp     byte ptr [rbx+0xffff], 0x5a
    sete    cl
    and     al, cl
    cmp     byte ptr [rbx+0x30000], 0x5a
    sete    cl
    and     al, cl
    cmp     al, 1
    CHECK   e, "plain: MADV_DONTNEED zeroes exactly its pages"
    mov     byte ptr [rbx+0x10000], 1
    cmp     byte ptr [rbx+0x10000], 1
    CHECK   e, "plain: and they take a write again"

    # mremap: grow (moves, keeps the bytes, a zero tail), then shrink
    mov     rdi, rbx
    mov     esi, 0x100000
    mov     edx, 0x300000
    mov     r10d, 1
    call    plat_mremap
    mov     r12, rax
    cmp     rax, -4096
    CHECK   b, "mremap: grown to 3 MiB"
    cmp     byte ptr [r12+0xfffff], 0x5a
    CHECK   e, "mremap: the old bytes came along"
    cmp     byte ptr [r12+0x2fffff], 0
    CHECK   e, "mremap: the new part reads zero"
    mov     byte ptr [r12+0x2fffff], 3
    mov     rdi, rbx                    # (it moved: the old one is gone)
    mov     esi, 4096
    lea     rdx, [rip+vec]
    call    plat_mincore
    cmp     rax, -12
    CHECK   e, "mremap: the old mapping is gone"
    mov     rdi, r12
    mov     esi, 0x300000
    mov     edx, 0x100000
    xor     r10d, r10d
    call    plat_mremap
    cmp     rax, r12
    CHECK   e, "mremap: shrunk in place"
    lea     rdi, [r12+0x200000]
    mov     esi, 4096
    lea     rdx, [rip+vec]
    call    plat_mincore
    cmp     byte ptr [rip+vec], 0
    CHECK   e, "mremap: the cut tail holds nothing"
    mov     rdi, r12
    mov     esi, 0x100000
    mov     edx, 0x200000
    xor     r10d, r10d
    call    plat_mremap
    cmp     rax, -12
    CHECK   e, "mremap: growing without MREMAP_MAYMOVE fails"

    # munmap in two halves: the allocation goes when the second goes
    lea     rdi, [r12+0x80000]
    mov     esi, 0x80000
    call    plat_munmap
    cmp     byte ptr [r12+0x7ffff], 0x5a
    CHECK   e, "munmap: half unmapped, the other half still there"
    mov     rdi, r12
    mov     esi, 0x80000
    call    plat_munmap
    mov     rdi, r12
    mov     esi, 4096
    lea     rdx, [rip+vec]
    call    plat_mincore
    cmp     rax, -12
    CHECK   e, "munmap: both halves unmapped, the allocation is gone"

    # mprotect: code written into a mapping, made executable, run
    xor     edi, edi
    mov     esi, 4096
    mov     edx, PROT_RW
    mov     r10d, MAP_PRIV
    mov     r8d, -1
    xor     r9d, r9d
    call    plat_mmap
    mov     r13, rax
    mov     dword ptr [r13], 0x00002ab8 # mov eax, 42
    mov     word ptr [r13+4], 0xc300    # (0) ; ret
    mov     rdi, r13
    mov     esi, 4096
    mov     edx, PROT_RX
    call    plat_mprotect
    test    rax, rax
    CHECK   z, "mprotect: made executable"
    call    r13
    cmp     eax, 42
    CHECK   e, "mprotect: the code runs"

    # a file mapping from an fd that is not open
    xor     edi, edi
    mov     esi, 4096
    mov     edx, PROT_R
    mov     r10d, MAP_FILE
    mov     r8d, 3
    xor     r9d, r9d
    call    plat_mmap
    cmp     rax, -9
    CHECK   e, "mmap of a file: an fd not open is -EBADF"

    # the contract: every register but rax, rcx, r11 kept (the arguments too)
    xor     edi, edi
    mov     esi, 4096
    mov     edx, PROT_RW
    mov     r10d, MAP_PRIV
    mov     r8, -1
    xor     r9d, r9d
    mov     rbx, 0x1111
    mov     r12, 0x2222
    mov     eax, 0x3333
    movq    xmm0, rax
    movq    xmm5, rax
    call    plat_mmap
    xor     ecx, ecx
    or      rcx, rdi
    lea     rax, [rsi-4096]
    or      rcx, rax
    lea     rax, [rdx-PROT_RW]
    or      rcx, rax
    lea     rax, [r10-MAP_PRIV]
    or      rcx, rax
    lea     rax, [r8+1]
    or      rcx, rax
    or      rcx, r9
    lea     rax, [rbx-0x1111]
    or      rcx, rax
    lea     rax, [r12-0x2222]
    or      rcx, rax
    movq    rax, xmm0
    sub     rax, 0x3333
    or      rcx, rax
    movq    rax, xmm5
    sub     rax, 0x3333
    or      rcx, rax
    test    rcx, rcx
    CHECK   z, "contract: rdi, rsi, rdx, r10, r8, r9, rbx, r12, xmm0, xmm5 kept"

    mov     edi, [rip+fails]
    call    plat_exit_group

# report(rdi=what, esi=1 ok / 0 failed)
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
s_ok:   .ascii "  ok   "
s_fail: .ascii "  FAIL "
s_nl:   .ascii "\n"

.section .bss
.align 8
envp:   .skip 8
fails:  .skip 4
vec:    .skip 0x400
